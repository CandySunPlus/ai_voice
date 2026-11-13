import Foundation
import Darwin
import CryptoKit
import PassportCore

/// Uses the public transport and real local TCP/UDP sockets; never opens audio or sends keys.
enum TransportRoundChecks {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
    // Every access to stored is protected by lock.
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Error?
        var error: Error? { lock.lock(); defer { lock.unlock() }; return stored }
        func fail(_ error: Error) { lock.lock(); defer { lock.unlock() }; if stored == nil { stored = error } }
    }
    @MainActor
    static func run() async throws {
        guard let address = LocalAddress.all().first?.address else { throw Failure("集成检查需要本机局域网 IPv4") }
        let reservation = try boundSocket(address: address, type: SOCK_STREAM)
        let port = try localPort(reservation)
        close(reservation)
        let host = String(repeating: "1", count: 32), device = String(repeating: "2", count: 32)
        let nonce = String(repeating: "3", count: 32), key = Data(0..<32)
        let server = LocalTransport(hostID: host) { $0 == device ? key : nil }
        let authenticated = DispatchSemaphore(value: 0), first = DispatchSemaphore(value: 0), second = DispatchSemaphore(value: 0)
        let outcome = Outcome(), worker = DispatchGroup()
        var received: [UInt32] = []
        server.onError = { outcome.fail(Failure($0)) }
        server.onConnected = { if $0 { authenticated.signal() } }
        server.onAudio = { packet in
            guard packet.sequence == 1, packet.pcm == (packet.recording == 1 ? Data([101, 0]) : Data([202, 0])) else {
                outcome.fail(Failure("音频内容或序号错误")); return
            }
            received.append(packet.recording)
            if packet.recording == 1 { first.signal() }
            if packet.recording == 2 { second.signal() }
        }
        try server.start(address: address, port: port)
        defer { server.stop() }
        worker.enter()
        DispatchQueue.global().async {
            defer { worker.leave() }
            do {
                let tcp = try connect(address: address, port: port)
                defer { close(tcp) }
                let one = try boundSocket(address: address, type: SOCK_DGRAM), two = try boundSocket(address: address, type: SOCK_DGRAM)
                var firstOpen = true
                defer { if firstOpen { close(one) }; close(two) }
                guard try localPort(one) != localPort(two) else { throw Failure("测试未使用两个独立 UDP 源端口") }
                var hello = try JSONSerialization.data(withJSONObject: ["v": 1, "type": "hello", "host": host, "device": device, "nonce": nonce])
                hello.append(10)
                try writeAll(tcp, hello)
                let welcome = try readLine(tcp)
                guard let reply = try JSONSerialization.jsonObject(with: welcome) as? [String: Any],
                      let session = reply["nonce"] as? String, let tag = reply["mac"] as? String,
                      Authentication.valid(tag, bytes: Data("welcome|\(device)|\(host)|\(nonce)|\(session)".utf8), key: key),
                      let sessionBytes = Data(hex: session) else { throw Failure("握手响应无效") }
                let sessionKey = Authentication.sessionKey(key: key, deviceNonce: nonce, hostNonce: session)
                var channel = SecureChannel(session: session, key: sessionKey)
                let (_, ready) = try channel.encode(kind: "ready", body: [:])
                try writeAll(tcp, ready)
                guard authenticated.wait(timeout: .now() + 1) == .success else { throw Failure("设备认证未完成") }
                try sendAudio(one, address: address, port: port, session: sessionBytes, key: sessionKey, recording: 1, pcm: 101)
                guard first.wait(timeout: .now() + 1) == .success else { throw Failure("首轮音频未送达") }
                close(one); firstOpen = false
                try sendAudio(two, address: address, port: port, session: sessionBytes, key: sessionKey, recording: 2, pcm: 202)
                guard second.wait(timeout: .now() + 1) == .success else { throw Failure("更换 UDP 源端口后，第二轮音频未送达") }
            } catch { outcome.fail(error) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            worker.notify(queue: .main) {
                if let error = outcome.error { continuation.resume(throwing: error) }
                else if received != [1, 2] { continuation.resume(throwing: Failure("连续录音轮次错误：\(received)")) }
                else { continuation.resume() }
            }
        }
        print("通过连续录音 UDP 集成检查：同一认证连接、两个源端口、两轮 PCM 均完整送达")
    }
    private static func endpoint(_ address: String, _ port: UInt16) throws -> sockaddr_in {
        var peer = sockaddr_in()
        peer.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        peer.sin_family = sa_family_t(AF_INET); peer.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address, &peer.sin_addr) == 1 else { throw Failure("测试地址无效") }
        return peer
    }
    private static func boundSocket(address: String, type: Int32) throws -> Int32 {
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { throw Failure("无法创建测试 socket") }
        var peer = try endpoint(address, 0)
        let result = withUnsafePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { close(fd); throw Failure("无法绑定测试 socket") }
        return fd
    }
    private static func localPort(_ fd: Int32) throws -> UInt16 {
        var peer = sockaddr_in(), size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        guard result == 0 else { throw Failure("无法读取测试源端口") }
        return UInt16(bigEndian: peer.sin_port)
    }
    private static func connect(address: String, port: UInt16) throws -> Int32 {
        var peer = try endpoint(address, port)
        let deadline = Date().addingTimeInterval(2)
        // Wait only for the asynchronous listener's readiness, not for packet delivery.
        while Date() < deadline {
            let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            guard fd >= 0 else { throw Failure("无法创建测试 TCP socket") }
            let result = withUnsafePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            if result == 0 {
                var timeout = timeval(tv_sec: 2, tv_usec: 0), noSignal: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                return fd
            }
            let code = errno; close(fd)
            guard code == ECONNREFUSED else { throw Failure("测试 TCP 连接失败：\(code)") }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw Failure("测试 TCP 监听未就绪")
    }
    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                guard count > 0 else { throw Failure("测试 TCP 写入失败") }
                sent += count
            }
        }
    }
    private static func readLine(_ fd: Int32) throws -> Data {
        var data = Data(), byte: UInt8 = 0
        while data.count < 2048 {
            guard recv(fd, &byte, 1, 0) == 1 else { throw Failure("测试 TCP 握手读取失败") }
            if byte == 10 { return data }
            data.append(byte)
        }
        throw Failure("测试握手响应过长")
    }
    private static func sendAudio(_ fd: Int32, address: String, port: UInt16, session: Data, key: Data, recording: UInt32, pcm: UInt8) throws {
        var packet = Data("APV1".utf8); packet.append(session)
        packet.append(contentsOf: [UInt8(recording >> 24), UInt8(recording >> 16), UInt8(recording >> 8), UInt8(recording)])
        packet.append(contentsOf: [0, 0, 0, 1, 0, 1, pcm, 0])
        packet.append(contentsOf: HMAC<SHA256>.authenticationCode(for: packet, using: SymmetricKey(data: key)))
        var peer = try endpoint(address, port)
        let count = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        guard count == packet.count else { throw Failure("测试 UDP 写入失败") }
    }
}
