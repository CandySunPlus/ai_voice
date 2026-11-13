import AppKit
import Combine
import PassportCore

if CommandLine.arguments.contains("--release-guard") {
    VoiceKeys.runReleaseGuard()
    exit(0)
}

final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}

final class ControlPanel: NSView {
    private let model: PassportController
    private var observation: AnyCancellable?
    private let message = NSTextField(wrappingLabelWithString: "")
    private let host = NSTextField(string: "")
    private let addresses = NSPopUpButton()
    private let outputs = NSPopUpButton()
    private let ports = NSPopUpButton()
    private let targets = NSPopUpButton()
    private let keyCode = NSTextField(string: "")
    private let preparation = NSTextField(string: "")
    private let mode = NSPopUpButton()
    private let verified = NSButton(checkboxWithTitle: "已用实体键盘验证快捷键、模式及豆包音源", target: nil, action: nil)
    private let modifiers = ["⌘", "⌥", "⌃", "⇧", "Fn"].map { NSButton(checkboxWithTitle: $0, target: nil, action: nil) }
    private let ssid = NSTextField(string: "")
    private let password = NSSecureTextField(string: "")
    private var localAddresses: [LocalAddress] = []
    private var audioOutputs: [AudioOutput] = []
    private var serialPorts: [String] = []
    private let connect = NSButton()
    private let provision = NSButton()
    private var targetIDs: [String] = []

    init(model: PassportController) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 720, height: 840))
        let scroll = NSScrollView(frame: bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 700, height: 1140))
        document.autoresizingMask = [.width]
        scroll.documentView = document
        addSubview(scroll)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -20)
        ])
        func add(_ view: NSView) {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        func label(_ text: String, small: Bool = false) -> NSTextField {
            let view = NSTextField(wrappingLabelWithString: text)
            view.font = .systemFont(ofSize: small ? 11 : 13)
            if small { view.textColor = .secondaryLabelColor }
            return view
        }
        func section(_ text: String) {
            let title = label(text)
            title.font = .boldSystemFont(ofSize: 14)
            add(title)
        }
        let title = label("AI Passport 语音控制面板")
        title.font = .boldSystemFont(ofSize: 22)
        add(row([title, button("立即停止语音", #selector(stopVoice))]))
        message.font = .boldSystemFont(ofSize: 13)
        add(message)
        add(label("Codex 任务状态：未知　｜　任务数量：不可用", small: true))
        section("运行主机与音频")
        host.stringValue = model.settings.hostName
        host.placeholderString = "设备上显示的主机名称（最多 48 UTF-8 字节）"
        add(host)
        add(row([addresses, button("刷新设备", #selector(refreshDevices))]))
        add(outputs)
        add(label("豆包输入源需选择 BlackHole 2ch；系统默认输出保持不变。音频在可信局域网明文传输，每包鉴权。", small: true))
        connect.title = "启动连接"; connect.target = self; connect.action = #selector(toggleConnection)
        add(row([connect, button("申请辅助功能权限", #selector(requestAccess))]))
        section("豆包真实语音快捷键")
        keyCode.stringValue = String(model.settings.shortcut.keyCode)
        keyCode.placeholderString = "macOS keyCode"
        mode.addItems(withTitles: ["按住／松开", "点击开始／点击结束"])
        mode.selectItem(at: model.settings.shortcut.mode == "tap" ? 1 : 0)
        add(row([label("键码"), keyCode, mode]))
        let flags: [CGEventFlags] = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
        for (index, flag) in flags.enumerated() {
            modifiers[index].state = CGEventFlags(rawValue: model.settings.shortcut.modifiers).contains(flag) ? .on : .off
        }
        add(row(modifiers))
        add(label("编码示例：F9=101，右 Shift=60，Fn=63；不是豆包默认配置。Fn／地球键必须实测。", small: true))
        preparation.stringValue = String(model.settings.preparationMilliseconds)
        add(row([label("准备等待（200–3000 毫秒）"), preparation]))
        verified.state = model.settings.shortcutConfirmed ? .on : .off
        add(verified)
        add(button("保存快捷键", #selector(saveShortcut)))
        section("输入目标：当前桌面的普通窗口")
        targets.addItem(withTitle: "请先授权辅助功能并刷新窗口")
        add(targets)
        add(row([button("刷新窗口", #selector(refreshTargets)), button("激活所选窗口", #selector(activateTarget))]))
        add(label("窗口不等于输入框。必要时在 Mac 点选输入位置，再按住设备上键。跨 Space／全屏无法可靠验证时手动切换；识别结束后先核对文字，不自动发送或按 Enter。", small: true))
        section("USB 首次配置／新增地点")
        add(label("先安装已核验兼容的面板固件，再在设备长按 OK 进入配置模式。此客户端不会刷写固件。", small: true))
        add(ports)
        ssid.placeholderString = "2.4 GHz Wi-Fi SSID"
        password.placeholderString = "Wi-Fi 密码（开放网络可留空）"
        add(ssid); add(password)
        provision.title = "经 USB 保存网络并配对此 Mac"; provision.target = self; provision.action = #selector(configureUSB)
        add(provision)
        add(label("网络按 SSID、主机按身份合并保存，各最多 4 个；IP 变化时经 USB 更新。密钥只存钥匙串／设备 NVS。最长录音 120 秒，不保存音频或转写。", small: true))
        refreshDevices()
        refreshState()
        observation = model.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshState() }
    }
    required init?(coder: NSCoder) { nil }
    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views); row.orientation = .horizontal; row.spacing = 10; row.alignment = .centerY
        return row
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    @objc private func refreshDevices() {
        localAddresses = LocalAddress.all(); audioOutputs = AudioBridge.outputs(); serialPorts = USBProvisioner.ports()
        addresses.removeAllItems(); addresses.addItem(withTitle: "选择具体局域网接口")
        addresses.addItems(withTitles: localAddresses.map { "\($0.interface) · \($0.address)" })
        if let index = localAddresses.firstIndex(where: { $0.address == model.settings.bindAddress }) { addresses.selectItem(at: index + 1) }
        outputs.removeAllItems(); outputs.addItem(withTitle: "选择 BlackHole 2ch")
        outputs.addItems(withTitles: audioOutputs.map(\.name))
        if let index = audioOutputs.firstIndex(where: { $0.uid == model.settings.outputUID }) { outputs.selectItem(at: index + 1) }
        ports.removeAllItems(); ports.addItem(withTitle: "选择 USB 串口"); ports.addItems(withTitles: serialPorts)
    }
    private func saveConnection() {
        model.settings.hostName = host.stringValue
        let address = addresses.indexOfSelectedItem - 1
        let output = outputs.indexOfSelectedItem - 1
        model.settings.bindAddress = localAddresses.indices.contains(address) ? localAddresses[address].address : ""
        model.settings.outputUID = audioOutputs.indices.contains(output) ? audioOutputs[output].uid : ""
        model.saveSettings()
    }
    private func refreshState() {
        message.stringValue = model.message
        connect.title = model.listening ? "停止连接" : "启动连接"
        connect.isEnabled = !model.provisioning
        provision.isEnabled = !model.provisioning
        let ids = model.targets.map(\.id)
        if ids != targetIDs {
            targets.removeAllItems(); targets.addItem(withTitle: "请选择输入目标")
            targets.addItems(withTitles: model.targets.map { "\($0.app) / \($0.title)" })
            targetIDs = ids
        }
    }
    @objc private func stopVoice() { model.emergencyStop() }
    @objc private func toggleConnection() { if model.listening { model.stopListening() } else { saveConnection(); model.startListening() } }
    @objc private func requestAccess() { model.requestAccessibility() }
    @objc private func refreshTargets() { model.refreshTargets() }
    @objc private func activateTarget() {
        let index = targets.indexOfSelectedItem - 1
        if targetIDs.indices.contains(index) { model.selectTarget(targetIDs[index]) }
    }
    @objc private func saveShortcut() {
        guard !["preparing", "recording", "draining"].contains(model.phase) else { model.emergencyStop(); return }
        guard let code = UInt16(keyCode.stringValue), code < 128, ![36, 76, 57].contains(code),
              let delay = Int(preparation.stringValue), (200...3000).contains(delay) else {
            message.stringValue = "键码为 0–127，禁止 Enter／Caps Lock；准备等待为 200–3000 毫秒"
            return
        }
        let masks: [CGEventFlags] = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
        var flags: CGEventFlags = []
        for (index, mask) in masks.enumerated() where modifiers[index].state == .on { flags.insert(mask) }
        model.settings.shortcut = VoiceShortcut(keyCode: code, modifiers: flags.rawValue, mode: mode.indexOfSelectedItem == 1 ? "tap" : "hold")
        model.settings.shortcutConfirmed = verified.state == .on
        model.settings.preparationMilliseconds = delay
        model.saveSettings()
        message.stringValue = "快捷键配置已保存；未勾选实体验证时不会开始语音"
    }
    @objc private func configureUSB() {
        saveConnection()
        let index = ports.indexOfSelectedItem - 1
        guard serialPorts.indices.contains(index) else { message.stringValue = "请选择设备 USB 串口"; return }
        model.provision(port: serialPorts[index], ssid: ssid.stringValue, password: password.stringValue)
        password.stringValue = ""
    }
}

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private let controller = PassportController()
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var signalSources: [DispatchSourceSignal] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }; source.resume(); signalSources.append(source)
        }
        NSApp.setActivationPolicy(.accessory)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "AI Passport 语音控制面板"; window.isReleasedWhenClosed = false
        window.contentView = ControlPanel(model: controller); window.minSize = NSSize(width: 660, height: 600); window.center()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength); statusItem.button?.title = "AI◉"
        let menu = NSMenu()
        menu.addItem(withTitle: "打开控制面板", action: #selector(openPanel), keyEquivalent: "")
        menu.addItem(withTitle: "立即停止语音", action: #selector(stopVoice), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 AI Passport", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }; statusItem.menu = menu
        openPanel()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(stopVoice), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(stopVoice), name: NSWorkspace.willSleepNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(stopVoice), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
    }
    func applicationWillTerminate(_ notification: Notification) { controller.shutdown() }
    @objc private func openPanel() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func stopVoice() { controller.emergencyStop() }
    @objc private func quit() { NSApp.terminate(nil) }
}

if CommandLine.arguments.contains("--diagnose") {
    print("AI Passport 本机检查（不录音、不注入按键）")
    #if arch(arm64)
    print("架构：arm64")
    #else
    print("架构：不支持，需要 Apple Silicon arm64")
    #endif
    print("辅助功能：\(TargetAccess().isTrusted ? "已授权" : "未授权")")
    for address in LocalAddress.all() { print("局域网：\(address.interface) \(address.address)") }
    let outputs = AudioBridge.outputs()
    if outputs.isEmpty { print("BlackHole 2ch：未检测到；不能验证豆包音频闭环") }
    for output in outputs { print("音频出口：\(output.name) UID=\(output.uid)") }
    print("USB 串口数量：\(USBProvisioner.ports().count)")
    print("Codex 实时任务：未知；数量不可用")
    exit(0)
}
let application = NSApplication.shared
let delegate = ApplicationDelegate()
application.delegate = delegate
application.run()
