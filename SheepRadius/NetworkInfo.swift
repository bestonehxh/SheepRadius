import Foundation

nonisolated enum LocalNetwork {
    /// `String(cString: [CChar])` is deprecated — truncate at the NUL ourselves. (The
    /// `UnsafePointer<CChar>` overload used for `ifa_name` is not deprecated.)
    static func string(fromCChars buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The local IPv4 the kernel would use to reach `host` — a connected UDP
    /// socket picks the outgoing interface without sending a packet. This is
    /// the address that belongs in device-side copy commands; en0's address
    /// is useless to a switch on a different lab subnet.
    static func ipv4(toReach host: String) -> String? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM,
                             ai_protocol: IPPROTO_UDP, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "69", &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }

        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }
        guard Darwin.connect(sock, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
            return nil
        }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &length) == 0
            }
        }
        guard ok else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var address = local.sin_addr
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else {
            return nil
        }
        let ip = string(fromCChars: buffer)
        return ip == "0.0.0.0" ? nil : ip
    }

    /// Best-effort primary IPv4 (en0 first) for building device-side commands.
    static func primaryIPv4() -> String? {
        var addresses: [(name: String, ip: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            // getifaddrs may return entries with a NULL ifa_addr (e.g. some
            // tunnel interfaces) — dereferencing one crashes.
            guard let addr = interface.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = string(fromCChars: host)
                // 169.254 is excluded for the same reason `allIPv4` excludes it: a self-assigned
                // address is what en0 gets for a few seconds while DHCP fails or Wi-Fi
                // reconnects. Returning it made `AddressMonitor` raise the full "every NAS,
                // supplicant and directory client must be reconfigured" notice for a hiccup —
                // the cry-wolf case the type exists to avoid — and put an address in the Status
                // tile that `allIPv4` would not list.
                if !ip.hasPrefix("127."), !ip.hasPrefix("169.254.") {
                    addresses.append((name, ip))
                }
            }
        }
        return (addresses.first { $0.name == "en0" } ?? addresses.first)?.ip
    }
}

/// One "this Mac moved" event, kept until it is dismissed.
///
/// It matters because every device in the lab is pointed at an address, not at a name: the
/// notebook's DNS, iMaster's *Primary server address*, the NAS entries under Clients. When the
/// Mac goes from Wi-Fi to a cable, all of them are now pointed at nothing, and nothing in any
/// of those products says so — they simply stop working. The owner did exactly this on
/// 18 Sep 2026 (192.168.1.34 → 10.10.36.117) and spent the afternoon on it.
nonisolated struct AddressChange: Equatable, Sendable {
    var from: String
    var to: String
    var at: Date
}

/// The pure half of the address watcher: fed an address, it says whether that is news.
///
/// Separated from the timer so the interesting part is testable. The rules are all "do not cry
/// wolf" rules — a lab Mac drops an interface for a second more often than it changes network:
///
/// - The **first** address ever seen is not a change. There is nothing to tell anyone.
/// - `nil` (no usable IPv4 at all — the cable is out, Wi-Fi is reconnecting) is **not** a
///   change and does not clear what is already known. The next real address is compared
///   against the last real one, so unplugging and replugging the same cable stays silent.
/// - The same address again is not a change, however often it is polled.
/// - A change **replaces** an undismissed one rather than queueing: A→B then B→C reads as
///   A→C, which is what a person needs to retype into a device.
nonisolated struct AddressMonitor: Equatable, Sendable {
    /// The last usable address seen, which is what the next one is compared against.
    private(set) var current: String?
    /// The outstanding notice, or nil when there is none to show.
    private(set) var change: AddressChange?

    init(current: String? = nil) { self.current = current }

    /// Returns the change to announce, or nil when there is nothing to say.
    @discardableResult
    mutating func observe(_ address: String?, at time: Date) -> AddressChange? {
        guard let address, !address.isEmpty else { return nil }
        guard let previous = current else {
            current = address
            return nil
        }
        guard previous != address else { return nil }
        current = address
        // Collapse onto the address the notice started from, so the "from" stays the one the
        // devices in the lab are still configured with.
        let origin = change?.from ?? previous
        let announced = AddressChange(from: origin, to: address, at: time)
        change = origin == address ? nil : announced      // moved back to where it started
        return change
    }

    mutating func dismiss() { change = nil }
}

extension LocalNetwork {
    /// Every non-loopback IPv4 on this Mac — a lab machine is usually on several segments at once,
    /// and the NAS needs whichever one it can actually route to.
    static func allIPv4() -> [(name: String, ip: String)] {
        var out: [(name: String, ip: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = string(fromCChars: host)
            if !ip.hasPrefix("127."), !ip.hasPrefix("169.254.") { out.append((String(cString: interface.ifa_name), ip)) }
        }
        return out
    }
}
