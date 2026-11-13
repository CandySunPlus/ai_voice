import Foundation
import PassportCore

private enum CheckFailure: Error { case failed(String) }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw CheckFailure.failed(message) }
}
private func rejects<T>(_ operation: () throws -> T) throws {
    do { _ = try operation() } catch { return }
    throw CheckFailure.failed("非法消息未被拒绝")
}

/// No XCTest/Testing dependency: runs with the macOS Command Line Tools alone.
@main struct ProtocolChecks {
    private let key = Data(0..<32)
    private let session = "00112233445566778899aabbccddeeff"
    // Independent Python hashlib/hmac/struct golden vectors.
    private let control = Data(#"{"seq":1,"kind":"start","body":"eyJyZWNvcmRpbmciOjF9","mac":"94e3cdba6364c760f0af9a0f1f194cff5da62ed84064ae6dc6ec40107ccd432f"}"#.utf8)
    private let audioHex = "4150563100112233445566778899aabbccddeeff000000010000000100027b00bffef58a8af0daef5d2860794f828cc7bd11b1f494fff9aa9358184b6d538eb4c115"

    static func main() async throws {
        if CommandLine.arguments.contains("--transport-rounds") {
            try await TransportRoundChecks.run()
            return
        }
        let checks = ProtocolChecks()
        try checks.controlReplay()
        try checks.controlTampering()
        try checks.controlGap()
        try checks.audioAuthentication()
        try checks.jitterAndTail()
        try checks.localAddresses()
        print("通过 6 组协议安全检查：跨语言向量、去重、防篡改／重放、音频鉴权、乱序／收尾及地址限制")
    }
    private func controlReplay() throws {
        var channel = SecureChannel(session: session, key: key)
        let first = try channel.decode(control)
        try require(!first.duplicate && first.kind == "start", "有效 start 未执行")
        try require(first.body["recording"] as? Int == 1, "录音编号错误")
        try require(try channel.decode(control).duplicate, "重复事件会再次执行")
    }
    private func controlTampering() throws {
        var receiver = SecureChannel(session: session, key: key)
        let tampered = Data(String(decoding: control, as: UTF8.self).replacingOccurrences(of: "start", with: "stop").utf8)
        try rejects { try receiver.decode(tampered) }
        var previous = SecureChannel(session: String(repeating: "a", count: 32), key: key)
        let (_, message) = try previous.encode(kind: "start", body: ["recording": 1])
        try rejects { try receiver.decode(message) }
        try require(try !receiver.decode(control).duplicate, "伪造事件消耗了合法序号")
    }
    private func controlGap() throws {
        var sender = SecureChannel(session: session, key: key)
        _ = try sender.encode(kind: "start", body: ["recording": 1])
        let (_, stop) = try sender.encode(kind: "stop", body: ["recording": 1, "last": 0])
        var receiver = SecureChannel(session: session, key: key)
        try rejects { try receiver.decode(stop) }
    }
    private func audioAuthentication() throws {
        guard let bytes = Data(hex: audioHex) else { throw CheckFailure.failed("音频测试向量错误") }
        let packet = try AudioPacket(data: bytes, session: session, key: key)
        try require(packet.recording == 1 && packet.sequence == 1, "音频头解析错误")
        try require(packet.pcm == Data([123, 0, 191, 254]), "PCM 大小端错误")
        var forged = bytes
        forged[30] ^= 1
        try rejects { try AudioPacket(data: forged, session: session, key: key) }
        try rejects { try AudioPacket(data: bytes.dropLast(), session: session, key: key) }
        try rejects { try AudioPacket(data: bytes, session: String(repeating: "f", count: 32), key: key) }
    }
    private func jitterAndTail() throws {
        var buffer = AudioJitterBuffer()
        let first = Data(repeating: 1, count: 640), second = Data(repeating: 2, count: 640)
        try buffer.insert(sequence: 2, pcm: second)
        try require(buffer.pop(now: 0) == nil, "乱序提前播放")
        try buffer.insert(sequence: 1, pcm: first)
        try require(buffer.pop(now: 0.02) == first && buffer.pop(now: 0.04) == second, "乱序未正确恢复")
        try buffer.insert(sequence: 1, pcm: first)
        try require(buffer.pop(now: 1) == nil, "旧音频重放")
        try require(buffer.pop(now: 1, tail: 3) == nil, "尾包未等待")
        try require(buffer.pop(now: 1.061, tail: 3) == Data(repeating: 0, count: 640), "缺失尾包未补静音")
        try require(buffer.pop(now: 5, tail: 3) == nil && buffer.concealed == 1, "尾部无限补静音")
        buffer.clear()
        try require(buffer.pop(now: 6) == nil, "清空后残留旧音频")
        try rejects { try buffer.insert(sequence: 11, pcm: first) }
    }
    private func localAddresses() throws {
        try require(LocalAddress.isPrivate("192.168.1.10") && LocalAddress.isPrivate("172.16.2.3"), "合法局域网被拒绝")
        for address in ["8.8.8.8", "172.32.0.1", "::1", "10.x.1.2.3"] {
            try require(!LocalAddress.isPrivate(address), "接受了公网或非法地址")
        }
    }
}
