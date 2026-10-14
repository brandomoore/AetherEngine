import Foundation
@testable import AetherEngine

/// Minimal UDF 2.50 image builder for tests. Sector size 2048. Exercises a
/// metadata partition and a fragmented file. Builder offsets mirror UDFReader.
enum UDFFixture {
    static let ss = 2048

    static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v>>8)&0xff)] }
    static func le32(_ v: Int) -> [UInt8] { [UInt8(v&0xff),UInt8((v>>8)&0xff),UInt8((v>>16)&0xff),UInt8((v>>24)&0xff)] }
    static func le64(_ v: Int) -> [UInt8] { le32(v & 0xffffffff) + le32(v >> 32) }

    /// Write a 16-byte descriptor tag at the front of `body` (which already has
    /// 16 zero bytes reserved at [0..16]); fills id, version, location, checksum.
    static func tag(_ id: Int, location: Int, into body: inout [UInt8]) {
        body[0..<2]  = ArraySlice(le16(id))
        body[2..<4]  = ArraySlice(le16(0x0200))     // descriptor version 2
        body[12..<16] = ArraySlice(le32(location))  // TagLocation
        // CRC length 0 (reader ignores CRC); checksum over bytes 0-3 and 5-15.
        var sum = 0
        for i in 0..<16 where i != 4 { sum = (sum + Int(body[i])) & 0xff }
        body[4] = UInt8(sum)
    }

    /// extent_ad: length(bytes), location(sector).
    static func extentAD(lenBytes: Int, location: Int) -> [UInt8] { le32(lenBytes) + le32(location) }
    /// long_ad: lenBytes, block, partitionRef.
    static func longAD(lenBytes: Int, block: Int, partRef: Int) -> [UInt8] {
        le32(lenBytes) + le32(block) + le16(partRef) + [UInt8](repeating:0,count:6)
    }
    /// long_ad with an explicit extent type in the high 2 bits of the length field
    /// (type 3 = allocation-extent continuation pointer to an AED).
    static func longADTyped(type: Int, lenBytes: Int, block: Int, partRef: Int) -> [UInt8] {
        le32(((type & 0x3) << 30) | (lenBytes & 0x3fffffff)) + le32(block) + le16(partRef) + [UInt8](repeating:0,count:6)
    }
    /// short_ad: lenBytes, block.
    static func shortAD(lenBytes: Int, block: Int) -> [UInt8] { le32(lenBytes) + le32(block) }

    /// Allocation Extent Descriptor (tag 258) holding one run of allocation descriptors.
    static func aed(location: Int, ads: [UInt8]) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 24 + ads.count)
        tag(258, location: location, into: &b)
        b[20..<24] = ArraySlice(le32(ads.count))   // LengthOfAllocationDescriptors (@24: the descriptors)
        for (i, v) in ads.enumerated() { b[24 + i] = v }
        return b
    }

    /// An Extended File Entry (tag 266). `fileType` 4=dir 5=file. `adType` 0=short_ad.
    /// `ads` is the concatenated allocation-descriptor bytes. `infoLen` is the file's
    /// data length in bytes.
    static func efe(location: Int, fileType: Int, partRefOfSelf: Int, adType: Int, infoLen: Int, ads: [UInt8]) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 216 + ads.count)
        tag(266, location: location, into: &b)
        // ICBTag @16: FileType @ 16+11=27, Flags @ 16+18=34
        b[27] = UInt8(fileType)
        b[34..<36] = ArraySlice(le16(adType))
        b[56..<64] = ArraySlice(le64(infoLen))         // InformationLength
        b[208..<212] = ArraySlice(le32(0))             // L_EA
        b[212..<216] = ArraySlice(le32(ads.count))     // L_AD
        for (i, v) in ads.enumerated() { b[216 + i] = v }
        return b
    }

    /// A File Identifier Descriptor (tag 257). Returns padded-to-4 bytes.
    static func fid(location: Int, name: String, isDir: Bool, childBlock: Int, childPartRef: Int) -> [UInt8] {
        let nameBytes: [UInt8] = name.isEmpty ? [] : ([0x08] + Array(name.utf8)) // 8-bit dstring
        let lfi = nameBytes.count
        var b = [UInt8](repeating: 0, count: 38 + lfi)
        tag(257, location: location, into: &b)
        b[18] = isDir ? 0x02 : 0x00                    // FileCharacteristics
        b[19] = UInt8(lfi)                             // L_FI
        b[20..<36] = ArraySlice(longAD(lenBytes: ss, block: childBlock, partRef: childPartRef)) // ICB
        b[36..<38] = ArraySlice(le16(0))               // L_IU
        for (i, v) in nameBytes.enumerated() { b[38 + i] = v }
        while b.count % 4 != 0 { b.append(0) }         // pad to 4
        return b
    }

    /// Build the complete BD image. Returns (bytes). Files placed:
    /// metadata vblock layout: 1=FSD, 2=rootDirEFE, 3=rootDirData,
    /// 4=BDMV EFE, 5=BDMV data, 6=PLAYLIST EFE, 7=PLAYLIST data,
    /// 8=STREAM EFE, 9=STREAM data, 10=mpls EFE, 11=mpls data,
    /// 12=m2ts EFE. m2ts data is two physical extents (fragmented), placed in
    /// the physical partition AFTER the metadata region.
    /// `m2tsViaAED`: place the m2ts EFE's second extent behind a type-3 allocation-extent
    /// continuation (an AED at vblock 13) instead of inline, to exercise AED chaining.
    /// `clpiBytes`: add `BDMV/CLIPINF/00001.clpi` (vblocks 14-17, one sector of data). A CLPI fixture
    /// carries a real stream whose EP map points into it, so the m2ts is then written whole rather than
    /// a sector per extent; each half has to fit the 10 blocks between the two extents.
    static func make(mplsBytes: [UInt8], m2tsBytes: [UInt8], m2tsViaAED: Bool = false,
                     clpiBytes: [UInt8]? = nil) -> Data {
        let partStart = 270
        // metadata partition extent = physical blocks 2.. of partition 0.
        // virtual block V -> physical sector partStart + 2 + V.
        func phys(_ vblock: Int) -> Int { partStart + 2 + vblock }

        // --- helpers to place a sector ---
        var image = [UInt8](repeating: 0, count: (partStart + 64) * ss)
        func put(_ bytes: [UInt8], atSector s: Int) {
            precondition((s+1)*ss <= image.count || bytes.count <= ss)
            for (i, v) in bytes.enumerated() where i < ss { image[s*ss + i] = v }
        }
        // UDF: metadata-partition tags record the virtual block number in TagLocation.
        func putV(_ bytes: [UInt8], vblock: Int) { put(bytes, atSector: phys(vblock)) }

        // m2ts: two physical extents past the metadata region (partition-relative blocks 40 and 50).
        let frag1Block = 40, frag2Block = 50   // physical partition (ref 0) blocks
        let half = m2tsBytes.count / 2
        let m2tsExt1 = Array(m2tsBytes[0..<half])
        let m2tsExt2 = Array(m2tsBytes[half...])
        if clpiBytes != nil {
            precondition(m2tsExt2.count <= 10 * ss, "a whole-stream fixture half must fit 10 blocks")
            for (i, v) in m2tsExt1.enumerated() { image[(partStart + frag1Block) * ss + i] = v }
            for (i, v) in m2tsExt2.enumerated() { image[(partStart + frag2Block) * ss + i] = v }
        } else {
            put(padTo(m2tsExt1, ss * 4), atSector: partStart + frag1Block)
            put(padTo(m2tsExt2, ss * 4), atSector: partStart + frag2Block)
        }

        // mpls data (virtual block 11)
        putV(padTo(mplsBytes, ss), vblock: 11)

        // --- EFEs (all resident in the metadata partition) ---
        // m2ts EFE (vblock 12): the large stream data lives in the PHYSICAL partition, so it is
        // referenced via long_ad (adType 1) carrying partition ref 0 -- exactly how real UDF 2.50
        // Blu-rays store m2ts (a metadata-partition FE pointing at physical data). short_ad here
        // would be metadata-partition-relative and could not address data past the metadata region.
        if m2tsViaAED {
            // Inline: extent 1 (physical) + a type-3 continuation pointer to an AED at vblock 13.
            let m2tsADs = longAD(lenBytes: m2tsExt1.count, block: frag1Block, partRef: 0)
                        + longADTyped(type: 3, lenBytes: ss, block: 13, partRef: 1)
            putV(efe(location: 12, fileType: 5, partRefOfSelf: 1, adType: 1, infoLen: m2tsBytes.count, ads: m2tsADs), vblock: 12)
            // AED (vblock 13): extent 2 (physical).
            putV(padTo(aed(location: 13, ads: longAD(lenBytes: m2tsExt2.count, block: frag2Block, partRef: 0)), ss), vblock: 13)
        } else {
            let m2tsADs = longAD(lenBytes: m2tsExt1.count, block: frag1Block, partRef: 0)
                        + longAD(lenBytes: m2tsExt2.count, block: frag2Block, partRef: 0)
            putV(efe(location: 12, fileType: 5, partRefOfSelf: 1, adType: 1, infoLen: m2tsBytes.count, ads: m2tsADs), vblock: 12)
        }
        // mpls EFE (vblock 10): long_ad (adType=1) into metadata partition ref 1, block 11.
        putV(efe(location: 10, fileType: 5, partRefOfSelf: 1, adType: 1, infoLen: mplsBytes.count,
                 ads: longAD(lenBytes: mplsBytes.count, block: 11, partRef: 1)), vblock: 10)

        // STREAM dir data (vblock 9): FID "00001.m2ts" -> m2ts EFE (vblock 12, partRef 1) + parent
        let streamData = fid(location: 9, name: "", isDir: true, childBlock: 4, childPartRef: 1) // parent placeholder
                       + fid(location: 9, name: "00001.m2ts", isDir: false, childBlock: 12, childPartRef: 1)
        putV(padTo(streamData, ss), vblock: 9)
        putV(efe(location: 8, fileType: 4, partRefOfSelf: 1, adType: 1, infoLen: streamData.count,
                 ads: longAD(lenBytes: ss, block: 9, partRef: 1)), vblock: 8)

        // PLAYLIST dir data (vblock 7): FID "00000.mpls" -> mpls EFE (vblock 10)
        let plData = fid(location: 7, name: "", isDir: true, childBlock: 4, childPartRef: 1)
                   + fid(location: 7, name: "00000.mpls", isDir: false, childBlock: 10, childPartRef: 1)
        putV(padTo(plData, ss), vblock: 7)
        putV(efe(location: 6, fileType: 4, partRefOfSelf: 1, adType: 1, infoLen: plData.count,
                 ads: longAD(lenBytes: ss, block: 7, partRef: 1)), vblock: 6)

        // CLIPINF dir (vblocks 14-15) and its one clpi (EFE 16, data 17), when asked for.
        if let clpiBytes {
            putV(padTo(clpiBytes, ss), vblock: 17)
            putV(efe(location: 16, fileType: 5, partRefOfSelf: 1, adType: 1, infoLen: clpiBytes.count,
                     ads: longAD(lenBytes: clpiBytes.count, block: 17, partRef: 1)), vblock: 16)
            let clipInfoData = fid(location: 15, name: "", isDir: true, childBlock: 4, childPartRef: 1)
                             + fid(location: 15, name: "00001.clpi", isDir: false, childBlock: 16, childPartRef: 1)
            putV(padTo(clipInfoData, ss), vblock: 15)
            putV(efe(location: 14, fileType: 4, partRefOfSelf: 1, adType: 1, infoLen: clipInfoData.count,
                     ads: longAD(lenBytes: ss, block: 15, partRef: 1)), vblock: 14)
        }

        // BDMV dir data (vblock 5): FIDs PLAYLIST (vblock 6) and STREAM (vblock 8), and CLIPINF (14)
        var bdmvData = fid(location: 5, name: "", isDir: true, childBlock: 2, childPartRef: 1)
                     + fid(location: 5, name: "PLAYLIST", isDir: true, childBlock: 6, childPartRef: 1)
                     + fid(location: 5, name: "STREAM", isDir: true, childBlock: 8, childPartRef: 1)
        if clpiBytes != nil {
            bdmvData += fid(location: 5, name: "CLIPINF", isDir: true, childBlock: 14, childPartRef: 1)
        }
        putV(padTo(bdmvData, ss), vblock: 5)
        putV(efe(location: 4, fileType: 4, partRefOfSelf: 1, adType: 1, infoLen: bdmvData.count,
                 ads: longAD(lenBytes: ss, block: 5, partRef: 1)), vblock: 4)

        // root dir data (vblock 3): FID BDMV (vblock 4)
        let rootData = fid(location: 3, name: "", isDir: true, childBlock: 2, childPartRef: 1)
                     + fid(location: 3, name: "BDMV", isDir: true, childBlock: 4, childPartRef: 1)
        putV(padTo(rootData, ss), vblock: 3)
        putV(efe(location: 2, fileType: 4, partRefOfSelf: 1, adType: 1, infoLen: rootData.count,
                 ads: longAD(lenBytes: ss, block: 3, partRef: 1)), vblock: 2)

        // FSD (vblock 1): RootDirectoryICB -> root dir EFE (vblock 2, partRef 1)
        var fsd = [UInt8](repeating: 0, count: ss)
        tag(256, location: 1, into: &fsd)
        fsd[400..<416] = ArraySlice(longAD(lenBytes: ss, block: 2, partRef: 1))
        putV(fsd, vblock: 1)

        writeVolume(into: &image, partStart: partStart)

        return Data(image)
    }

    /// A DVD-Video image with no ISO9660 bridge: UDF only, `VIDEO_TS` holding `files` in order. Directories
    /// live in the metadata partition as in `make`; each file's data is one run in the physical partition
    /// from block 40, unless it is named in `fragmented`, whose two halves are recorded as runs that do not
    /// continue each other.
    /// metadata vblock layout: 1=FSD, 2=root EFE, 3=root data, 4=VIDEO_TS EFE, 5=VIDEO_TS data, 6+i=file EFE.
    static func makeDVD(files: [(name: String, bytes: [UInt8])], fragmented: Set<String> = []) -> Data {
        let partStart = 270
        func phys(_ vblock: Int) -> Int { partStart + 2 + vblock }
        var block = 40
        var placed: [(name: String, ads: [UInt8], length: Int)] = []
        var data: [(block: Int, bytes: [UInt8])] = []
        for file in files {
            let sectors = { (count: Int) in max(1, (count + ss - 1) / ss) }
            if fragmented.contains(file.name) {
                let half = (file.bytes.count / 2 / ss) * ss
                let first = Array(file.bytes[0..<half]), second = Array(file.bytes[half...])
                data.append((block, first))
                let gap = block + sectors(first.count) + 1  // one block of nothing between the runs
                data.append((gap, second))
                placed.append((file.name, longAD(lenBytes: first.count, block: block, partRef: 0)
                                          + longAD(lenBytes: second.count, block: gap, partRef: 0), file.bytes.count))
                block = gap + sectors(second.count)
            } else {
                data.append((block, file.bytes))
                placed.append((file.name, longAD(lenBytes: file.bytes.count, block: block, partRef: 0), file.bytes.count))
                block += sectors(file.bytes.count)
            }
        }
        var image = [UInt8](repeating: 0, count: (partStart + max(64, block + 1)) * ss)
        func put(_ bytes: [UInt8], atSector s: Int) {
            for (i, v) in bytes.enumerated() where i < ss { image[s*ss + i] = v }
        }
        func putV(_ bytes: [UInt8], vblock: Int) { put(bytes, atSector: phys(vblock)) }
        for run in data {
            for (i, v) in run.bytes.enumerated() { image[(partStart + run.block) * ss + i] = v }
        }

        var dirData = fid(location: 5, name: "", isDir: true, childBlock: 2, childPartRef: 1)
        for (i, file) in placed.enumerated() {
            putV(efe(location: 6 + i, fileType: 5, partRefOfSelf: 1, adType: 1, infoLen: file.length, ads: file.ads),
                 vblock: 6 + i)
            dirData += fid(location: 5, name: file.name, isDir: false, childBlock: 6 + i, childPartRef: 1)
        }
        precondition(dirData.count <= ss, "VIDEO_TS listing must fit one sector")
        putV(padTo(dirData, ss), vblock: 5)
        putV(efe(location: 4, fileType: 4, partRefOfSelf: 1, adType: 1, infoLen: dirData.count,
                 ads: longAD(lenBytes: ss, block: 5, partRef: 1)), vblock: 4)

        let rootData = fid(location: 3, name: "", isDir: true, childBlock: 2, childPartRef: 1)
                     + fid(location: 3, name: "VIDEO_TS", isDir: true, childBlock: 4, childPartRef: 1)
        putV(padTo(rootData, ss), vblock: 3)
        putV(efe(location: 2, fileType: 4, partRefOfSelf: 1, adType: 1, infoLen: rootData.count,
                 ads: longAD(lenBytes: ss, block: 3, partRef: 1)), vblock: 2)

        var fsd = [UInt8](repeating: 0, count: ss)
        tag(256, location: 1, into: &fsd)
        fsd[400..<416] = ArraySlice(longAD(lenBytes: ss, block: 2, partRef: 1))
        putV(fsd, vblock: 1)

        writeVolume(into: &image, partStart: partStart)
        return Data(image)
    }

    /// The volume around the metadata partition: its Metadata File, the LVD, the Partition Descriptor and
    /// the AVDP. Shared by every image here; the metadata partition is physical blocks 2..33.
    private static func writeVolume(into image: inout [UInt8], partStart: Int) {
        func put(_ bytes: [UInt8], atSector s: Int) {
            for (i, v) in bytes.enumerated() where i < ss { image[s*ss + i] = v }
        }
        // --- Metadata File (E)FE at physical block 0 of partition 0 (sector partStart) ---
        // one extent: metadata partition = physical blocks 2.. (short_ad, partition-relative)
        let metaExtentBlocks = 32
        let metaFile = efe(location: 0, fileType: 5, partRefOfSelf: 0, adType: 0,
                           infoLen: metaExtentBlocks * ss,
                           ads: shortAD(lenBytes: metaExtentBlocks * ss, block: 2))
        put(metaFile, atSector: partStart + 0)

        // --- LVD (sector 258) ---
        var lvd = [UInt8](repeating: 0, count: ss)
        tag(6, location: 258, into: &lvd)
        lvd[212..<216] = ArraySlice(le32(ss))                 // LogicalBlockSize
        lvd[248..<264] = ArraySlice(longAD(lenBytes: ss, block: 1, partRef: 1)) // FSD long_ad (metadata part)
        // partition maps
        var maps = [UInt8]()
        // index 0: Type 1 -> partition number 0
        maps += [1, 6] + le16(0) + le16(0)
        // index 1: Type 2 metadata, 64 bytes
        var t2 = [UInt8](repeating: 0, count: 64)
        t2[0] = 2; t2[1] = 64
        // PartitionTypeIdentifier regid (offset 4) "*UDF Metadata Partition"
        let mid = Array("*UDF Metadata Partition".utf8)
        for (i,v) in mid.enumerated() where i < 23 { t2[5 + i] = v } // [4]=flags,[5..] id
        t2[36..<38] = ArraySlice(le16(0))                     // VolumeSequenceNumber
        t2[38..<40] = ArraySlice(le16(0))                     // PartitionNumber (physical part 0)
        t2[40..<44] = ArraySlice(le32(0))                     // MetadataFileLocation = block 0 of part 0
        maps += t2
        lvd[264..<268] = ArraySlice(le32(maps.count))         // MapTableLength
        lvd[268..<272] = ArraySlice(le32(2))                  // NumberofPartitionMaps
        for (i,v) in maps.enumerated() { lvd[440 + i] = v }
        put(lvd, atSector: 258)

        // --- Partition Descriptor (sector 257) ---
        var pd = [UInt8](repeating: 0, count: ss)
        tag(5, location: 257, into: &pd)
        pd[22..<24] = ArraySlice(le16(0))                     // PartitionNumber 0
        pd[188..<192] = ArraySlice(le32(partStart))           // PartitionStartingLocation
        pd[192..<196] = ArraySlice(le32(128))                 // PartitionLength (sectors, ample)
        put(pd, atSector: 257)

        // --- AVDP (sector 256) -> VDS at sector 257, length 2 sectors ---
        var avdp = [UInt8](repeating: 0, count: ss)
        tag(2, location: 256, into: &avdp)
        avdp[16..<24] = ArraySlice(extentAD(lenBytes: 2*ss, location: 257)) // MainVDS extent
        put(avdp, atSector: 256)
    }

    static func padTo(_ b: [UInt8], _ n: Int) -> [UInt8] {
        b.count >= n ? b : b + [UInt8](repeating: 0, count: n - b.count)
    }
}
