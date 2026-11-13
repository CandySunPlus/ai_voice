# AI Passport 局域网协议 v1

## 安全与传输

仅 IPv4 局域网；Mac 必须绑定用户选择的具体接口地址，不绑定通配地址，不映射公网端口。控制使用 TCP 端口 43821，音频使用相同数字的 UDP 端口。控制 JSON 单行最多 8192 字节，音频包最多 1024 字节。配对经 USB 串口完成，每个设备／主机独立生成 32 字节随机密钥（64 位十六进制文本）。音频在可信局域网明文传输，但每包均鉴权；本协议不宣称加密音频。

设备显式选择保存的主机。设备到主机先发送一行：

```json
{"v":1,"type":"hello","device":"32位十六进制设备ID","host":"32位十六进制主机ID","nonce":"32位随机十六进制"}
```

Mac 返回：

```json
{"v":1,"type":"welcome","nonce":"32位随机十六进制","mac":"64位小写十六进制HMAC"}
```

welcome 的 HMAC-SHA256 使用配对密钥，输入 UTF-8 文本 `welcome|device|host|deviceNonce|hostNonce`。会话密钥是配对密钥对 UTF-8 `session|deviceNonce|hostNonce` 的 HMAC-SHA256，原始 32 字节。会话标识为 hostNonce。设备验证 welcome 后发送已签名 `ready`；Mac 未收到 ready 不接受音频或设备操作。新连接必须重新握手、清除输入目标。

## 控制消息

双方各自维护从 1 开始的无符号 32 位递增序号（不能回绕，耗尽时重连）：

```json
{"seq":1,"kind":"ping","body":"e30=","mac":"64位小写十六进制"}
```

body 是紧凑 UTF-8 JSON 对象的标准 base64 编码。HMAC 输入为 UTF-8 `sessionID|seq|kind|body`。TCP 保序；重复序号只回 ack，不重新执行；跳号、非法签名、错误类型立即中止。除 ack 外每条有效消息都返回 `ack`，body 为 `{"seq":1}`；ack 自身也有独立发送序号但不再要求 ack。消息重传必须保留原序号与原消息，不允许生成新的按键事件。任意未确认消息超过 2 秒，或连续 3 秒无已认证消息，结束会话。心跳 ping 每 1 秒一次。

设备 → Mac：

- `ready {}`：完成设备密钥证明。
- `ping {}`。
- `select {"id":"输入目标ID"}`：仅待命时允许。
- `start {"recording":正整数}`：按下上键；只有目标及输入焦点确认才接受。
- `stop {"recording":正整数,"last":最后音频序号}`：松开上键；Mac 在尾部播放完成后结束豆包。
- `cancel {}`：取消，立即清空缓冲并释放快捷键，不模拟 Enter。
- `list {}`：回到目标选择页前取消录音，再请求目标列表。

Mac → 设备：

- `targets {"items":[{"id":"ID","app":"应用","title":"短标题"}]}`：最多 12 项，单条 id 最多 128 个 UTF-8 字节，app/title 各最多 48 个 UTF-8 字节；不是任务状态。
- `state {"phase":"idle|target|preparing|recording|draining|waiting|error","message":"短提示","target":"ID或空串","task":"unknown"}`：target 最多 128 个 UTF-8 字节，message 最多 192 个 UTF-8 字节。
- `speak {"recording":正整数}`：音频通路和输入法准备等待结束后允许设备开始采集。未收到前设备不采集。
- `ack`、`ping`。

`waiting` 表示本轮音频已排空、快捷键已结束，等待豆包出字及用户核对；同一输入目标可以请求下一录音轮次，每次 start 仍须由 Mac 重新核验真实焦点。设备请求选择输入目标、尚未得到运行主机确认时，不得将本地等待状态当作已确认目标。

Mac 不发送键盘 Enter，不执行转写文本。设备下键始终取消／返回。控制状态与任务状态分开：task 只能为 unknown，任务数量不可用。

## UDP 音频

每包大端网络序头：`magic[4]="APV1" | hostNonce[16]原始字节 | recording:uint32 | sequence:uint32 | samples:uint16`，随后为 `samples×2` 字节 PCM16LE 单声道，最后 32 字节 HMAC-SHA256。HMAC 覆盖头和 PCM，密钥为会话密钥。固定采样率 16000 Hz，典型每包 320 样本（20 ms），最大 320。sequence 从 1 开始，重复／旧包丢弃；小范围乱序由 Mac 有界抖动缓冲处理。音频来源地址须与已认证 TCP 对端相同；录音 ID 必须等于当前会话的 recording。新会话绝不接收旧包。

UDP 源端口不属于会话身份，接收端不得固定绑定首轮源端口；同一认证连接须允许连续录音轮次更换源端口。

抖动缓冲上限 10 包（200 ms）；最多等待缺包 60 ms 后用等长静音补齐，不重放旧语音。stop 后最多等待缺失尾包 300 ms，再排空已接收音频。焦点变化、锁屏、安全输入、急停、断连均立即清理，不排空到新目标。录音最长 120 秒，避免无限占用按键。

## USB 配置

串口 115200，UTF-8 JSONL，上电后不输出任何密钥或 Wi-Fi 密码。仅用户在设备上长按 OK 进入配置状态时才接受以下命令：

- `{"op":"info"}` → `{"ok":true,"device":"设备ID","board":"ai-passport-esp32c3-8mb","protocol":1}`；返回的是固件声明，不代替实物核验。
- `{"op":"configure","wifi":[{"ssid":"...","password":"..."}],"host":{"id":"主机ID","name":"显示名","address":"具体IPv4地址","port":43821,"key":"64位十六进制"}}`：最多 4 个网络／4 个主机，网络按 SSID 合并、主机按 ID 合并，同名更新、异名追加，不删除其他地点配置；超限拒绝整个事务。验证完整配置后持久化，回应 `{"ok":true}`，断开旧会话并重连。
- `{"op":"erase"}`：设备物理配置模式内清除本应用配对与网络，回应 ok；不会从 Mac 自动调用。

Mac 端密钥存入登录钥匙串；设备端存入本应用 NVS。未启用 Flash 加密的实物可被物理读取，不声称抗物理提取。诊断日志不记录 USB 请求正文、密钥、密码、音频、转写或窗口正文。

## Mac 系统模块接口（仓库内部）

`Sources/PassportCore/MacSystem.swift` 拥有以下类型，其他文件不重复定义：

```swift
public struct InputTarget: Codable, Identifiable {
    public let id: String
    public let app: String
    public let title: String
}
public final class TargetAccess {
    public init()
    public var isTrusted: Bool { get }
    public func requestAccess()
    public func listTargets() -> [InputTarget]
    public func activate(_ id: String) throws
    public func lockFocus(_ id: String) throws
    public func validateFocus() -> Bool
    public func clear()
}
public struct VoiceShortcut: Codable {
    public var keyCode: UInt16
    public var modifiers: UInt64 // CGEventFlags rawValue
    public var mode: String // hold 或 tap
    public init(keyCode: UInt16, modifiers: UInt64, mode: String)
}
public final class VoiceKeys {
    public init()
    public func begin(_ shortcut: VoiceShortcut) throws
    public func end()
}
public struct AudioOutput: Identifiable {
    public let id: UInt32
    public let name: String
    public let uid: String
}
public final class AudioBridge {
    public init()
    public static func outputs() -> [AudioOutput]
    public func start(deviceUID: String) throws
    public func enqueue(_ pcm: Data) -> Bool // 16kHz PCM16LE 单声道，有界；false 为溢出
    public var queuedFrames: Int { get }
    public func stop() // 同步清理内存，不修改系统默认设备
}
```

这些系统方法均由主线程调用。音频回调禁止分配、阻塞或向日志写入。TargetAccess 必须核对前台应用、精确窗口和可编辑焦点身份；不能确认时拒绝，不用标题猜测定位。窗口列表仅自动操作当前 Space 的普通窗口；无法可靠验证的目标保留手动激活路径。
