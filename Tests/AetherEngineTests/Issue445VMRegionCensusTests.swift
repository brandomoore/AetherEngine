import Testing
import Foundation
import Darwin.Mach
@testable import AetherEngine

/// AE#445 round 2: the memprobe could say `physFP` rose and every bucket it itemizes stayed flat,
/// which is exactly the state three rounds of this issue ended in. `mallocBlocks` covers the heap
/// and `vmInt/vmExt/vmCmp` cover the totals, so retention that lives in neither (a CoreMedia pool,
/// an IOSurface, a mapped file kept dirty) leaves no name behind, only a slope.
///
/// Serialized: the census keeps a process-wide baseline, and Swift Testing runs cases in parallel.
@Suite(.serialized, .offCooperativePool)
struct Issue445VMRegionCensusTests {

    @Test("census is opt-in and answers nothing while disabled")
    func disabledCensusIsSilent() {
        VMRegionCensus.isEnabled = false
        #expect(VMRegionCensus.census() == nil)
        #expect(VMRegionCensus.probeFragment().isEmpty)
    }

    @Test("a known tag reports its name, an unknown one reports its number")
    func tagNaming() {
        #expect(VMRegionCensus.tagName(3) == "MALLOC_LARGE")
        #expect(VMRegionCensus.tagName(91) == "IOSURFACE")
        #expect(VMRegionCensus.tagName(97) == "CM_MEMORYPOOL")
        #expect(VMRegionCensus.tagName(201) == "tag201")
    }

    @Test("dirty pages allocated after the baseline are attributed to a tag, not just to the total")
    func growthIsAttributedToATag() {
        VMRegionCensus.isEnabled = true
        defer { VMRegionCensus.isEnabled = false }

        VMRegionCensus.markBaseline()
        // An application-specific tag of its own, not the heap: the census is process-wide, and a
        // test running in parallel that frees a large MALLOC block between baseline and census
        // took this growth back out of the MALLOC tallies, so a 96 MB write read as less than 64.
        let tag = 242
        let size = 96 << 20
        let mapped = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, Int32(bitPattern: UInt32(tag) << 24), 0)
        guard let buffer = mapped, buffer != MAP_FAILED else {
            Issue.record("mmap failed: \(errno)")
            return
        }
        defer { munmap(buffer, size) }
        // Footprint counts DIRTY pages, so the allocation has to be written to before it exists as
        // far as this census is concerned. A mapping that is never touched is a promise.
        memset(buffer, 0xAB, size)

        guard let result = VMRegionCensus.census() else {
            Issue.record("census returned nil while enabled")
            return
        }
        let own = result.tallies.first { $0.tag == tag }
        #expect((own?.deltaBytes ?? 0) >= 64 << 20,
                "expected the 96 MB write to show as growth of tag \(tag), saw \((own?.deltaBytes ?? 0) >> 20) MB")
        let grownBytes = result.tallies.reduce(0) { $0 + max(0, $1.deltaBytes) }
        #expect(grownBytes >= 64 << 20, "the total counts the tagged growth too, saw \(grownBytes >> 20) MB")

        let fragment = VMRegionCensus.probeFragment()
        #expect(fragment.contains("vmGrewMB="))
        #expect(fragment.contains("vmTagTop="))
    }

    @Test("the fragment states growth since the baseline, which is the figure that can be checked")
    func fragmentStatesGrowth() {
        VMRegionCensus.isEnabled = true
        defer { VMRegionCensus.isEnabled = false }
        VMRegionCensus.clearBaseline()
        _ = VMRegionCensus.probeFragment()   // first call anchors the baseline

        // A fresh anonymous mapping rather than malloc: the allocator hands back a region an
        // earlier case in this suite already dirtied, so the baseline would contain it and the
        // growth would read as zero. That is the allocator behaving, not the census failing.
        let size = 192 << 20
        let mapped = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
        guard let mapped, mapped != MAP_FAILED else {
            Issue.record("mmap failed")
            return
        }
        defer { munmap(mapped, size) }
        memset(mapped, 0xCD, size)

        let fragment = VMRegionCensus.probeFragment()
        guard let field = fragment.split(separator: " ").first(where: { $0.hasPrefix("vmGrewMB=") }),
              let grewMB = Int(field.dropFirst("vmGrewMB=".count)) else {
            Issue.record("no vmGrewMB in \(fragment)")
            return
        }
        #expect(grewMB >= 128, "expected the 192 MB write to be reported as growth, saw \(grewMB) MB")
    }

    @Test("an anonymous total is deliberately not claimed to equal phys_footprint")
    func totalIsNotClaimedToMatchFootprint() {
        VMRegionCensus.isEnabled = true
        defer { VMRegionCensus.isEnabled = false }
        VMRegionCensus.clearBaseline()

        guard let result = VMRegionCensus.census() else {
            Issue.record("census returned nil while enabled")
            return
        }
        // Anonymous dirt only. Counting a mapped file's dirty pages too produced 104 MB against a
        // 65 MB footprint on a live session, and a total larger than the number above it in the
        // same line is worse than no total at all.
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        #expect(kr == KERN_SUCCESS)
        let footprint = Int(info.phys_footprint)
        // Not an equality, on purpose: IOSurface and video-bitstream mappings read as anonymous
        // here while the kernel charges them to the process that created them, so the anonymous sum
        // legitimately overshoots (measured 100 MB against a 56 MB footprint on a live session).
        // The fragment therefore publishes growth, not this total; what is asserted is only that
        // the walk saw real memory and that the tallies add up to what it reports.
        #expect(footprint > 0)
        #expect(result.totalFootprintBytes > 0)
        #expect(result.tallies.reduce(0) { $0 + $1.footprintBytes } == result.totalFootprintBytes)
    }

    @Test("without a baseline the census still states absolute footprint per tag")
    func absoluteWithoutBaseline() {
        VMRegionCensus.isEnabled = true
        defer { VMRegionCensus.isEnabled = false }
        VMRegionCensus.clearBaseline()

        guard let result = VMRegionCensus.census() else {
            Issue.record("census returned nil while enabled")
            return
        }
        #expect(result.totalFootprintBytes > 0)
        #expect(result.tallies.allSatisfy { $0.deltaBytes == 0 })
        #expect(result.tallies.contains { $0.footprintBytes > 0 })
    }
}
