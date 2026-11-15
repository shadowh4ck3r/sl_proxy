import Darwin
import Foundation

/// Answers "can a TCP listener bind this address right now?" by briefly binding a native socket.
///
/// Used for the status indicator in Proxy Share Settings and by `TunnelController` before it hands
/// a port to sing-box, so the core is not started on a port another proxy tool already holds. The
/// socket sets `SO_REUSEADDR` like Go's listener does, so a port that is only in `TIME_WAIT` counts
/// as free while one with a live listener counts as busy. The probe socket is closed at once;
/// nothing keeps listening.
enum PortProbe {
    /// Upper bound for upward scans (`port`, `port + 1`, ...) so a fully occupied range fails fast.
    static let maxUpwardScan = 512

    /// True when `host:port` can be bound by a TCP listener at this moment.
    static func isAvailable(_ port: Int, host: String = AppSettings.localProxyHost) -> Bool {
        guard (1...65535).contains(port) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port)).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return false }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(fd, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return false }
        return listen(fd, 1) == 0
    }

    /// Same as `isAvailable`, run off the main thread for SwiftUI `.task` callers.
    static func check(_ port: Int, host: String = AppSettings.localProxyHost) async -> Bool {
        await Task.detached(priority: .utility) {
            PortProbe.isAvailable(port, host: host)
        }.value
    }

    /// First port at or above `start` that is available on `host` and passes `accepting`; nil when
    /// nothing within `limit` ports is free.
    static func firstAvailable(
        from start: Int,
        host: String = AppSettings.localProxyHost,
        limit: Int = maxUpwardScan,
        accepting: (Int) -> Bool = { _ in true }
    ) -> Int? {
        var port = start
        var tried = 0
        while port <= 65535, tried < limit {
            if accepting(port), isAvailable(port, host: host) { return port }
            port += 1
            tried += 1
        }
        return nil
    }
}
