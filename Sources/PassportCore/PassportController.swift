import Foundation
import Combine
import CoreFoundation

public final class PassportController: ObservableObject {
    @Published public var settings = ClientSettings.load()
    @Published public private(set) var targets: [InputTarget] = []
    @Published public private(set) var phase = "idle"
    @Published public private(set) var message = "请选择局域网地址并启动连接"
    @Published public private(set) var connected = false
    @Published public private(set) var listening = false
    @Published public private(set) var selectedID = ""
    @Published public private(set) var provisioning = false
    @Published public private(set) var concealedPackets: UInt32 = 0
    private let targetAccess = TargetAccess()
    private let keys = VoiceKeys()
    private let audio = AudioBridge()
    private var transport: LocalTransport!
    private var pairedKeys: [String: Data] = [:]
    private var timer: Timer?
    private var jitter = AudioJitterBuffer()
    private var recording: UInt32 = 0
    private var previousRecording: UInt32 = 0
    private var started: TimeInterval = 0
    private var readyAt: TimeInterval = 0
    private var stoppedAt: TimeInterval = 0
    private var drainedAt: TimeInterval?
    private var tail: UInt32?
    private var nextAudioAt: TimeInterval = 0

    public init() {
        transport = LocalTransport(hostID: settings.hostID, lookupKey: { [weak self] in self?.pairedKeys[$0] })
        transport.onConnected = { [weak self] value in self?.connectionChanged(value) }
        transport.onControl = { [weak self] message in self?.handle(message) }
        transport.onAudio = { [weak self] packet in self?.receive(packet) }
        transport.onError = { [weak self] reason in self?.abort(reason) }
        let heartbeat = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(heartbeat, forMode: .common)
        timer = heartbeat
        refreshTargets()
    }
    public var hasAccessibility: Bool { targetAccess.isTrusted }
    public func requestAccessibility() { targetAccess.requestAccess() }
    public func saveSettings() {
        guard !["preparing", "recording", "draining"].contains(phase) else { abort("录音中不能修改配置"); return }
        settings.preparationMilliseconds = min(3000, max(200, settings.preparationMilliseconds))
        settings.save()
    }
    public func startListening() {
        emergencyStop()
        do {
            // Never let unauthenticated network input initiate a blocking Keychain query.
            pairedKeys = Dictionary(uniqueKeysWithValues: Set(settings.devices).compactMap { device in
                PairingKeys.load(device: device).map { (device, $0) }
            })
            try transport.start(address: settings.bindAddress)
            settings.save()
            listening = true
            phase = "idle"
            message = "等待已配对设备；TCP/UDP 43821，仅指定局域网地址"
        } catch { abort(error.localizedDescription) }
    }
    public func stopListening() {
        emergencyStop()
        transport.stop()
        listening = false
        message = "连接已停止"
    }
    public func refreshTargets() {
        guard !["preparing", "recording", "draining"].contains(phase) else { return }
        targets = Array(targetAccess.listTargets().prefix(12))
        if connected { sendTargets() }
    }
    public func selectTarget(_ id: String) {
        guard connected, !["preparing", "recording", "draining"].contains(phase),
              targets.contains(where: { $0.id == id }) else { return }
        targetAccess.clear()
        selectedID = id
        do {
            try targetAccess.activate(id)
            transition("target", "请在 Mac 点选输入位置，再按住设备上键")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self, self.selectedID == id, self.phase == "target", self.connected else { return }
                do { try self.targetAccess.lockFocus(id); self.transition("target", "输入位置已确认；按住上键说话") }
                catch { self.transition("target", "请在 Mac 点选输入位置，再按住上键") }
            }
        } catch { abort(error.localizedDescription) }
    }
    public func emergencyStop() {
        keys.end()
        audio.stop()
        jitter.clear()
        recording = 0
        tail = nil
        drainedAt = nil
        targetAccess.clear()
        selectedID = ""
        transition("idle", "已停止；请重新选择输入目标")
    }
    public func shutdown() {
        emergencyStop()
        transport.stop()
        timer?.invalidate()
        timer = nil
    }
    public func provision(port: String, ssid: String, password: String) {
        guard !provisioning else { return }
        stopListening()
        provisioning = true
        message = "请在设备长按 OK 进入 USB 配置；正在核对设备协议"
        let snapshot = settings
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try USBProvisioner.configure(port: port, ssid: ssid, password: password, settings: snapshot) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.provisioning = false
                switch result {
                case .success(let device):
                    if !self.settings.devices.contains(device) { self.settings.devices.append(device) }
                    self.settings.save()
                    self.message = "配置完成；请在设备选择运行主机，然后启动连接"
                case .failure(let error): self.message = error.localizedDescription
                }
            }
        }
    }
    private func connectionChanged(_ value: Bool) {
        emergencyStop()
        connected = value
        previousRecording = 0
        if value { refreshTargets(); transition("idle", "已配对连接；请在设备选择输入目标") }
        else { transition("error", "设备断开；重连后必须重新选择输入目标") }
    }
    private func sendTargets() {
        func short(_ text: String) -> String {
            var result = ""
            for character in text {
                if result.utf8.count + String(character).utf8.count > 48 { break }
                result.append(character)
            }
            return result
        }
        transport.send("targets", ["items": targets.map { ["id": $0.id, "app": short($0.app), "title": short($0.title)] }])
    }
    private static func number(_ body: [String: Any], _ key: String, allowZero: Bool = false) -> UInt32? {
        guard let value = body[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.rounded(.towardZero) == value.doubleValue,
              value.doubleValue >= (allowZero ? 0 : 1), value.doubleValue <= Double(UInt32.max) else { return nil }
        return value.uint32Value
    }
    private func handle(_ event: ControlMessage) {
        switch event.kind {
        case "list": emergencyStop(); refreshTargets()
        case "select":
            guard let id = event.body["id"] as? String else { abort("缺少输入目标"); return }
            selectTarget(id)
        case "start":
            guard let id = Self.number(event.body, "recording") else { abort("录音编号无效"); return }
            begin(id)
        case "stop":
            guard let id = Self.number(event.body, "recording"), let last = Self.number(event.body, "last", allowZero: true) else { abort("录音结束标记无效"); return }
            end(id, last: last)
        case "cancel": emergencyStop()
        default: abort("设备发送不支持的控制事件")
        }
    }
    private func begin(_ id: UInt32) {
        guard ["target", "waiting"].contains(phase), id > previousRecording, !selectedID.isEmpty,
              settings.shortcutConfirmed else { abort("请确认输入目标及豆包真实快捷键配置"); return }
        do {
            try targetAccess.lockFocus(selectedID)
            guard targetAccess.validateFocus() else { throw PassportError.invalid("无法确认输入焦点，拒绝录音") }
            try audio.start(deviceUID: settings.outputUID)
            try keys.begin(settings.shortcut)
            jitter.clear()
            recording = id
            previousRecording = id
            started = ProcessInfo.processInfo.systemUptime
            readyAt = started + Double(settings.preparationMilliseconds) / 1000
            tail = nil
            drainedAt = nil
            transition("preparing", "准备中；看到设备录音提示后再说话")
        } catch { abort(error.localizedDescription) }
    }
    private func end(_ id: UInt32, last: UInt32) {
        guard id == recording, ["preparing", "recording"].contains(phase) else { abort("录音结束顺序错误"); return }
        guard last <= 6000, last >= jitter.next - 1, last <= jitter.highest + 10 else { abort("音频尾部序号错误"); return }
        tail = last
        stoppedAt = ProcessInfo.processInfo.systemUptime
        nextAudioAt = min(nextAudioAt, stoppedAt)
        transition("draining", "正在收尾，请保持输入焦点")
    }
    private func receive(_ packet: AudioPacket) {
        guard packet.recording == recording, ["recording", "draining"].contains(phase) else { return }
        if let tail = tail, packet.sequence > tail { return }
        do { try jitter.insert(sequence: packet.sequence, pcm: packet.pcm) }
        catch { abort(error.localizedDescription) }
    }
    private func tick() {
        guard ["preparing", "recording", "draining"].contains(phase) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard targetAccess.validateFocus() else { abort("焦点改变、锁屏或安全输入；已中止语音"); return }
        guard now - started < 120 else { abort("录音达到 120 秒上限"); return }
        if phase == "preparing", now >= readyAt {
            transition("recording", "录音中；松开上键结束")
            nextAudioAt = now + 0.06
            transport.send("speak", ["recording": recording])
        }
        if ["recording", "draining"].contains(phase), now >= nextAudioAt {
            // Catch up timer jitter without turning a delayed packet into unbounded latency.
            let declaredTail = phase == "draining" && now - stoppedAt >= 0.3 ? tail : nil
            for _ in 0..<3 where now >= nextAudioAt && audio.queuedFrames < 1600 {
                guard let pcm = jitter.pop(now: now, tail: declaredTail) else { break }
                guard audio.enqueue(pcm) else { abort("音频输出缓冲溢出"); return }
                nextAudioAt = max(nextAudioAt + Double(pcm.count / 2) / 16000, now - 0.04)
            }
            concealedPackets = jitter.concealed
        }
        if phase == "draining", let tail = tail, jitter.next > tail, audio.queuedFrames == 0 {
            if drainedAt == nil { drainedAt = now }
            if let drainedAt = drainedAt, now - drainedAt >= 0.15 {
                keys.end()
                audio.stop()
                jitter.clear()
                recording = 0
                self.tail = nil
                transition("waiting", "等待豆包出字；请核对后再操作，不会自动发送")
            }
        } else { drainedAt = nil }
        if phase == "draining", now - stoppedAt > 2 { abort("音频收尾超时；已停止并清空缓冲") }
    }
    private func abort(_ reason: String) {
        emergencyStop()
        transition("error", reason)
    }
    private func transition(_ value: String, _ text: String) {
        phase = value
        message = text
        transport?.send("state", ["phase": value, "message": text, "target": selectedID, "task": "unknown"])
    }
}
