import Foundation

/// Two probes the AD self-test needs and no shipped tool provides: a TCP connect with a
/// deadline, and a single UDP exchange. Both are plain sockets on purpose — `nc` is not
/// guaranteed to be present and `ldapsearch` will not speak UDP at all, which is exactly why
/// the CLDAP netlogon ping has to be built by hand.
nonisolated enum NetProbe {
    static func address(_ host: String, _ port: Int) -> sockaddr_in? {
        var out = sockaddr_in()
        out.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        out.sin_family = sa_family_t(AF_INET)
        out.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, host, &out.sin_addr) == 1 else { return nil }
        return out
    }

    /// Non-blocking connect plus `poll`: a blocking connect would sit on the kernel's own
    /// 75-second timeout, and a self-test with eight ports cannot afford that.
    static func canConnect(_ host: String, _ port: Int, timeout: Double = 3) -> Bool {
        guard var target = address(host, port) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        let started = withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if started == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&descriptor, 1, Int32(timeout * 1000)) > 0 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
        return error == 0
    }

    /// Send one datagram, wait for one answer. nil on timeout.
    static func exchange(_ host: String, _ port: Int, payload: [UInt8], timeout: Double = 3) -> [UInt8]? {
        guard var target = address(host, port) else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var deadline = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
        let sent = payload.withUnsafeBytes { bytes in
            withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let received = recv(fd, &buffer, buffer.count, 0)
        guard received > 0 else { return nil }
        return Array(buffer[0..<received])
    }
}

/// The one piece of AD mode the app has to host itself: DNS on `0.0.0.0:53`, UDP **and** TCP,
/// forwarded to the DC container.
///
/// **Why the app and not `container -p 53:53`.** The moment the first container starts, macOS
/// brings up the vmnet shared bridge and mDNSResponder takes `*:53` as that bridge's DNS
/// proxy. `-p 53:53` then fails with EADDRINUSE and so does anything started afterwards;
/// `SO_REUSEPORT` does not help. The fix is ordering — bind 53 **before** the first container
/// starts and mDNSResponder simply never gets the IPv4 socket. The bridge still comes up and
/// containers still get addresses. `ADController` therefore starts the relay first, always.
///
/// **Why raw sockets and not `NWListener`.** A reply has to leave from the address the query
/// arrived on. This Mac is multi-homed the instant AD mode runs (en0 plus bridge100), so the
/// kernel's route-based source selection answers a query sent to the LAN address from
/// 192.168.64.1 and every resolver on earth discards that as a spoofed reply. `IP_RECVDSTADDR`
/// on the way in and `IP_SENDSRCADDR` on the way out are the fix, and Network.framework does
/// not expose either. The Python prototype needed exactly the same two options.
///
/// **Why a target that can change.** The relay is bound before the DC exists, so it starts
/// with no target and is pointed at the container once it has an address. Re-pointing is a
/// property write — a new DC address or a new LAN address needs no restart.
nonisolated final class DNSRelay: @unchecked Sendable {
    struct Failure: Error, Sendable { let message: String }

    /// macOS: `IP_RECVDSTADDR` and `IP_SENDSRCADDR` are both 7. Spelled out rather than
    /// imported because the two names are the same number and that is worth seeing.
    private static let ipRecvDstAddr: Int32 = 7
    private static let ipSendSrcAddr: Int32 = 7
    private static let cmsgHeaderSize = MemoryLayout<cmsghdr>.size   // 12, already 4-aligned

    private let lock = NSLock()
    private var storedTarget: String?
    private var udpSocket: Int32 = -1
    private var tcpSocket: Int32 = -1
    private var active = false
    private let workers = DispatchQueue(label: "sheep.dnsrelay.work", attributes: .concurrent)
    /// **A hard cap on queries in flight, and it is not a nicety.**
    ///
    /// A custom concurrent queue draws its threads from the process-wide libdispatch pool —
    /// the same pool `Shell.run` uses. While the DC provisions, the container's own resolver
    /// points at the bridge address, which this relay owns, and every one of those lookups
    /// goes unanswered until Samba's DNS is up. Unbounded, each one parks a pooled thread for
    /// the upstream timeout, the pool is exhausted within seconds, and *the app's own
    /// `Shell.run` continuations stop being scheduled at all* — which is how a first start
    /// came to hang forever with no child process to show for it. Excess queries are dropped;
    /// every DNS client on earth retries.
    private let udpSlots = DispatchSemaphore(value: 16)
    private let tcpSlots = DispatchSemaphore(value: 8)

    /// Set before `start`. Called from background threads.
    var onLog: (@Sendable (String) -> Void)?

    /// The DC container's address. nil parks every query until there is one — answering with
    /// a failure would only teach the client to cache it.
    var target: String? {
        get { lock.lock(); defer { lock.unlock() }; return storedTarget }
        set { lock.lock(); storedTarget = newValue; lock.unlock() }
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return active }

    // MARK: Lifecycle

    func start(port: Int = 53) throws {
        lock.lock()
        let alreadyRunning = active
        lock.unlock()
        guard !alreadyRunning else { return }

        let udp = try bind(type: SOCK_DGRAM, port: port, proto: "udp")
        var one: Int32 = 1
        setsockopt(udp, IPPROTO_IP, Self.ipRecvDstAddr, &one, socklen_t(MemoryLayout<Int32>.size))

        let tcp: Int32
        do {
            tcp = try bind(type: SOCK_STREAM, port: port, proto: "tcp")
        } catch {
            close(udp)
            throw error
        }
        guard listen(tcp, 64) == 0 else {
            close(udp); close(tcp)
            throw Failure(message: "DNS relay: listen on tcp/\(port) failed (\(String(cString: strerror(errno)))).")
        }

        lock.lock()
        udpSocket = udp
        tcpSocket = tcp
        active = true
        lock.unlock()

        Thread.detachNewThread { [weak self] in self?.serveUDP(udp) }
        Thread.detachNewThread { [weak self] in self?.serveTCP(tcp) }
        onLog?("DNS relay bound 0.0.0.0:\(port) udp+tcp")
    }

    func stop() {
        lock.lock()
        let (udp, tcp) = (udpSocket, tcpSocket)
        active = false
        udpSocket = -1
        tcpSocket = -1
        storedTarget = nil
        lock.unlock()
        // Closing is what breaks the two blocking loops out of recvmsg/accept.
        if udp >= 0 { close(udp) }
        if tcp >= 0 { close(tcp) }
        if udp >= 0 || tcp >= 0 { onLog?("DNS relay released 0.0.0.0:53") }
    }

    private func bind(type: Int32, port: Int, proto: String) throws -> Int32 {
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else {
            throw Failure(message: "DNS relay: could not create a \(proto) socket (\(String(cString: strerror(errno)))).")
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let ok = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard ok else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw Failure(message: """
            DNS relay: \(proto)/\(port) could not be bound (\(reason)).

            AD mode needs port 53 on this Mac. macOS gives it to mDNSResponder as soon as the \
            first container starts, so the relay has to bind it first — if a container is \
            already running, stop it (container stop --all) and try again.
            """)
        }
        return fd
    }

    // MARK: UDP

    private func serveUDP(_ fd: Int32) {
        let bufferSize = 4096
        let controlSize = 256
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        let control = UnsafeMutableRawPointer.allocate(byteCount: controlSize, alignment: 8)
        let name = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<sockaddr_storage>.size, alignment: 8)
        let iov = UnsafeMutablePointer<iovec>.allocate(capacity: 1)
        defer { buffer.deallocate(); control.deallocate(); name.deallocate(); iov.deallocate() }

        while isRunning {
            iov.pointee = iovec(iov_base: buffer, iov_len: bufferSize)
            var message = msghdr(msg_name: name,
                                 msg_namelen: socklen_t(MemoryLayout<sockaddr_storage>.size),
                                 msg_iov: iov, msg_iovlen: 1,
                                 msg_control: control, msg_controllen: socklen_t(controlSize),
                                 msg_flags: 0)
            let count = recvmsg(fd, &message, 0)
            guard count > 0 else {
                if count < 0, errno == EINTR { continue }
                return                                  // the socket was closed by stop()
            }
            let query = Data(bytes: buffer, count: count)
            let from = Data(bytes: name, count: Int(message.msg_namelen))
            let destination = Self.destinationAddress(in: message)
            guard let upstream = target else { continue }
            guard udpSlots.wait(timeout: .now()) == .success else { continue }
            workers.async { [weak self] in
                defer { self?.udpSlots.signal() }
                self?.relayUDP(query: query, from: from, destination: destination, upstream: upstream, listener: fd)
            }
        }
    }

    /// Walks the control messages for `IP_RECVDSTADDR` — the address this query was actually
    /// sent to, which is the address the answer has to come back from.
    private static func destinationAddress(in message: msghdr) -> in_addr? {
        guard let control = message.msg_control, message.msg_controllen >= UInt32(cmsgHeaderSize) else { return nil }
        var offset = 0
        let total = Int(message.msg_controllen)
        while offset + cmsgHeaderSize <= total {
            let header = control.advanced(by: offset).assumingMemoryBound(to: cmsghdr.self).pointee
            let length = Int(header.cmsg_len)
            guard length >= cmsgHeaderSize, offset + length <= total else { return nil }
            if header.cmsg_level == IPPROTO_IP, header.cmsg_type == ipRecvDstAddr,
               length >= cmsgHeaderSize + MemoryLayout<in_addr>.size {
                return control.advanced(by: offset + cmsgHeaderSize).assumingMemoryBound(to: in_addr.self).pointee
            }
            offset += (length + 3) & ~3                   // CMSG_ALIGN
        }
        return nil
    }

    private func relayUDP(query: Data, from: Data, destination: in_addr?, upstream: String, listener: Int32) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        // Short on purpose: a slot held here is a slot no other query can use.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var server = sockaddr_in()
        server.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        server.sin_family = sa_family_t(AF_INET)
        server.sin_port = UInt16(53).bigEndian
        guard inet_pton(AF_INET, upstream, &server.sin_addr) == 1 else { return }

        let sent = query.withUnsafeBytes { bytes -> Int in
            withUnsafePointer(to: &server) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent > 0 else { return }

        var reply = [UInt8](repeating: 0, count: 4096)
        let received = recv(fd, &reply, reply.count, 0)
        guard received > 0 else { return }   // the DC is not answering yet; the client retries
        sendReply(Array(reply[0..<received]), to: from, source: destination, on: listener)
    }

    /// `IP_SENDSRCADDR`, hand-built: one cmsghdr plus a 4-byte `in_addr`. Without it the
    /// kernel picks the source by route and a multi-homed Mac answers from the wrong address.
    private func sendReply(_ reply: [UInt8], to destination: Data, source: in_addr?, on fd: Int32) {
        let payload = UnsafeMutableRawPointer.allocate(byteCount: reply.count, alignment: 8)
        let name = UnsafeMutableRawPointer.allocate(byteCount: destination.count, alignment: 8)
        let controlSize = ((Self.cmsgHeaderSize + 3) & ~3) + ((MemoryLayout<in_addr>.size + 3) & ~3)
        let control = UnsafeMutableRawPointer.allocate(byteCount: controlSize, alignment: 8)
        let iov = UnsafeMutablePointer<iovec>.allocate(capacity: 1)
        defer { payload.deallocate(); name.deallocate(); control.deallocate(); iov.deallocate() }

        payload.copyMemory(from: reply, byteCount: reply.count)
        destination.withUnsafeBytes { name.copyMemory(from: $0.baseAddress!, byteCount: destination.count) }
        iov.pointee = iovec(iov_base: payload, iov_len: reply.count)

        var message = msghdr(msg_name: name, msg_namelen: socklen_t(destination.count),
                             msg_iov: iov, msg_iovlen: 1,
                             msg_control: nil, msg_controllen: 0, msg_flags: 0)
        // 0.0.0.0 as the destination means the kernel never told us, so let it choose.
        if let source, source.s_addr != 0 {
            let header = control.assumingMemoryBound(to: cmsghdr.self)
            header.pointee.cmsg_len = socklen_t(Self.cmsgHeaderSize + MemoryLayout<in_addr>.size)
            header.pointee.cmsg_level = IPPROTO_IP
            header.pointee.cmsg_type = Self.ipSendSrcAddr
            control.advanced(by: (Self.cmsgHeaderSize + 3) & ~3)
                .assumingMemoryBound(to: in_addr.self).pointee = source
            message.msg_control = control
            message.msg_controllen = socklen_t(controlSize)
        }
        if sendmsg(fd, &message, 0) < 0 {
            // vmnet refuses a spoofed source for container-to-LAN-address traffic; falling
            // back keeps host-local queries working instead of dropping them.
            message.msg_control = nil
            message.msg_controllen = 0
            _ = sendmsg(fd, &message, 0)
        }
    }

    // MARK: TCP

    private func serveTCP(_ fd: Int32) {
        while isRunning {
            var address = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &length) }
            }
            guard client >= 0 else {
                if errno == EINTR { continue }
                return
            }
            guard let upstream = target else { close(client); continue }
            guard tcpSlots.wait(timeout: .now()) == .success else { close(client); continue }
            workers.async { [weak self] in
                defer { self?.tcpSlots.signal() }
                self?.relayTCP(client: client, upstream: upstream)
            }
        }
    }

    /// A straight byte pump: DNS over TCP is length-prefixed and the DC speaks it, so there is
    /// nothing here to parse. TCP hairpins through vmnet without any source-address games.
    private func relayTCP(client: Int32, upstream: String) {
        defer { close(client) }
        let server = socket(AF_INET, SOCK_STREAM, 0)
        guard server >= 0 else { return }
        defer { close(server) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(server, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(53).bigEndian
        guard inet_pton(AF_INET, upstream, &address.sin_addr) == 1 else { return }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard connected else { return }

        let group = DispatchGroup()
        workers.async(group: group) { Self.pump(from: client, to: server) }
        Self.pump(from: server, to: client)
        _ = group.wait(timeout: .now() + 10)
    }

    private static func pump(from source: Int32, to sink: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = recv(source, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            var written = 0
            while written < count {
                let n = buffer.withUnsafeBytes { send(sink, $0.baseAddress!.advanced(by: written), count - written, 0) }
                guard n > 0 else { return }
                written += n
            }
        }
        shutdown(sink, SHUT_WR)
    }
}
