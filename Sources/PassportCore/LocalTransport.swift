import Foundation
import Network
import Darwin

public struct LocalAddress: Identifiable {
    public let interface: String
    public let address: String
    public var id: String { address }
    public static func all() -> [LocalAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [LocalAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: buffer)
            if isPrivate(address) { result.append(LocalAddress(interface: String(cString: entry.pointee.ifa_name), address: address)) }
        }
        return result
    }
    public static func isPrivate(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return false }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168) || (octets[0] == 169 && octets[1] == 254)
    }
}

/// All callbacks and mutations occur on the main queue. One authenticated device owns a session.
public final class LocalTransport {
    public var onControl: ((ControlMessage) -> Void)?
    public var onAudio: ((AudioPacket) -> Void)?
    public var onConnected: ((Bool) -> Void)?
    public var onError: ((String) -> Void)?
    private let hostID: String
    private let lookupKey: (String) -> Data?
    private var tcp: NWListener?
    private var udp: DispatchSourceRead?
    private var udpFD: Int32 = -1
    private var udpLifetime: UInt64 = 0
    private var connection: NWConnection?
    private var channel: SecureChannel?
    private var input = Data()
    private var authenticated = false
    private var peerAddress: in_addr_t = 0
    private var lastReceived: TimeInterval = 0
    private var lastPing: TimeInterval = 0
    private var pending: [UInt32: TimeInterval] = [:]
    private var timer: Timer?
    private var generation: UInt64 = 0
    public private(set) var isConnected = false

    public init(hostID: String, lookupKey: @escaping (String) -> Data?) {
        self.hostID = hostID
        self.lookupKey = lookupKey
    }
    deinit {
        timer?.invalidate()
        tcp?.cancel()
        udp?.cancel()
        if udpFD >= 0 { close(udpFD) }
    }
    public func start(address: String, port: UInt16 = 43821) throws {
        stop()
        guard LocalAddress.all().contains(where: { $0.address == address }), let ip = IPv4Address(address),
              let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw PassportError.invalid("请选择本机的具体局域网 IPv4 地址")
        }
        let endpoint = NWEndpoint.hostPort(host: .ipv4(ip), port: endpointPort)
        let tp = NWParameters.tcp
        tp.requiredLocalEndpoint = endpoint
        tp.allowLocalEndpointReuse = true
        let control = try NWListener(using: tp)
        let fd = try Self.audioSocket(address: address, port: port)
        let audio = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        let lifetime = udpLifetime
        udpFD = fd
        tcp = control
        udp = audio
        control.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        audio.setEventHandler { [weak self] in self?.receiveAudio(fd, lifetime) }
        audio.activate()
        control.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.stop(); self?.onError?("局域网监听失败，请检查地址、端口及本地网络权限") }
        }
        control.start(queue: .main)
        let heartbeat = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(heartbeat, forMode: .common)
        timer = heartbeat
    }
    public func stop() {
        timer?.invalidate()
        timer = nil
        udpLifetime &+= 1
        tcp?.cancel()
        udp?.cancel()
        tcp = nil
        udp = nil
        // Reads and close are serialized on main; invalidate queued handlers before reusing an fd.
        if udpFD >= 0 { close(udpFD); udpFD = -1 }
        disconnect()
    }
    public func disconnect() {
        generation &+= 1
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        input.resetBytes(in: 0..<input.count)
        input.removeAll(keepingCapacity: false)
        channel = nil
        pending.removeAll()
        let wasConnected = authenticated
        authenticated = false
        isConnected = false
        peerAddress = 0
        if wasConnected { onConnected?(false) }
    }
    public func send(_ kind: String, _ body: [String: Any] = [:]) {
        guard authenticated else { return }
        do { try sendSigned(kind, body) }
        catch { fail("控制消息发送失败") }
    }
    private func sendSigned(_ kind: String, _ body: [String: Any]) throws {
        guard var signer = channel, let connection = connection else { throw PassportError.invalid("设备未连接") }
        let (seq, bytes) = try signer.encode(kind: kind, body: body)
        channel = signer
        if kind != "ack" { pending[seq] = ProcessInfo.processInfo.systemUptime }
        let current = generation
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let self = self, self.generation == current else { return }
            if error != nil { self.fail("控制连接发送中断") }
        })
    }
    private static func address(_ connection: NWConnection) -> String? {
        guard case .hostPort(let host, _) = connection.endpoint, case .ipv4(let address) = host else { return nil }
        return address.debugDescription
    }
    private func accept(_ candidate: NWConnection) {
        var peer = in_addr()
        guard connection == nil, let address = Self.address(candidate), LocalAddress.isPrivate(address),
              inet_pton(AF_INET, address, &peer) == 1 else { candidate.cancel(); return }
        generation &+= 1
        let current = generation
        connection = candidate
        peerAddress = peer.s_addr
        lastReceived = ProcessInfo.processInfo.systemUptime
        candidate.stateUpdateHandler = { [weak self, weak candidate] state in
            guard let self = self, self.generation == current, candidate === self.connection else { return }
            switch state {
            case .ready: self.receive(current)
            case .failed, .cancelled: self.fail("设备连接中断")
            default: break
            }
        }
        candidate.start(queue: .main)
    }
    private func receive(_ current: UInt64) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] bytes, _, complete, error in
            guard let self = self, self.generation == current else { return }
            if let bytes = bytes {
                self.input.append(bytes)
                while let newline = self.input.firstIndex(of: 10) {
                    guard newline <= 8192 else { self.fail("控制消息过长"); return }
                    let line = self.input.subdata(in: 0..<newline)
                    self.input.removeSubrange(0...newline)
                    do { try self.handleLine(line) }
                    catch { self.fail("设备控制消息验证失败"); return }
                    guard self.generation == current else { return }
                }
                if self.input.count > 8192 { self.fail("控制缓冲超限"); return }
            }
            if complete || error != nil { self.fail("设备连接已断开"); return }
            self.receive(current)
        }
    }
    private func handleLine(_ line: Data) throws {
        if channel == nil {
            guard let hello = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  hello["v"] as? Int == 1, hello["type"] as? String == "hello",
                  hello["host"] as? String == hostID,
                  let device = hello["device"] as? String, device.count == 32, Data(hex: device)?.count == 16,
                  let nonce = hello["nonce"] as? String, nonce.count == 32, Data(hex: nonce)?.count == 16,
                  let key = lookupKey(device), key.count == 32 else { throw PassportError.invalid("设备未配对") }
            let hostNonce = try Authentication.random(16).hex
            let tag = Authentication.mac("welcome|\(device)|\(hostID)|\(nonce)|\(hostNonce)", key: key)
            channel = SecureChannel(session: hostNonce, key: Authentication.sessionKey(key: key, deviceNonce: nonce, hostNonce: hostNonce))
            var reply = try JSONSerialization.data(withJSONObject: ["v": 1, "type": "welcome", "nonce": hostNonce, "mac": tag])
            reply.append(10)
            connection?.send(content: reply, completion: .contentProcessed { _ in })
            return
        }
        guard var signer = channel else { return }
        let message = try signer.decode(line)
        channel = signer
        lastReceived = ProcessInfo.processInfo.systemUptime
        if message.kind == "ack" {
            if let number = message.body["seq"] as? NSNumber { pending.removeValue(forKey: number.uint32Value) }
            return
        }
        try sendSigned("ack", ["seq": message.sequence])
        if message.duplicate { return }
        if !authenticated {
            guard message.kind == "ready" else { throw PassportError.invalid("缺少设备密钥证明") }
            authenticated = true
            isConnected = true
            lastPing = lastReceived
            onConnected?(true)
        } else if message.kind == "ready" {
            throw PassportError.invalid("重复握手")
        } else if message.kind != "ping" {
            onControl?(message)
        }
    }
    private static func audioSocket(address: String, port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw PassportError.invalid("无法创建音频 UDP 监听") }
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address, &local.sin_addr) == 1 else {
            close(fd); throw PassportError.invalid("音频 UDP 地址无效")
        }
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            close(fd); throw PassportError.invalid("音频 UDP 监听失败，请检查所选地址与端口")
        }
        return fd
    }
    private func receiveAudio(_ fd: Int32, _ lifetime: UInt64) {
        // UDP source ports may change between recording rounds. Authenticate each datagram.
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 1025) { buffer in
            for _ in 0..<64 {
                guard udpLifetime == lifetime, udpFD == fd else { return }
                var peer = sockaddr_in(), size = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, buffer.baseAddress, buffer.count, 0, $0, &size)
                    }
                }
                if count < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    if code != EAGAIN && code != EWOULDBLOCK {
                        stop(); onError?("音频接收中断，请重新启动连接")
                    }
                    return
                }
                guard count >= 64, count <= 1024, peer.sin_family == sa_family_t(AF_INET),
                      authenticated, peer.sin_addr.s_addr == peerAddress, let channel = channel else { continue }
                // AudioPacket copies its PCM; the borrowed receive buffer never escapes this call.
                let bytes = Data(bytesNoCopy: buffer.baseAddress!, count: count, deallocator: .none)
                if let packet = try? AudioPacket(data: bytes, session: channel.session, key: channel.key) {
                    onAudio?(packet)
                }
            }
        }
    }
    private func tick() {
        guard connection != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastReceived > (authenticated ? 3 : 2) || pending.values.contains(where: { now - $0 > 2 }) {
            fail("设备心跳或控制确认超时")
            return
        }
        if authenticated, now - lastPing >= 1 {
            lastPing = now
            send("ping")
        }
    }
    private func fail(_ reason: String) { disconnect(); onError?(reason) }
}
