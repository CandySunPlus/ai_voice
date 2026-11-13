import Foundation
import CryptoKit
import Security

public enum PassportError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

extension Data {
    public init?(hex: String) {
        guard hex.utf8.count % 2 == 0 else { return nil }
        var result = Data(capacity: hex.utf8.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let value = UInt8(hex[index..<end], radix: 16) else { return nil }
            result.append(value)
            index = end
        }
        self = result
    }
    public var hex: String { map { String(format: "%02x", $0) }.joined() }
}

public enum Authentication {
    public static func random(_ count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw PassportError.invalid("无法生成安全随机数") }
        return bytes
    }
    public static func mac(_ text: String, key: Data) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key))).hex
    }
    public static func valid(_ hex: String, bytes: Data, key: Data) -> Bool {
        guard let tag = Data(hex: hex), tag.count == 32 else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: bytes, using: SymmetricKey(data: key))
    }
    public static func sessionKey(key: Data, deviceNonce: String, hostNonce: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("session|\(deviceNonce)|\(hostNonce)".utf8), using: SymmetricKey(data: key)))
    }
}

public struct ControlMessage {
    public let sequence: UInt32
    public let kind: String
    public let body: [String: Any]
    public let duplicate: Bool
}

public struct SecureChannel {
    private struct Envelope: Codable {
        let seq: UInt32
        let kind: String
        let body: String
        let mac: String
    }
    public let session: String
    public let key: Data
    private var sent: UInt32 = 0
    private var received: UInt32 = 0

    public init(session: String, key: Data) {
        self.session = session
        self.key = key
    }
    public mutating func encode(kind: String, body: [String: Any]) throws -> (UInt32, Data) {
        guard sent < UInt32.max, kind.utf8.count <= 32 else { throw PassportError.invalid("会话序号耗尽或消息类型错误") }
        let payload = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]).base64EncodedString()
        let next = sent + 1
        let text = "\(session)|\(next)|\(kind)|\(payload)"
        let envelope = Envelope(seq: next, kind: kind, body: payload, mac: Authentication.mac(text, key: key))
        var line = try JSONEncoder().encode(envelope)
        guard line.count < 8192 else { throw PassportError.invalid("控制消息超过上限") }
        line.append(10)
        sent = next
        return (next, line)
    }
    public mutating func decode(_ data: Data) throws -> ControlMessage {
        guard data.count <= 8192 else { throw PassportError.invalid("控制消息超过上限") }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        let text = "\(session)|\(envelope.seq)|\(envelope.kind)|\(envelope.body)"
        guard envelope.seq > 0, envelope.kind.utf8.count <= 32,
              Authentication.valid(envelope.mac, bytes: Data(text.utf8), key: key),
              let payload = Data(base64Encoded: envelope.body),
              let body = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw PassportError.invalid("控制消息鉴权失败")
        }
        guard envelope.seq <= received || (received < UInt32.max && envelope.seq == received + 1) else {
            throw PassportError.invalid("控制消息序号不连续")
        }
        let duplicate = envelope.seq <= received
        if !duplicate { received = envelope.seq }
        return ControlMessage(sequence: envelope.seq, kind: envelope.kind, body: body, duplicate: duplicate)
    }
}

public struct AudioPacket {
    public let recording: UInt32
    public let sequence: UInt32
    public let pcm: Data
    public init(data: Data, session: String, key: Data) throws {
        guard data.count >= 64, data.count <= 1024, data.prefix(4) == Data("APV1".utf8),
              let nonce = Data(hex: session), nonce.count == 16, data.subdata(in: 4..<20) == nonce else {
            throw PassportError.invalid("音频头错误")
        }
        func u32(_ offset: Int) -> UInt32 {
            data[offset..<offset+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        let samples = Int(data[28]) << 8 | Int(data[29])
        guard samples > 0, samples <= 320, data.count == 30 + samples * 2 + 32,
              HMAC<SHA256>.isValidAuthenticationCode(data.suffix(32), authenticating: data.prefix(data.count - 32), using: SymmetricKey(data: key)) else {
            throw PassportError.invalid("音频长度或签名错误")
        }
        recording = u32(20)
        sequence = u32(24)
        guard recording > 0, sequence > 0 else { throw PassportError.invalid("音频序号错误") }
        pcm = data.subdata(in: 30..<data.count - 32)
    }
}

/// A missing packet is concealed only while later audio or a declared tail proves it exists.
public struct AudioJitterBuffer {
    private static let silence = Data(repeating: 0, count: 640)
    private var packets: [UInt32: Data] = [:]
    private var missingSince: TimeInterval?
    public private(set) var next: UInt32 = 1
    public private(set) var concealed: UInt32 = 0
    public private(set) var highest: UInt32 = 0
    public init() {}
    public mutating func insert(sequence: UInt32, pcm: Data) throws {
        guard sequence >= next else { return }
        guard sequence - next < 10, packets.count < 10 || packets[sequence] != nil else {
            throw PassportError.invalid("音频抖动缓冲溢出")
        }
        guard packets[sequence] == nil else { return }
        packets[sequence] = pcm
        highest = max(highest, sequence)
    }
    public mutating func pop(now: TimeInterval, tail: UInt32? = nil) -> Data? {
        guard next < UInt32.max else { return nil }
        if let pcm = packets.removeValue(forKey: next) {
            next += 1
            missingSince = nil
            return pcm
        }
        guard next <= max(highest, tail ?? 0) else { return nil }
        guard let since = missingSince else { missingSince = now; return nil }
        guard now - since >= 0.06 else { return nil }
        next += 1
        concealed += 1
        missingSince = nil
        return Self.silence
    }
    public var isEmpty: Bool { packets.isEmpty }
    public mutating func clear() { self = AudioJitterBuffer() }
}
