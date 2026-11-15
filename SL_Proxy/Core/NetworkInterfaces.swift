import Darwin
import Foundation

/// Reads the addresses of the device's network interfaces (`getifaddrs`). Used to bind the Proxy
/// Share listener to Wi-Fi (`en0`) or cellular (`pdp_ip0`, ...) and to show that address in
/// Proxy Share Settings.
enum NetworkInterfaces {
    /// IPv4 address of the up-and-running BSD interface `name`, or nil when it has none.
    static func ipv4Address(ofInterface name: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let head = list else { return nil }
        defer { freeifaddrs(list) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            let flags = entry.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_RUNNING) != 0 else { continue }
            guard String(cString: entry.pointee.ifa_name) == name else { continue }
            guard let generic = entry.pointee.ifa_addr,
                  generic.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var inet = generic.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &inet.sin_addr, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            return String(cString: text)
        }
        return nil
    }

    /// IPv4 address of the first interface behind `interface` that currently has one.
    static func ipv4Address(of interface: ShareInterface) -> String? {
        for name in interface.bsdNames {
            if let address = ipv4Address(ofInterface: name) { return address }
        }
        return nil
    }
}
