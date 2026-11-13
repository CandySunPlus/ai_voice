import AppKit
import ApplicationServices
import AudioToolbox
import Carbon
import CoreAudio
import Darwin

public struct InputTarget: Codable, Identifiable {
    public let id: String
    public let app: String
    public let title: String
}

private enum MacSystemError: LocalizedError {
    case refused(String)
    case audio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .refused(let message): return message
        case .audio(let operation, let status): return "\(operation)失败（\(status)）"
        }
    }
}

private func inputSessionIsSafe() -> Bool {
    guard !IsSecureEventInputEnabled(),
          let session = CGSessionCopyCurrentDictionary() as? [String: Any],
          session[kCGSessionOnConsoleKey as String] as? Bool == true,
          session[kCGSessionLoginDoneKey as String] as? Bool == true,
          session["CGSSessionScreenIsLocked"] as? Bool != true,
          let front = NSWorkspace.shared.frontmostApplication,
          !["com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.ScreenSaver.Engine"]
            .contains(front.bundleIdentifier ?? "") else { return false }
    return true
}

private func axValue(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result
}

private func axElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = axValue(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
}

private func axBool(_ element: AXUIElement, _ name: String) -> Bool? {
    axValue(element, name) as? Bool
}

private func sameAX(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool { CFEqual(lhs, rhs) }

private func axBounds(_ element: AXUIElement) -> CGRect? {
    guard let position = axValue(element, kAXPositionAttribute),
          let size = axValue(element, kAXSizeAttribute),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    let p = unsafeBitCast(position, to: AXValue.self)
    let s = unsafeBitCast(size, to: AXValue.self)
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(p, .cgPoint, &point), AXValueGetValue(s, .cgSize, &dimensions) else { return nil }
    return CGRect(origin: point, size: dimensions)
}

private func sameBounds(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.minX - rhs.minX) < 1 && abs(lhs.minY - rhs.minY) < 1 &&
        abs(lhs.width - rhs.width) < 1 && abs(lhs.height - rhs.height) < 1
}

private struct VisibleWindow {
    let number: CGWindowID
    let pid: pid_t
    let bounds: CGRect
    let title: String
}

private func visibleWindows() -> [VisibleWindow] {
    guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] else { return [] }
    return rows.compactMap { row in
        guard let layer = row[kCGWindowLayer as String] as? Int, layer == 0,
              let number = row[kCGWindowNumber as String] as? UInt32,
              let pid = row[kCGWindowOwnerPID as String] as? Int32,
              let rawBounds = row[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
              bounds.width > 1, bounds.height > 1,
              (row[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
        return VisibleWindow(number: number, pid: pid, bounds: bounds,
                             title: row[kCGWindowName as String] as? String ?? "")
    }
}

public final class TargetAccess {
    private struct Record {
        let target: InputTarget
        let pid: pid_t
        let launched: Date
        let bundle: String?
        let executable: URL
        let number: CGWindowID
        var window: AXUIElement?
    }

    private var records: [String: Record] = [:]
    private var locked: Record?
    private var focused: AXUIElement?

    public init() {}
    public var isTrusted: Bool { AXIsProcessTrusted() }

    public func requestAccess() {
        precondition(Thread.isMainThread)
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    public func listTargets() -> [InputTarget] {
        precondition(Thread.isMainThread)
        guard isTrusted, inputSessionIsSafe() else { return [] }
        let visible = visibleWindows()
        var next: [String: Record] = [:]
        var result: [InputTarget] = []
        for window in visible {
            guard result.count < 12,
                  let app = NSRunningApplication(processIdentifier: window.pid),
                  app.activationPolicy == .regular, !app.isTerminated,
                  let launched = app.launchDate, let executable = app.executableURL else { continue }
            let match = matchAX(window, in: visible)
            let previous = records.values.first {
                $0.pid == window.pid && $0.launched == launched && $0.executable == executable &&
                    $0.bundle == app.bundleIdentifier && $0.number == window.number &&
                    (($0.window == nil && match == nil) || ($0.window != nil && match != nil && sameAX($0.window!, match!)))
            }
            let id = previous?.target.id ?? UUID().uuidString
            // AX titles are available without requesting Screen Recording.
            var title = window.title
            if let match, let accessibleTitle = axValue(match, kAXTitleAttribute) as? String, !accessibleTitle.isEmpty {
                title = accessibleTitle
            }
            let target = InputTarget(id: id, app: shortLabel(app.localizedName ?? "应用"),
                                     title: shortLabel(title.isEmpty ? "窗口 \(window.number)" : title))
            next[id] = Record(target: target, pid: window.pid, launched: launched,
                              bundle: app.bundleIdentifier, executable: executable,
                              number: window.number, window: match)
            result.append(target)
        }
        records = next
        return result
    }

    public func activate(_ id: String) throws {
        precondition(Thread.isMainThread)
        clear()
        guard isTrusted, inputSessionIsSafe(), var record = records[id],
              let app = runningApp(record), let window = resolve(&record) else {
            throw MacSystemError.refused("无法唯一确认窗口；请在 Mac 手动激活输入位置")
        }
        records[id] = record
        guard app.activate(options: [.activateIgnoringOtherApps]),
              AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else {
            throw MacSystemError.refused("窗口激活失败；请在 Mac 手动选择输入位置")
        }
    }

    public func lockFocus(_ id: String) throws {
        precondition(Thread.isMainThread)
        clear()
        guard var record = records[id], let window = resolve(&record),
              let element = verifiedFocus(record, window: window) else {
            throw MacSystemError.refused("请在选定窗口点选可编辑的非密码输入框")
        }
        records[id] = record
        locked = record
        focused = element
    }

    public func validateFocus() -> Bool {
        precondition(Thread.isMainThread)
        guard var record = locked, let focus = focused, let window = resolve(&record),
              let current = verifiedFocus(record, window: window), sameAX(current, focus) else { return false }
        return true
    }

    public func clear() {
        precondition(Thread.isMainThread)
        locked = nil
        focused = nil
    }

    private func runningApp(_ record: Record) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: record.pid), !app.isTerminated,
              app.launchDate == record.launched, app.bundleIdentifier == record.bundle,
              app.executableURL == record.executable else { return nil }
        return app
    }

    private func resolve(_ record: inout Record) -> AXUIElement? {
        guard isTrusted, runningApp(record) != nil else { return nil }
        let visible = visibleWindows()
        guard let cgWindow = visible.first(where: { $0.number == record.number && $0.pid == record.pid }),
              let current = matchAX(cgWindow, in: visible) else { return nil }
        if let retained = record.window, !sameAX(retained, current) { return nil }
        record.window = current
        return current
    }

    // Public AX has no portable CGWindowID attribute. Geometry must be bijective
    // in BOTH lists; identical/overlapping duplicate bounds are deliberately refused.
    private func matchAX(_ window: VisibleWindow, in visible: [VisibleWindow]) -> AXUIElement? {
        let application = AXUIElementCreateApplication(window.pid)
        guard let windows = axValue(application, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        let candidates = windows.filter {
            axValue($0, kAXRoleAttribute) as? String == kAXWindowRole &&
                axValue($0, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole &&
                axBool($0, kAXMinimizedAttribute) == false &&
                axBool($0, "AXFullScreen") != true &&
                axBounds($0).map { sameBounds($0, window.bounds) } == true
        }
        guard candidates.count == 1,
              visible.filter({ $0.pid == window.pid && sameBounds($0.bounds, window.bounds) }).count == 1 else { return nil }
        return candidates[0]
    }

    private func verifiedFocus(_ record: Record, window: AXUIElement) -> AXUIElement? {
        guard isTrusted, inputSessionIsSafe(), let app = runningApp(record), app.isActive,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == record.pid else { return nil }
        let application = AXUIElementCreateApplication(record.pid)
        let system = AXUIElementCreateSystemWide()
        guard let front = axElement(system, kAXFocusedApplicationAttribute), sameAX(front, application),
              let activeWindow = axElement(application, kAXFocusedWindowAttribute), sameAX(window, activeWindow),
              axBool(window, kAXMainAttribute) == true,
              let focus = axElement(application, kAXFocusedUIElementAttribute),
              let systemFocus = axElement(system, kAXFocusedUIElementAttribute), sameAX(focus, systemFocus),
              axBool(focus, kAXFocusedAttribute) == true,
              axBool(focus, kAXEnabledAttribute) != false, // TextEdit omits this; editability is proven below.
              let role = axValue(focus, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else { return nil }
        var settable = DarwinBoolean(false)
        let valueCanChange = AXUIElementIsAttributeSettable(focus, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
        guard valueCanChange || axBool(focus, "AXEditable") == true else { return nil }
        var ancestor: AXUIElement? = focus
        for _ in 0..<64 {
            guard let node = ancestor,
                  axValue(node, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
                  axBool(node, "AXProtectedContent") != true else { return nil }
            let role = axValue(node, kAXRoleAttribute) as? String ?? ""
            guard ![kAXMenuRole, kAXMenuBarRole, kAXMenuItemRole, kAXMenuBarItemRole].contains(role) else { return nil }
            if sameAX(node, window) { return focus }
            ancestor = axElement(node, kAXParentAttribute)
        }
        return nil
    }
}

private func shortLabel(_ text: String) -> String {
    var result = ""
    var count = 0
    for character in text where !character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
        let size = character.utf8.count
        if count + size > 48 { break }
        result.append(character)
        count += size
    }
    return result
}

public struct VoiceShortcut: Codable {
    public var keyCode: UInt16
    public var modifiers: UInt64
    public var mode: String

    public init(keyCode: UInt16, modifiers: UInt64, mode: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.mode = mode
    }
}

public final class VoiceKeys {
    private struct Stroke {
        let down: [CGEvent]
        let up: [CGEvent]
    }
    private struct EventSpec: Codable {
        let keyCode: UInt16
        let flags: UInt64
        let type: UInt32

        init(_ event: CGEvent) {
            keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            flags = event.flags.rawValue
            type = event.type.rawValue
        }
    }

    private struct GuardPlan: Codable {
        let tap: Bool
        let down: [EventSpec]
        let up: [EventSpec]
    }

    private var releaseGuard: Process?
    private var guardInput: FileHandle?
    private static let modifierKeys: [(CGEventFlags, CGKeyCode)] = [
        (.maskControl, 59), (.maskAlternate, 58), (.maskShift, 56), (.maskCommand, 55), (.maskSecondaryFn, 63)
    ]
    private static let modifierCodes: [CGKeyCode: CGEventFlags] = [
        54: .maskCommand, 55: .maskCommand, 56: .maskShift, 60: .maskShift,
        58: .maskAlternate, 61: .maskAlternate, 59: .maskControl, 62: .maskControl, 63: .maskSecondaryFn
    ]

    public init() {}

    public func begin(_ shortcut: VoiceShortcut) throws {
        precondition(Thread.isMainThread)
        guard guardInput == nil, releaseGuard?.isRunning != true else {
            throw MacSystemError.refused("上一语音快捷键仍在结束，请稍后再试")
        }
        let allowed = Self.modifierKeys.reduce(CGEventFlags()) { $0.union($1.0) }
        let flags = CGEventFlags(rawValue: shortcut.modifiers)
        guard shortcut.mode == "hold" || shortcut.mode == "tap",
              shortcut.keyCode < 128, ![36, 76, 57].contains(shortcut.keyCode),
              flags.subtracting(allowed).isEmpty,
              AXIsProcessTrusted(), CGPreflightPostEventAccess(), inputSessionIsSafe(),
              CGEventSource.flagsState(.combinedSessionState).intersection(allowed.union(.maskAlphaShift)).isEmpty,
              !CGEventSource.keyState(.combinedSessionState, key: shortcut.keyCode),
              let source = CGEventSource(stateID: .privateState) else {
            throw MacSystemError.refused("快捷键无效、已有按键按下、权限不足或当前输入环境不安全（禁止回车键）")
        }
        var keys = Self.modifierKeys.filter { flags.contains($0.0) }
        let primaryModifier = Self.modifierCodes[shortcut.keyCode]
        if let primaryModifier {
            guard !flags.contains(primaryModifier) else { throw MacSystemError.refused("快捷键包含重复修饰键") }
            keys.append((primaryModifier, shortcut.keyCode))
        }
        for (_, key) in keys where CGEventSource.keyState(.combinedSessionState, key: key) {
            throw MacSystemError.refused("请先松开快捷键涉及的物理按键")
        }
        var down: [CGEvent] = []
        var up: [CGEvent] = []
        var current = CGEventFlags()
        func event(_ key: CGKeyCode, _ pressed: Bool, _ eventFlags: CGEventFlags, modifier: Bool) throws -> CGEvent {
            guard let value = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: pressed) else {
                throw MacSystemError.refused("无法创建快捷键事件")
            }
            if modifier { value.type = .flagsChanged }
            value.flags = eventFlags
            value.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            return value
        }
        for (flag, key) in keys {
            current.insert(flag)
            down.append(try event(key, true, current, modifier: true))
        }
        if primaryModifier == nil {
            down.append(try event(shortcut.keyCode, true, current, modifier: false))
            up.append(try event(shortcut.keyCode, false, current, modifier: false))
        }
        for (flag, key) in keys.reversed() {
            current.remove(flag)
            up.append(try event(key, false, current, modifier: true))
        }
        try launchGuard(Stroke(down: down, up: up), tap: shortcut.mode == "tap")
    }

    public func end() {
        precondition(Thread.isMainThread)
        guard let input = guardInput else { return }
        guardInput = nil
        // A single byte cannot fill this nonblocking pipe. The helper is the ONLY
        // event writer: D and EOF both end its one active stroke exactly once.
        var command: UInt8 = 68
        _ = Darwin.write(input.fileDescriptor, &command, 1)
        try? input.close()
    }

    private static func post(_ events: [CGEvent]) {
        for event in events {
            event.timestamp = DispatchTime.now().uptimeNanoseconds
            event.post(tap: .cghidEventTap)
        }
    }

    private func launchGuard(_ stroke: Stroke, tap: Bool) throws {
        let plan = GuardPlan(tap: tap, down: stroke.down.map(EventSpec.init), up: stroke.up.map(EventSpec.init))
        let data = try JSONEncoder().encode(plan)
        guard let argument = String(data: data, encoding: .utf8),
              let executable = Bundle.main.executableURL else {
            throw MacSystemError.refused("无法创建快捷键释放守护")
        }
        let pipe = Pipe()
        let input = pipe.fileHandleForWriting
        let descriptor = input.fileDescriptor
        // An exited helper must never SIGPIPE the UI process. Both flags are set
        // before spawn; no key is posted if pipe configuration or spawn fails.
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1 else {
            try? pipe.fileHandleForReading.close()
            try? input.close()
            throw MacSystemError.refused("无法配置快捷键释放守护管道")
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            try? pipe.fileHandleForReading.close()
            try? input.close()
            throw MacSystemError.refused("无法配置非阻塞快捷键释放管道")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--release-guard", argument]
        process.standardInput = pipe.fileHandleForReading
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? pipe.fileHandleForReading.close()
            try? input.close()
            throw MacSystemError.refused("快捷键释放守护启动失败：\(error.localizedDescription)")
        }
        try? pipe.fileHandleForReading.close()
        releaseGuard = process
        guardInput = input
    }

    /// Route --release-guard here before creating NSApplication or the main
    /// controller. This method runs only in the helper and terminates its process.
    /// It never requests permissions and never launches a second helper.
    public static func runReleaseGuard() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, arguments[1] == "--release-guard",
              let data = arguments[2].data(using: .utf8), data.count <= 8192,
              let plan = try? JSONDecoder().decode(GuardPlan.self, from: data),
              !plan.down.isEmpty, plan.down.count <= 6, plan.up.count == plan.down.count,
              plan.down.map(\.keyCode) == plan.up.reversed().map(\.keyCode),
              plan.up.last?.flags == 0,
              let source = CGEventSource(stateID: .privateState) else { Darwin.exit(EX_USAGE) }
        let allowed = modifierKeys.reduce(CGEventFlags()) { $0.union($1.0) }
        func events(_ specifications: [EventSpec], down: Bool) -> [CGEvent]? {
            var result: [CGEvent] = []
            for specification in specifications {
                let flags = CGEventFlags(rawValue: specification.flags)
                guard specification.keyCode < 128, ![36, 76, 57].contains(specification.keyCode),
                      flags.subtracting(allowed).isEmpty,
                      let type = CGEventType(rawValue: specification.type),
                      type == .flagsChanged || type == (down ? .keyDown : .keyUp),
                      (type == .flagsChanged) == (modifierCodes[specification.keyCode] != nil),
                      let event = CGEvent(keyboardEventSource: source, virtualKey: specification.keyCode, keyDown: down) else { return nil }
                event.type = type
                event.flags = flags
                event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
                result.append(event)
            }
            return result
        }
        guard let down = events(plan.down, down: true), let up = events(plan.up, down: false) else {
            Darwin.exit(EX_USAGE)
        }
        // The same signed executable inherits the parent's TCC identity, but
        // authorization can still be revoked. Do not prompt from this process.
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess(), inputSessionIsSafe(),
              CGEventSource.flagsState(.combinedSessionState).intersection(allowed.union(.maskAlphaShift)).isEmpty,
              plan.down.allSatisfy({ !CGEventSource.keyState(.combinedSessionState, key: $0.keyCode) }) else {
            Darwin.exit(EX_NOPERM)
        }
        // A cancellation received while this process was starting must not
        // briefly activate recognition after the parent has already stopped.
        var pending = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
        if Darwin.poll(&pending, 1, 0) != 0 { Darwin.exit(EXIT_SUCCESS) }
        post(down)
        if plan.tap { post(up) }
        // Only this process sends events. A parent SIGKILL closes stdin; a normal
        // D is read before EOF. Both paths converge on exactly one end operation.
        var command: UInt8 = 0
        while true {
            let count = Darwin.read(STDIN_FILENO, &command, 1)
            if count == -1 && errno == EINTR { continue }
            if count <= 0 || command == 68 { break }
        }
        if plan.tap {
            if AXIsProcessTrusted(), CGPreflightPostEventAccess(), inputSessionIsSafe() {
                post(down)
                post(up)
            }
        } else {
            post(up)
        }
        // No guard can recover if it too is killed, or during machine shutdown.
        Darwin.exit(EXIT_SUCCESS)
    }

    deinit { end() }
}

public struct AudioOutput: Identifiable {
    public let id: UInt32
    public let name: String
    public let uid: String
}

private func checkAudio(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw MacSystemError.audio(operation, status) }
}

private func audioString(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
    }
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

private func outputChannels(_ device: AudioDeviceID) -> UInt32 {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
          size >= MemoryLayout<AudioBufferList>.size else { return 0 }
    let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { storage.deallocate() }
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        .reduce(0) { $0 + $1.mNumberChannels }
}

// The deprecated OSAtomic ABI is available on macOS 11 and arm64. These are
// lock-free 64-bit acquire/release barriers, not locks or Dispatch operations.
@inline(__always) private func atomicLoad(_ value: UnsafeMutablePointer<Int64>) -> Int64 {
    OSAtomicAdd64Barrier(0, value)
}

@inline(__always) private func atomicStore(_ value: UnsafeMutablePointer<Int64>, _ next: Int64) {
    // Each counter has exactly one writer throughout a running audio session.
    _ = OSAtomicAdd64Barrier(next - atomicLoad(value), value)
}

private struct PlaybackSpan {
    var start: Int64 = 0
    var frames: Int64 = 0
}

private struct AudioRenderState {
    static let capacity = 32_000
    static let maximumSlice: UInt32 = 16_384
    let samples: UnsafeMutablePointer<Int16>
    let scratch: UnsafeMutablePointer<Int16>
    let spans: UnsafeMutablePointer<PlaybackSpan>
    // PCM read/write, span read/write, stream origin host ticks, render fault.
    let counters: UnsafeMutablePointer<Int64>
    let ticksPerSecond: Double
    var converter: AudioUnit?
    var inputPosition: Int64 = 0
    var outputPosition: Int64 = 0
    var outputRate: Double = 48_000
    var converterLatency: Double = 0
}

private let sourceRender: AURenderCallback = { refcon, _, _, _, frameCount, buffers in
    let state = refcon.assumingMemoryBound(to: AudioRenderState.self)
    guard frameCount <= AudioRenderState.maximumSlice, let buffers else { return kAudioUnitErr_TooManyFramesToProcess }
    let count = Int(frameCount)
    let scratch = state.pointee.scratch
    var copied = 0
    let counters = state.pointee.counters
    let read = atomicLoad(counters)
    let write = atomicLoad(counters + 1)
    let spanRead = atomicLoad(counters + 2)
    let spanWrite = atomicLoad(counters + 3)
    let available = min(count, Int(write - read))
    if available > 0 && spanWrite - spanRead < Int64(AudioRenderState.capacity) {
        let offset = Int(read % Int64(AudioRenderState.capacity))
        let first = min(available, AudioRenderState.capacity - offset)
        memcpy(scratch, state.pointee.samples + offset, first * MemoryLayout<Int16>.size)
        if first < available {
            memcpy(scratch + first, state.pointee.samples, (available - first) * MemoryLayout<Int16>.size)
        }
        let slot = Int(spanWrite % Int64(AudioRenderState.capacity))
        state.pointee.spans[slot] = PlaybackSpan(start: state.pointee.inputPosition, frames: Int64(available))
        atomicStore(counters + 3, spanWrite + 1)
        atomicStore(counters, read + Int64(available))
        copied = available
    }
    if copied < count {
        memset(scratch + copied, 0, (count - copied) * MemoryLayout<Int16>.size)
    }
    state.pointee.inputPosition += Int64(frameCount)
    buffers.pointee.mNumberBuffers = 1
    buffers.pointee.mBuffers.mNumberChannels = 1
    buffers.pointee.mBuffers.mDataByteSize = frameCount * 2
    buffers.pointee.mBuffers.mData = UnsafeMutableRawPointer(scratch)
    return noErr
}

private let deviceRender: AURenderCallback = { refcon, flags, timestamp, _, frameCount, buffers in
    let state = refcon.assumingMemoryBound(to: AudioRenderState.self)
    guard let converter = state.pointee.converter, let buffers,
          timestamp.pointee.mFlags.contains(.hostTimeValid) else {
        atomicStore(state.pointee.counters + 5, 1)
        return kAudioUnitErr_CannotDoInCurrentContext
    }
    let elapsed = Double(state.pointee.outputPosition) / state.pointee.outputRate
    let origin = Double(timestamp.pointee.mHostTime) - elapsed * state.pointee.ticksPerSecond
    atomicStore(state.pointee.counters + 4, Int64(origin))
    let status = AudioUnitRender(converter, flags, timestamp, 0, frameCount, buffers)
    state.pointee.outputPosition += Int64(frameCount)
    if status != noErr { atomicStore(state.pointee.counters + 5, 1) }
    return status
}

public final class AudioBridge {
    private var outputUnit: AudioUnit?
    private var converterUnit: AudioUnit?
    private var state: UnsafeMutablePointer<AudioRenderState>?
    private var enqueued: Int64 = 0
    private var played: Int64 = 0
    private var partialSpan: Int64 = 0

    public init() {}

    public static func outputs() -> [AudioOutput] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        guard size >= MemoryLayout<AudioDeviceID>.size else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        return devices.compactMap { device in
            guard let name = audioString(device, kAudioObjectPropertyName),
                  let uid = audioString(device, kAudioDevicePropertyDeviceUID),
                  (name == "BlackHole 2ch" || uid == "BlackHole2ch_UID"), outputChannels(device) == 2 else { return nil }
            return AudioOutput(id: device, name: name, uid: uid)
        }
    }

    public func start(deviceUID: String) throws {
        precondition(Thread.isMainThread)
        stop()
        guard let device = Self.outputs().first(where: { $0.uid == deviceUID }) else {
            throw MacSystemError.refused("请选择已安装的 BlackHole 2ch；不会回退到系统扬声器")
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        try checkAudio(AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &rate), "读取 BlackHole 采样率")
        guard rate.isFinite, rate >= 8_000, rate <= 384_000 else { throw MacSystemError.refused("BlackHole 采样率不受支持") }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let samples = UnsafeMutablePointer<Int16>.allocate(capacity: AudioRenderState.capacity)
        samples.initialize(repeating: 0, count: AudioRenderState.capacity)
        let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: Int(AudioRenderState.maximumSlice))
        scratch.initialize(repeating: 0, count: Int(AudioRenderState.maximumSlice))
        let spans = UnsafeMutablePointer<PlaybackSpan>.allocate(capacity: AudioRenderState.capacity)
        spans.initialize(repeating: PlaybackSpan(), count: AudioRenderState.capacity)
        let counters = UnsafeMutablePointer<Int64>.allocate(capacity: 6)
        counters.initialize(repeating: 0, count: 6)
        let storage = UnsafeMutablePointer<AudioRenderState>.allocate(capacity: 1)
        storage.initialize(to: AudioRenderState(samples: samples, scratch: scratch, spans: spans, counters: counters,
                                                ticksPerSecond: 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer),
                                                outputRate: rate))
        state = storage
        do {
            let output = try makeUnit(kAudioUnitType_Output, kAudioUnitSubType_HALOutput)
            outputUnit = output
            let converter = try makeUnit(kAudioUnitType_FormatConverter, kAudioUnitSubType_AUConverter)
            converterUnit = converter
            storage.pointee.converter = converter
            var disabled: UInt32 = 0
            var enabled: UInt32 = 1
            try set(output, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disabled)
            try set(output, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enabled)
            var deviceID = device.id
            try set(output, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID)
            var maximum = AudioRenderState.maximumSlice
            try set(output, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximum)
            try set(converter, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximum)
            var input = AudioStreamBasicDescription(mSampleRate: 16_000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
            var hardware = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            try set(converter, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &input)
            try set(converter, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &hardware)
            try set(output, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &hardware)
            var source = AURenderCallbackStruct(inputProc: sourceRender, inputProcRefCon: UnsafeMutableRawPointer(storage))
            var sink = AURenderCallbackStruct(inputProc: deviceRender, inputProcRefCon: UnsafeMutableRawPointer(storage))
            try set(converter, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &source)
            try set(output, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &sink)
            try checkAudio(AudioUnitInitialize(converter), "初始化采样转换")
            try checkAudio(AudioUnitInitialize(output), "初始化定向音频输出")
            var latency: Float64 = 0
            var latencySize = UInt32(MemoryLayout<Float64>.size)
            try checkAudio(AudioUnitGetProperty(converter, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &latencySize), "读取采样转换延迟")
            guard latency.isFinite, latency >= 0 else { throw MacSystemError.refused("无法确认采样转换延迟") }
            storage.pointee.converterLatency = latency
            try checkAudio(AudioOutputUnitStart(output), "启动 BlackHole 定向输出")
        } catch {
            stop()
            throw error
        }
    }

    public func enqueue(_ pcm: Data) -> Bool {
        precondition(Thread.isMainThread)
        guard let state, pcm.count % 2 == 0, atomicLoad(state.pointee.counters + 5) == 0 else { return false }
        let frames = pcm.count / 2
        guard frames <= AudioRenderState.capacity - queuedFrames else { return false }
        if frames == 0 { return true }
        let counters = state.pointee.counters
        let write = atomicLoad(counters + 1)
        let read = atomicLoad(counters)
        guard Int64(frames) <= Int64(AudioRenderState.capacity) - (write - read) else { return false }
        let offset = Int(write % Int64(AudioRenderState.capacity))
        let first = min(frames, AudioRenderState.capacity - offset)
        pcm.withUnsafeBytes { bytes in
            memcpy(state.pointee.samples + offset, bytes.baseAddress!, first * 2)
            if first < frames { memcpy(state.pointee.samples, bytes.baseAddress! + first * 2, (frames - first) * 2) }
        }
        enqueued += Int64(frames)
        atomicStore(counters + 1, write + Int64(frames))
        return true
    }

    public var queuedFrames: Int {
        precondition(Thread.isMainThread)
        guard let state else { return 0 }
        let counters = state.pointee.counters
        guard atomicLoad(counters + 5) == 0 else { return Int(enqueued - played) }
        let origin = atomicLoad(counters + 4)
        guard origin != 0 else { return Int(enqueued - played) }
        // Count only real 16 kHz samples, including converter-prefetched samples
        // and hardware buffers whose presentation timestamp is still in the future.
        let seconds = (Double(mach_absolute_time()) - Double(origin)) / state.pointee.ticksPerSecond
            - state.pointee.converterLatency
        let position = Int64(max(0, seconds * 16_000))
        var head = atomicLoad(counters + 2)
        let tail = atomicLoad(counters + 3)
        while head < tail {
            let span = state.pointee.spans[Int(head % Int64(AudioRenderState.capacity))]
            let complete = min(span.frames, max(0, position - span.start))
            played += max(0, complete - partialSpan)
            partialSpan = complete
            if complete < span.frames { break }
            partialSpan = 0
            head += 1
        }
        atomicStore(counters + 2, head)
        return Int(max(0, enqueued - played))
    }

    public func stop() {
        precondition(Thread.isMainThread)
        if let outputUnit {
            AudioOutputUnitStop(outputUnit)
            AudioUnitUninitialize(outputUnit)
            AudioComponentInstanceDispose(outputUnit)
            self.outputUnit = nil
        }
        if let converterUnit {
            AudioUnitUninitialize(converterUnit)
            AudioComponentInstanceDispose(converterUnit)
            self.converterUnit = nil
        }
        if let state {
            // AudioOutputUnitStop/Uninitialize complete before any storage is freed.
            memset(state.pointee.samples, 0, AudioRenderState.capacity * MemoryLayout<Int16>.size)
            memset(state.pointee.scratch, 0, Int(AudioRenderState.maximumSlice) * MemoryLayout<Int16>.size)
            state.pointee.samples.deallocate()
            state.pointee.scratch.deallocate()
            state.pointee.spans.deinitialize(count: AudioRenderState.capacity)
            state.pointee.spans.deallocate()
            state.pointee.counters.deinitialize(count: 6)
            state.pointee.counters.deallocate()
            state.deinitialize(count: 1)
            state.deallocate()
            self.state = nil
        }
        enqueued = 0
        played = 0
        partialSpan = 0
    }

    private func makeUnit(_ type: OSType, _ subtype: OSType) throws -> AudioUnit {
        var description = AudioComponentDescription(componentType: type, componentSubType: subtype,
                                                     componentManufacturer: kAudioUnitManufacturer_Apple,
                                                     componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw MacSystemError.refused("系统音频模块不可用") }
        var unit: AudioUnit?
        try checkAudio(AudioComponentInstanceNew(component, &unit), "创建系统音频模块")
        guard let unit else { throw MacSystemError.refused("系统音频模块未返回实例") }
        return unit
    }

    private func set<T>(_ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement, _ value: inout T) throws {
        try withUnsafePointer(to: &value) {
            try checkAudio(AudioUnitSetProperty(unit, property, scope, element, $0, UInt32(MemoryLayout<T>.size)), "配置系统音频模块")
        }
    }

    deinit { stop() }
}
