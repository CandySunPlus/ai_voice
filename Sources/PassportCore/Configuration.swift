import Foundation
import Security
import Darwin

public struct ClientSettings: Codable {
    public var hostID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    public var hostName = Host.current().localizedName ?? "我的 Mac"
    public var bindAddress = ""
    public var outputUID = ""
    public var shortcut = VoiceShortcut(keyCode: 101, modifiers: 0, mode: "hold")
    public var shortcutConfirmed = false
    public var preparationMilliseconds = 600
    public var devices: [String] = []
    public init() {}
    public static func load() -> ClientSettings {
        guard let data = UserDefaults.standard.data(forKey: "passport.settings.v1"),
              let settings = try? JSONDecoder().decode(ClientSettings.self, from: data) else { return ClientSettings() }
        return settings
    }
    public func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "passport.settings.v1") }
    }
}

public enum PairingKeys {
    private static let service = "cn.candysun.ai-passport.pairing.v1"
    public static func load(device: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: device,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    public static func save(device: String, key: Data) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: device]
        let update = [kSecValueData as String: key]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var entry = query
            entry[kSecValueData as String] = key
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else { throw PassportError.invalid("无法保存配对密钥到钥匙串") }
        } else if status != errSecSuccess { throw PassportError.invalid("无法更新配对密钥") }
    }
    public static func delete(device: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service, kSecAttrAccount as String: device] as CFDictionary)
    }
}

public enum USBProvisioner {
    public static func ports() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { $0.hasPrefix("cu.usbmodem") || $0.hasPrefix("cu.usbserial") }
            .sorted().map { "/dev/" + $0 }
    }
    /// Run off the main thread. A physical configuration-mode confirmation is enforced on-device.
    public static func configure(port: String, ssid: String, password: String, settings: ClientSettings) throws -> String {
        guard ports().contains(port), !ssid.isEmpty, ssid.utf8.count <= 32, password.utf8.count <= 64,
              !settings.hostName.isEmpty, settings.hostName.utf8.count <= 48,
              LocalAddress.all().contains(where: { $0.address == settings.bindAddress }) else {
            throw PassportError.invalid("请检查串口、SSID、密码长度、主机名称及本机局域网地址")
        }
        let fd = open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw PassportError.invalid("无法打开设备串口；请关闭占用串口的其他程序") }
        defer { close(fd) }
        var attributes = termios()
        guard tcgetattr(fd, &attributes) == 0 else { throw PassportError.invalid("无法读取串口参数") }
        let original = attributes
        defer { var restore = original; _ = tcsetattr(fd, TCSANOW, &restore) }
        cfmakeraw(&attributes)
        cfsetspeed(&attributes, speed_t(B115200))
        attributes.c_cflag |= tcflag_t(CLOCAL | CREAD)
        guard tcsetattr(fd, TCSANOW, &attributes) == 0 else { throw PassportError.invalid("无法设置串口") }
        tcflush(fd, TCIFLUSH)
        let info = try exchange(fd: fd, object: ["op": "info"])
        guard info["ok"] as? Bool == true, info["protocol"] as? Int == 1,
              info["board"] as? String == "ai-passport-esp32c3-8mb",
              let device = info["device"] as? String, device.count == 32, Data(hex: device)?.count == 16 else {
            throw PassportError.invalid("设备未运行兼容面板固件，或不在物理配置模式")
        }
        let previous = PairingKeys.load(device: device)
        let key = try Authentication.random(32)
        try PairingKeys.save(device: device, key: key)
        do {
            let request: [String: Any] = ["op": "configure", "wifi": [["ssid": ssid, "password": password]],
                "host": ["id": settings.hostID, "name": settings.hostName, "address": settings.bindAddress, "port": 43821, "key": key.hex]]
            let reply = try exchange(fd: fd, object: request)
            guard reply["ok"] as? Bool == true else { throw PassportError.invalid("设备拒绝配置，请检查保存的网络／主机数量（各最多 4 个）") }
        } catch {
            // Retain the old trust relationship if a configuration transaction failed.
            if let previous = previous { try? PairingKeys.save(device: device, key: previous) }
            else { PairingKeys.delete(device: device) }
            throw error
        }
        return device
    }
    private static func exchange(fd: Int32, object: [String: Any]) throws -> [String: Any] {
        var bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        bytes.append(10)
        guard bytes.count <= 8192 else { throw PassportError.invalid("USB 配置过长") }
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        var offset = 0
        while offset < bytes.count {
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard ProcessInfo.processInfo.systemUptime < deadline, poll(&descriptor, 1, 100) >= 0 else { throw PassportError.invalid("USB 写入超时") }
            let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if written > 0 { offset += written }
            else if errno != EAGAIN && errno != EINTR { throw PassportError.invalid("USB 写入失败") }
        }
        var response = Data()
        defer { response.resetBytes(in: 0..<response.count) }
        var buffer = [UInt8](repeating: 0, count: 1024)
        while ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 100) < 0 { throw PassportError.invalid("USB 读取失败") }
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                response.append(contentsOf: buffer.prefix(count))
                while let newline = response.firstIndex(of: 10) {
                    let line = response.subdata(in: 0..<newline)
                    response.removeSubrange(0...newline)
                    if let reply = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], reply["ok"] != nil { return reply }
                }
                if response.count > 8192 { throw PassportError.invalid("USB 响应超过上限") }
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) { throw PassportError.invalid("USB 设备断开") }
        }
        throw PassportError.invalid("USB 响应超时：请先在设备长按 OK 进入配置模式；原厂固件不能直接接受此协议")
    }
}
