import Foundation

/// A 127.0.0.1 listen socket for the test origins, with the one ownership rule they kept getting
/// wrong: the accept thread owns the listen descriptor and is the only one that closes it.
///
/// Every suite runs in one process, and Darwin hands out the lowest free descriptor number, so a
/// number closed by `stop()` belongs to the next socket anyone opens. An accept loop that still held
/// it then accepted, and dropped, a connection meant for another suite's origin, which reached that
/// suite as a request with no response or a connection lost mid-body. `shutdown()` on a listening
/// socket does not wake a blocked `accept` on Darwin, so the loop polls the listener together with a
/// wake pipe that `stop()` writes to.
final class LoopbackListener: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let lock = NSLock()
    private var stopped = false
    /// Set by the accept loop under `lock` as it closes the listener and the pipe, so `stop()` never
    /// writes to a pipe number that may already be another socket's.
    private var closed = false

    init?(backlog: Int32 = 32) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        var wake: [Int32] = [-1, -1]
        guard bound == 0, listen(fd, backlog) == 0,
              withUnsafeMutablePointer(to: &address, {
                  $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
              }) == 0,
              pipe(&wake) == 0,
              fcntl(wake[1], F_SETFL, O_NONBLOCK) == 0 else {
            close(fd)
            for pipeFD in wake where pipeFD >= 0 { close(pipeFD) }
            return nil
        }
        listenFD = fd
        wakeRead = wake[0]
        wakeWrite = wake[1]
        port = UInt16(bigEndian: address.sin_port)
    }

    /// Runs the accept loop on its own thread. `onAccept` gets every accepted descriptor, already set
    /// to `SO_NOSIGPIPE`, and owns it from then on; it returns false to end the loop. It is never
    /// called once `stop()` has run.
    func start(_ onAccept: @escaping (Int32) -> Bool) {
        Thread.detachNewThread { [self] in acceptLoop(onAccept) }
    }

    /// Idempotent. Wakes the accept loop, which closes the listener on its way out.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        guard !closed else { return }
        var byte: UInt8 = 1
        _ = write(wakeWrite, &byte, 1)
    }

    private func acceptLoop(_ onAccept: (Int32) -> Bool) {
        defer {
            lock.lock()
            closed = true
            close(listenFD)
            close(wakeRead)
            close(wakeWrite)
            lock.unlock()
        }
        while true {
            var fds = [
                pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
            ]
            let ready = fds.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), -1) }
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if lock.withLock({ stopped }) || fds[1].revents != 0 { return }
            guard fds[0].revents != 0 else { continue }
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            if lock.withLock({ stopped }) {
                close(fd)
                return
            }
            if !onAccept(fd) { return }
        }
    }
}
