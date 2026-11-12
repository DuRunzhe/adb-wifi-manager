// AdbWifiBar —— Android 无线调试连接状态菜单栏工具
//
// 一个极简的 macOS 菜单栏辅助程序：展示当前无线调试连接状态，
// 并可直接启动/停止后台守护服务。真正的连接逻辑由 adb-wifi.sh 负责。
//
// 编译: ./build.sh

import Cocoa

// MARK: - 配置

let APP_BUNDLE_ID = "com.durunzhe.adb-wifibar"

/// 项目仓库：用于「关于」里的主页/反馈入口与版本更新检查
let REPO_SLUG = "DuRunzhe/adb-wifi-manager"
let REPO_URL = "https://github.com/" + REPO_SLUG
let RELEASES_URL = REPO_URL + "/releases"

/// App 版本号：由 build.sh 写入 Info.plist。
/// 优先读自定义键 ADBWifiFullVersion（可能带 -alpha.N 后缀）；
/// CFBundleShortVersionString 只存数字三段（Apple 对 bundle 版本的要求）。
/// 直接用 swiftc 跑的开发态没有 bundle，降级为 dev，避免误判有新版本。
let APP_VERSION: String = {
    if let full = Bundle.main.infoDictionary?["ADBWifiFullVersion"] as? String, !full.isEmpty {
        return full
    }
    let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    return v.isEmpty ? "dev" : v
}()
let APP_BUILD: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""

/// 脚本路径：优先读取环境变量，其次按 App 所在位置推导
/// 记录/读取上次成功使用的脚本路径，保证迁移目录后仍能自动找到。
func savedScriptPath() -> String? {
    let conf = NSHomeDirectory() + "/Library/Application Support/adb-wifi-manager/script_path.txt"
    guard let t = try? String(contentsOfFile: conf, encoding: .utf8) else { return nil }
    let p = t.trimmingCharacters(in: .whitespacesAndNewlines)
    return FileManager.default.fileExists(atPath: p) ? p : nil
}

func saveScriptPath(_ p: String) {
    let dir = NSHomeDirectory() + "/Library/Application Support/adb-wifi-manager"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? p.write(toFile: dir + "/script_path.txt", atomically: true, encoding: .utf8)
}

/// 依次尝试多个位置，避免把项目路径写死。
/// 优先级：环境变量 > 上次记录 > 相对 App 推导 > 常见安装位置 > PATH
func resolveScriptPath() -> String {
    if let p = ProcessInfo.processInfo.environment["ADB_WIFI_SCRIPT"], !p.isEmpty,
       FileManager.default.fileExists(atPath: p) {
        return p
    }
    if let p = savedScriptPath() { return p }

    // 情形 1：直接运行 build/AdbWifiBar.app，项目根在 .app 的上一级
    let exe = Bundle.main.executableURL?.path ?? ""
    var dir = URL(fileURLWithPath: exe).deletingLastPathComponent()   // MacOS
    dir = dir.deletingLastPathComponent()                              // Contents
    dir = dir.deletingLastPathComponent()                              // .app
    let fromBuild = dir.deletingLastPathComponent().appendingPathComponent("bin/adb-wifi.sh").path
    if FileManager.default.fileExists(atPath: fromBuild) {
        saveScriptPath(fromBuild)
        return fromBuild
    }

    // 情形 2：App 被复制到 ~/Applications 等位置时，按默认安装目录查找
    // （与 get.sh / install.sh 的默认值一致；其他位置由 script_path.txt
    // 或 ADB_WIFI_SCRIPT 环境变量指定，避免在源码里写死个人目录）
    let home = NSHomeDirectory()
    let candidates = [
        home + "/mycode/adb-wifi-manager/bin/adb-wifi.sh",
    ]
    for c in candidates where FileManager.default.fileExists(atPath: c) {
        saveScriptPath(c)
        return c
    }

    // 情形 3：从 PATH 中找 adb-wifi.sh
    if let path = ProcessInfo.processInfo.environment["PATH"] {
        for d in path.split(separator: ":") {
            let c = String(d) + "/adb-wifi.sh"
            if FileManager.default.fileExists(atPath: c) {
                saveScriptPath(c)
                return c
            }
        }
    }
    // 都找不到时返回最可能的位置，便于报错时提示
    return home + "/mycode/adb-wifi-manager/bin/adb-wifi.sh"
}

let SCRIPT = resolveScriptPath()

/// 让脚本输出机器可读的协议字段（见 bin/adb-wifi.sh 文件头「输出协议」）。
/// 协议值为 ASCII 枚举，界面文案一律由本地 i18n 渲染，两边彻底分开。
let KV_ENV = ["ADBWIFI_FORMAT": "kv"]

// MARK: - 执行脚本

@discardableResult
func runScript(_ args: [String], timeout: TimeInterval = 20,
               env extraEnv: [String: String] = [:]) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [SCRIPT] + args
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:"
        + NSHomeDirectory() + "/Library/Android/sdk/platform-tools"
    for (k, v) in extraEnv { env[k] = v }
    p.environment = env
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do {
        try p.run()
    } catch {
        return (-1, L.t("err.scriptFailed", error.localizedDescription))
    }
    // 超时保护，避免界面卡死
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline {
        usleep(50_000)
    }
    if p.isRunning {
        p.terminate()
        return (-1, L.t("err.timeout"))
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// MARK: - 状态

/// 单台设备的链路质量指标（由 `netinfo` 采集，见 bin/adb-wifi.sh）
struct DevLink {
    var serial = "", transport = "", model = ""
    var ssid = "", bssid = "", freq = "", channel = ""
    var linkMbps = "", rssi = ""
    var rttMin = "", rttAvg = "", rttMax = ""
    var battery = "", charging = ""
    var isWifi: Bool { transport == "wifi" }
}

/// 单台「当前在线设备」，来自脚本 `devices` 子命令的 DEV_<n>_* 字段。
/// 与 DevLink（链路质量）分开：这里只关心"能对哪台设备下指令"，
/// 不做任何耗时采集，保证菜单打开速度。
struct DevEntry {
    var serial = "", state = "", transport = "", model = ""
    var isWifi: Bool { transport == "wifi" }
    var isUsb: Bool { transport == "usb" }
    /// 可作为"在手机上打开设置页"的对象：只有在线设备才行
    var usable: Bool { state == "device" }
    var displayName: String { model.isEmpty ? serial : "\(model)" }
    var stateText: String {
        switch state {
        case "device": return ""
        case "unauthorized": return "unauthorized"
        case "offline": return "offline"
        default: return state
        }
    }
}

struct Status {
    var running = false
    var pid = ""
    var mode = ""              // launchd / manual / stopped
    var endpoints: [String] = []
    var allDevices: [(String, String)] = []
    /// 由脚本 `devices` 子命令填充；与 allDevices 同源但带通道/状态标记
    var devEntries: [DevEntry] = []
    var hasUSB = false
    var usbFound: [String] = []
    var mdnsOK = false
    var knownFound: [String] = []
    var macIP = ""
    var devModel = ""
    // 插 USB 自动转 TCP 模式的状态
    var tcpipPort = ""
    var tcpipListen = false
    var autoTcpip = false
    // 传输速率（Mac 视角：手机→Mac 为下行）
    var rateDownHuman = ""
    var rateDownKB = ""
    var rateUpHuman = ""
    var rateTotalDown = ""
    var rateTotalUp = ""

    // ---- 链路质量（多设备：每台一份；Mac 侧全局一份）----
    var devLinks: [DevLink] = []
    var macChannel = ""
    var macRate = ""
    var macRSSI = ""
    var macBattery = ""
    var macPower = ""
    // 传输时的平均值 / 峰值（Mbps，与链路速率对比用）
    var rateAvgMbps = ""
    var rateMaxMbps = ""
    /// 链路数据采集时间戳（epoch 秒，来自 NET_AT），用于显示数据新鲜度
    var netAt = ""
    /// mDNS 细分状态：ok / stalled（adb server 卡死，已尝试自愈）/ blocked（网络屏蔽）
    var mdnsState = ""
    /// 连续为空的轮数（用于判断是短暂抖动还是持续失效）
    var mdnsEmptyTurns = ""
    /// Mac 侧当前 Wi-Fi 的 SSID（用于判断手机与电脑是否在同一 AP 下）
    var macSSID = ""
    // 结构化诊断结论（由脚本层统一给出，与 TUI 完全同源）
    var diagLevel = ""
    var diagCode = ""
    var diagTitle = ""
    var diagHint = ""
    var diagAction = ""
    var raw = ""
    var loadError = ""
}

func splitCSV(_ v: String?) -> [String] {
    guard let v = v, !v.isEmpty else { return [] }
    return v.split(separator: ",").map(String.init).filter { !$0.isEmpty }
}

/// 菜单栏 App 自身的更新日志（与守护日志分开），排查自动安装失败时看这里：
/// ~/Library/Application Support/adb-wifi-manager/logs/menubar-update.log
func updateLog(_ s: String) {
    let dir = NSHomeDirectory() + "/Library/Application Support/adb-wifi-manager/logs"
    let path = dir + "/menubar-update.log"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(stamp) \(s)\n"
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8) ?? Data())
        h.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// 把链路速率（Mbps）换算成字节基准（MB/s）并按大小选精度。
/// 用户对「MB/s」更直观，也更方便与菜单里已有的 ↓↑ 传输速率直接对比。
func linkRateText(_ mbps: Double) -> String {
    let mbs = mbps / 8
    if mbs >= 10 { return String(format: "%.0f", mbs) }
    if mbs >= 1  { return String(format: "%.1f", mbs) }
    return String(format: "%.2f", mbs)
}

/// 解析脚本的 KEY=VALUE 输出（`diag` 的原生格式，以及 `ADBWIFI_FORMAT=kv` 的结果协议）。
/// 只认第一行等号，忽略不含等号的行（如误入的日志/提示），值两端去空白。
func parseKV(_ text: String) -> [String: String] {
    var kv: [String: String] = [:]
    for line in text.split(separator: "\n") {
        guard let eq = line.firstIndex(of: "=") else { continue }
        let k = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
        let v = String(line[line.index(after: eq)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !k.isEmpty { kv[k] = v }
    }
    return kv
}

/// 解析 KEY=VALUE 形式的 diag 输出
func loadStatus() -> Status {
    let r = runScript(["diag"], timeout: 20)
    var s = Status()
    s.raw = r.out
    let kv = parseKV(r.out)
    if kv.isEmpty {
        s.loadError = r.out.isEmpty ? L.t("err.noStatus") : String(r.out.prefix(120))
        return s
    }
    s.pid = kv["DAEMON_PID"] ?? ""
    s.running = !s.pid.isEmpty
    s.mode = kv["DAEMON_MODE"] ?? "stopped"
    s.endpoints = splitCSV(kv["WIFI_DEVICES"])
    s.hasUSB = !(kv["USB_SERIAL"] ?? "").isEmpty
    s.usbFound = splitCSV(kv["USB_FOUND"])
    s.knownFound = splitCSV(kv["KNOWN_FOUND"])
    s.mdnsOK = (kv["MDNS_OK"] ?? kv["MDNS_ADB_COUNT"] ?? "0") != "0"
    s.macIP = kv["MAC_IP"] ?? ""
    s.devModel = kv["DEV_MODEL"] ?? ""
    s.tcpipPort = kv["TCPIP_PORT"] ?? ""
    s.tcpipListen = (kv["TCPIP_LISTEN"] ?? "0") == "1"
    s.autoTcpip = (kv["AUTO_TCPIP"] ?? "0") == "1"
    s.rateDownHuman = kv["RATE_DOWN_HUMAN"] ?? ""
    s.rateDownKB = kv["RATE_DOWN_KB"] ?? ""
    s.rateUpHuman = kv["RATE_UP_HUMAN"] ?? ""
    s.rateTotalDown = kv["RATE_TOTAL_DOWN_MB"] ?? ""
    s.rateTotalUp = kv["RATE_TOTAL_UP_MB"] ?? ""

    s.macChannel = kv["NET_MAC_CHANNEL"] ?? ""
    s.macRate = kv["NET_MAC_RATE"] ?? ""
    s.macRSSI = kv["NET_MAC_RSSI"] ?? ""
    s.macBattery = kv["NET_MAC_BATTERY"] ?? ""
    s.macPower = kv["NET_MAC_POWER"] ?? ""
    s.rateAvgMbps = kv["NET_RATE_AVG_MBPS"] ?? ""
    s.rateMaxMbps = kv["NET_RATE_MAX_MBPS"] ?? ""
    s.netAt = kv["NET_AT"] ?? ""
    s.mdnsState = kv["MDNS_STATE"] ?? ""
    s.mdnsEmptyTurns = kv["MDNS_EMPTY_TURNS"] ?? ""
    s.macSSID = kv["NET_MAC_SSID"] ?? ""

    let devCount = Int(kv["NET_DEV_COUNT"] ?? "0") ?? 0
    if devCount > 0 {
        for i in 1...devCount {
            var d = DevLink()
            d.serial = kv["NET_DEV_\(i)_SERIAL"] ?? ""
            d.transport = kv["NET_DEV_\(i)_TRANSPORT"] ?? ""
            d.model = kv["NET_DEV_\(i)_MODEL"] ?? ""
            d.ssid = kv["NET_DEV_\(i)_SSID"] ?? ""
            d.bssid = kv["NET_DEV_\(i)_BSSID"] ?? ""
            d.freq = kv["NET_DEV_\(i)_FREQ"] ?? ""
            d.channel = kv["NET_DEV_\(i)_CHANNEL"] ?? ""
            d.linkMbps = kv["NET_DEV_\(i)_LINK"] ?? ""
            d.rssi = kv["NET_DEV_\(i)_RSSI"] ?? ""
            d.rttMin = kv["NET_DEV_\(i)_RTT_MIN"] ?? ""
            d.rttAvg = kv["NET_DEV_\(i)_RTT_AVG"] ?? ""
            d.rttMax = kv["NET_DEV_\(i)_RTT_MAX"] ?? ""
            d.battery = kv["NET_DEV_\(i)_BATTERY"] ?? ""
            d.charging = kv["NET_DEV_\(i)_CHARGING"] ?? ""
            if !d.serial.isEmpty { s.devLinks.append(d) }
        }
    }
    s.diagLevel = kv["DIAG_LEVEL"] ?? ""
    s.diagCode = kv["DIAG_CODE"] ?? ""
    s.diagTitle = kv["DIAG_TITLE"] ?? ""
    s.diagHint = kv["DIAG_HINT"] ?? ""
    s.diagAction = kv["DIAG_ACTION"] ?? ""
    for item in splitCSV(kv["ALL_DEVICES"]) {
        let parts = item.split(separator: "|", maxSplits: 1).map(String.init)
        if parts.count == 2 { s.allDevices.append((parts[0], parts[1])) }
    }
    s.devEntries = loadDevices()
    return s
}

/// 当前在线设备清单（脚本 `devices` 子命令）。
/// 失败时退回 `diag` 里已有的 ALL_DEVICES，保证旧脚本也能列出设备。
func loadDevices() -> [DevEntry] {
    // 必须显式带 kv：不加时脚本走 text 模式，输出的是对齐过的中文表格，
    // parseKV 解析不到 DEV_n_* 字段（曾导致多设备只显示一台）。
    let kv = parseKV(runScript(["devices"], timeout: 15, env: KV_ENV).out)
    let n = Int(kv["DEV_COUNT"] ?? "0") ?? 0
    var list: [DevEntry] = []
    if n > 0 {
        for i in 1...n {
            var d = DevEntry()
            d.serial = kv["DEV_\(i)_SERIAL"] ?? ""
            d.state = kv["DEV_\(i)_STATE"] ?? ""
            d.transport = kv["DEV_\(i)_TRANSPORT"] ?? ""
            d.model = kv["DEV_\(i)_MODEL"] ?? ""
            if !d.serial.isEmpty { list.append(d) }
        }
    }
    return list
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var status = Status()
    var logWindow: NSWindow?
    var logTextView: NSTextView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(["smartphone", "iphone", "wifi"], fallbackText: "ADB")

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        refresh()
        // 兜底轮询（事件监听失效时仍能更新）。
        // 间隔自适应：设备连接稳定时不必频繁拉起 adb 子进程，
        // 一旦状态发生变化（或处于故障态）才切回快节奏。
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        watchEvents()
    }

    /// 监听脚本侧的设备事件日志（由 adb track-devices 实时写入），
    /// 一旦有变化立刻刷新，实现"设备接入/断开/插拔"的即时感知。
    var eventSource: DispatchSourceFileSystemObject?
    var eventFD: Int32 = -1

    func watchEvents() {
        let path = NSHomeDirectory() + "/Library/Application Support/adb-wifi-manager/state/events.log"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        eventFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .global())
        src.setEventHandler { [weak self] in
            self?.refresh()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        eventSource = src
    }

    var busy = false
    /// 「立即开启 TCP 模式」待处理的 USB 序列号（菜单重建时写入，动作触发时读取）
    var pendingTcpipSerials: [String] = []
    var lastLoadedAt = Date.distantPast

    var refreshing = false
    var lastRefreshAt = Date.distantPast

    /// 轮询间隔（秒）。用户可通过环境变量 ADBWIFI_POLL_INTERVAL 覆盖
    static let pollInterval: TimeInterval = {
        if let v = ProcessInfo.processInfo.environment["ADBWIFI_POLL_INTERVAL"],
           let d = Double(v), d >= 1 { return d }
        return 5.0
    }()

    func refresh() {
        guard !busy, !refreshing else { return }
        // 节流：事件可能短时间密集触发，避免频繁拉起子进程
        if Date().timeIntervalSince(lastRefreshAt) < 0.3 { return }
        lastRefreshAt = Date()
        refreshing = true
        DispatchQueue.global(qos: .background).async {
            let s = loadStatus()
            DispatchQueue.main.async {
                self.status = s
                self.lastLoadedAt = Date()
                self.refreshing = false
                self.updateIcon(s)
            }
        }
    }

    /// 按候选顺序尝试系统图标。
    /// 注意：部分 SF Symbols 在较新 macOS 上不存在（如 smartphone.slash、
    /// smartphone.radiowaves.left.and.right），若直接用会得到 nil，
    /// 导致菜单栏图标区域空白、用户看不到本程序。因此必须逐级降级。
    ///
    /// 菜单栏直接用系统 SF Symbol 渲染，不经过图片文件：
    /// 系统会按菜单栏标准尺寸绘制并自动适配深浅色外观，清晰度和大小最正。
    /// App 图标（.icns）则由 menubar/gen-icon.swift 用同一个符号生成，
    /// 两者视觉同源但各自走最适合的渲染路径。
    func setIcon(_ candidates: [String], fallbackText: String) {
        guard let button = statusItem.button else { return }
        for name in candidates {
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: "ADB WiFi") {
                img.isTemplate = true
                button.image = img
                button.title = ""
                return
            }
        }

        // 所有图标都不可用时，用文字保证菜单栏一定可见
        button.image = nil
        button.title = " " + fallbackText + " "
    }

    var currentIconState = ""

    func updateIcon(_ s: Status) {
        // 按状态选择候选符号；状态未变化时不重复设置图片，避免菜单栏闪烁
        let candidates: [String]
        let key: String
        if !s.running {
            candidates = ["smartphone.slash", "iphone.slash", "wifi.slash", "exclamationmark.circle"]
            key = "stopped"
        } else if s.endpoints.isEmpty {
            candidates = ["smartphone", "iphone", "wifi"]
            key = "idle"
        } else {
            candidates = ["iphone.radiowaves.left.and.right", "smartphone.radiowaves.left.and.right",
                          "dot.radiowaves.left.and.right", "antenna.radiowaves.left.and.right",
                          "smartphone", "iphone", "wifi"]
            key = "connected"
        }
        guard key != currentIconState else { return }
        currentIconState = key
        setIcon(candidates, fallbackText: "ADB")
    }

    // 菜单每次打开时重建
    func disabledItem(_ title: String, tooltip: String? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        if let t = tooltip { it.toolTip = t }
        return it
    }

    /// 设备区：每台在线设备一个子菜单（复制地址 / 重连本机 / 打开手机设置页）。
    /// 只有一台时直接平铺，不增加点击层级；多台时逐台成项，避免"点谁都一样"。
    /// 菜单底部再放一个「全部设备」子菜单承载批量动作。
    func addDeviceItems(to menu: NSMenu, s: Status) {
        // 单设备与多设备走**同一套结构**：每台设备一个子菜单，内部依次为
        //   状态行 → 刷新链路质量 → 分隔线 → 操作
        // 以前单设备时拍平成一级，导致"同一台设备在两种场景下长得不一样"：
        // 缩进不同、分隔线位置不同、⌘W 这类快捷键时有时无。
        // 统一后单设备只多一次点击，换来完全一致的认知模型。
        for d in s.devEntries {
            let mark = d.usable ? "✓" : (d.state == "unauthorized" ? "!" : "✗")
            var head = "  \(mark) \(d.displayName)"
            var notes: [String] = []
            notes.append(d.isWifi ? L.t("dev.tag.wifi") : L.t("dev.tag.usb"))
            // 「同 AP」标记紧跟在无线/USB 之后，一眼看出连接是否经过 AP 中转
            let apTag = sameAPTag(d, s: s)
            if !apTag.isEmpty { notes.append(apTag) }
            if d.state == "unauthorized" { notes.append(L.t("dev.state.unauthorized")) }
            else if d.state == "offline" { notes.append(L.t("dev.state.offline")) }
            head += " · " + notes.joined(separator: " · ")

            let item = NSMenuItem(title: head, action: nil, keyEquivalent: "")
            // tooltip 说明标题里符号的含义（符号本身没有文字，需要可查的解释）
            var tipText = d.serial
            let apStat = sameAPStatus(d, s: s)
            if d.isWifi {
                switch apStat {
                case .same:      tipText += "\n" + L.t("dev.ap.same.tip")
                case .maybe:     tipText += "\n" + L.t("dev.ap.maybe.tip")
                case .different: tipText += "\n" + L.t("dev.ap.different.tip")
                case .unknown:   break
                }
            }
            item.toolTip = tipText
            item.image = NSImage(systemSymbolName: d.isWifi ? "wifi" : "cable.connector",
                                 accessibilityDescription: nil)
            let sub = NSMenu()

            // ① 状态（延迟 / 信号 / 吞吐 / AP / 电量）—— 只读
            for line in deviceStatusLines(d, s: s) {
                sub.addItem(disabledItem(line.text, tooltip: line.tip))
            }
            // ② 链路质量是「与这台手机通信」的质量，刷新入口挂在这台设备下
            sub.addItem(refreshLinkItem(d, indent: ""))

            // ③ 操作
            let acts = deviceActionItems(d, indent: "")
            if !acts.isEmpty {
                sub.addItem(.separator())
                for it in acts { sub.addItem(it) }
            }
            item.submenu = sub
            menu.addItem(item)
        }
        addAllDevicesItems(to: menu, s: s)
    }

    /// 单台设备可执行的动作（平铺，不嵌套子菜单）
    func deviceActionItems(_ d: DevEntry, indent: String) -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        if d.isWifi { out.append(copyItem(d, indent: indent)) }

        let reconnect = NSMenuItem(title: indent + L.t("dev.reconnect"),
                                   action: #selector(reconnectDevice(_:)), keyEquivalent: "")
        reconnect.target = self
        reconnect.representedObject = d.serial
        reconnect.isEnabled = d.usable
        reconnect.toolTip = d.usable ? L.t("dev.reconnect.tip") : L.t("dev.phone.tip.unusable")
        out.append(reconnect)

        let entries: [(String, Selector)] = [
            ("dev.phone.wireless", #selector(openWirelessForDevice(_:))),
            ("dev.phone.dev", #selector(openDevForDevice(_:))),
        ]
        for (key, sel) in entries {
            let it = NSMenuItem(title: indent + L.t(key), action: sel, keyEquivalent: "")
            it.target = self
            it.representedObject = d.serial
            it.isEnabled = d.usable
            it.toolTip = d.usable ? L.t("menu.phone.tip.connected")
                                  : L.t("dev.phone.tip.unusable")
            out.append(it)
        }
        return out
    }

    // MARK: - 链路分级
    //
    // 分级可视化：等级词 + 五格量表 + 分档界线。
    // 只给"较差"这样的结论词，用户无法判断它是勉强越界还是差得离谱；
    // 补上量表（██░░░）和完整分界线后，不看 tooltip 也能读懂。

    /// 生成量表条：filled 个实心格 + (total-filled) 个空心格
    func meter(filled: Int, total: Int = 5) -> String {
        let n = max(0, min(filled, total))
        return String(repeating: "█", count: n) + String(repeating: "░", count: total - n)
    }

    /// 延迟分级：越小越好。返回 (档位 1-3, 量表, 等级词 key)
    func rttLevel(_ v: Double) -> (step: Int, label: String) {
        // <20 优秀(3格) / 20–50 一般(2格) / >50 较差(1格)
        if v < 20 { return (3, L.t("net.rtt.grade.good")) }
        if v < 50 { return (2, L.t("net.rtt.grade.fair")) }
        return (1, L.t("net.rtt.grade.poor"))
    }

    /// 信号分级：越大（越接近 0）越好，5 档
    func signalLevel(_ v: Double) -> (step: Int, label: String) {
        if v > -50 { return (5, L.t("net.signal.grade.excellent")) }
        if v > -60 { return (4, L.t("net.signal.grade.good")) }
        if v > -70 { return (3, L.t("net.signal.grade.ok")) }
        if v > -80 { return (2, L.t("net.signal.grade.weak")) }
        return (1, L.t("net.signal.grade.bad"))
    }

    /// 吞吐分级：按「峰值 ÷ 上限」的比例，3 档
    func throughputLevel(_ usage: Double) -> (step: Int, label: String) {
        if usage >= 30 { return (3, L.t("net.tp.grade.good")) }
        if usage >= 10 { return (2, L.t("net.tp.grade.fair")) }
        return (1, L.t("net.tp.grade.poor"))
    }

    /// 判断手机与这台 Mac 是否接在同一个 AP 下。
    ///
    /// 限制：macOS 不向普通应用提供 Mac 侧 BSSID（隐私限制），
    /// 因此无法直接比对 BSSID，只能用 SSID + 信道间接推断：
    ///   SSID 不同            → 明确不在同一网络
    ///   SSID 同 + 信道不同   → 不同 AP（同一 SSID 下常有多台 AP 分不同信道）
    ///   SSID 同 + 信道相同   → 大概率同一 AP（同信道也可能恰好是两台 AP，故不下断言）
    enum SameAP { case same, maybe, different, unknown }

    func sameAPStatus(_ d: DevEntry, s: Status) -> SameAP {
        guard d.isWifi else { return .unknown }
        guard let link = s.devLinks.first(where: { $0.serial == d.serial }) else { return .unknown }
        guard !link.ssid.isEmpty, !s.macSSID.isEmpty else { return .unknown }
        if link.ssid != s.macSSID { return .different }
        guard !link.channel.isEmpty, !s.macChannel.isEmpty else { return .maybe }
        return link.channel == s.macChannel ? .same : .different
    }

    /// 设备标题后的「同 AP」标记，直接跟在「无线 / USB」状态后面
    func sameAPTag(_ d: DevEntry, s: Status) -> String {
        guard d.isWifi else { return "" }
        switch sameAPStatus(d, s: s) {
        case .same:      return L.t("dev.ap.same")       // 同一 AP
        case .maybe:     return L.t("dev.ap.maybe")      // 大概率同一 AP
        case .different: return L.t("dev.ap.different")  // 不同 AP
        case .unknown:   return ""
        }
    }

    /// 单台设备的状态行：每个指标都带单位、分级和 tooltip 释义。
    ///
    /// 数值来源（见 bin/adb-wifi.sh 的 net_dev_collect）：
    ///   RTT   = Mac 对手机 IP 做 `ping -c 3` 的往返时延
    ///   RSSI  = 手机 `dumpsys wifi` 上报的信号强度（dBm）
    ///   Link  = 手机上报的 Wi-Fi 协商速率（Mbps，理论值，非实测吞吐）
    ///   实测  = adb server 侧统计的传输速率（最近 10 分钟有流量时的平均/峰值）
    func deviceStatusLines(_ d: DevEntry, s: Status) -> [(text: String, tip: String?)] {
        guard let link = s.devLinks.first(where: { $0.serial == d.serial }) else { return [] }
        var out: [(text: String, tip: String?)] = []

        if link.isWifi {
            // ---- RTT ----
            if let rtt = Double(link.rttAvg) {
                let lv = rttLevel(rtt)
                var tip = L.t("net.rtt.tip")
                if !link.rttMin.isEmpty && !link.rttMax.isEmpty {
                    tip += "\n\n" + L.t("net.rtt.range", link.rttMin, link.rttMax)
                }
                out.append(("    " + L.t("net.rtt.line",
                                         String(format: "%.1f", rtt),
                                         meter(filled: lv.step, total: 3),
                                         lv.label,
                                         L.t("net.rtt.scale")), tip))
            }
            // ---- 信号 ----
            if let rssi = Double(link.rssi) {
                let lv = signalLevel(rssi)
                var tip = L.t("net.signal.tip")
                if !s.macRSSI.isEmpty { tip += "\n\n" + L.t("net.signal.mac", s.macRSSI) }
                out.append(("    " + L.t("net.signal.line", link.rssi,
                                         meter(filled: lv.step, total: 5),
                                         lv.label,
                                         L.t("net.signal.scale")), tip))
            }
            // ---- adb 吞吐量（用户最关心：现在能跑多快，以及跑得好不好）----
            // 三个数一起看：
            //   上限 = 协商速率 × 60%，这台设备理论上能达到的 adb 速度天花板
            //   平均 = 最近 10 分钟「有流量时」的平均，代表日常典型速度
            //   最大 = 同期峰值，决定大文件 push/pull 的耗时
            // 评级按「实测峰值 ÷ 上限」的实际利用率来算，而不是看绝对速度：
            // 不同 Wi-Fi 制式（433 / 866 / 1200 Mbps）对应一个 32 / 64 / 90 MB/s 的上限，
            // 只有利用率才能跨设备横向比较。
            if let mbps = Double(link.linkMbps) {
                let capText = linkRateText(mbps * 0.6)
                let avgMBs = Double(s.rateAvgMbps) ?? 0
                let peakMBs = Double(s.rateMaxMbps) ?? 0
                let hasTraffic = avgMBs > 0 || peakMBs > 0

                var tip = L.t("net.tp.tip", link.linkMbps, capText)
                let avgText = avgMBs < 0.8 ? L.t("net.tp.negligible") : linkRateText(avgMBs)

                if hasTraffic, mbps > 0 {
                    // 利用率：峰值占上限的百分比（上限已经是 60%，这里再取一次比例）
                    let usage = peakMBs / (mbps * 0.6) * 100
                    let lv = throughputLevel(usage)
                    tip += "\n\n" + L.t("net.tp.tip.usage", String(format: "%.0f", usage))
                    out.append(("    " + L.t("net.tp.main", capText, avgText,
                                             linkRateText(peakMBs),
                                             meter(filled: lv.step, total: 3),
                                             lv.label,
                                             String(format: "%.0f", usage)), tip))
                } else {
                    // 无流量时也要能看懂"健康标准是什么"，否则这行等于没信息
                    out.append(("    " + L.t("net.tp.idle", capText,
                                             L.t("net.tp.scale")), tip))
                }
            }
            // ---- AP 信息 ----
            if !link.ssid.isEmpty {
                let ch = link.channel.isEmpty ? "-" : link.channel
                let freq = link.freq.isEmpty ? "-" : link.freq
                // BSSID 是区分「同一 SSID 下的不同 AP」的唯一依据：
                // 两台手机 BSSID 相同 = 接在同一个 AP 上，互传延迟最低；
                // 不同则跨 AP 转发，RTT 会明显变高。
                // 完整 12 位太长，显示末 5 位（形如 …8d:c7）足够区分且不挤占宽度。
                let bssidShort: String
                if link.bssid.isEmpty {
                    bssidShort = "-"
                } else {
                    let parts = link.bssid.split(separator: ":")
                    bssidShort = parts.count >= 2
                        ? "…" + parts.suffix(2).joined(separator: ":")
                        : link.bssid
                }
                out.append(("    " + L.t("net.ap.line", link.ssid, ch, freq, bssidShort),
                            L.t("net.ap.tip", link.bssid.isEmpty ? "-" : link.bssid,
                                s.macChannel.isEmpty ? "-" : s.macChannel)))
            }
        } else {
            // USB 设备：走本地总线，不存在网络往返；也拿不到无线指标
            out.append(("    " + L.t("net.usb.line"), L.t("net.usb.tip")))
        }
        // ---- 电量 ----
        if !link.battery.isEmpty {
            let text = link.charging == "1"
                ? L.t("net.battery.line", link.battery, L.t("net.battery.charging"))
                : L.t("net.battery.lineNoCharge", link.battery)
            out.append(("    " + text, L.t("net.battery.tip")))
        }
        return out
    }

    /// 「刷新这台设备的链路质量」菜单项。
    /// tooltip 里带上数据采集时间，让用户知道点之前的数据有多旧。
    func refreshLinkItem(_ d: DevEntry, indent: String) -> NSMenuItem {
        let it = NSMenuItem(title: indent + L.t("net.refresh"),
                            action: #selector(refreshLinkQuality(_:)), keyEquivalent: "")
        it.target = self
        it.representedObject = d.serial
        // 采集时间是全局一份（NET_AT），单台刷新后仍是整体重采时间，
        // 因此这里如实说明，不假装是"这台设备的采集时间"。
        var tip = L.t("net.refresh.tip")
        let ageText = netAgeText(status)
        if !ageText.isEmpty {
            tip += "\n" + L.t("net.age.line", ageText)
        }
        it.toolTip = tip
        it.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        it.isEnabled = d.usable
        return it
    }

    /// 「复制设备地址」：仅无线端点有意义（USB 序列号拔线即失效，不提供复制）
    func copyItem(_ d: DevEntry, indent: String) -> NSMenuItem {
        let copy = NSMenuItem(title: indent + L.t("dev.copy"),
                              action: #selector(copySerial(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = d.serial
        copy.toolTip = d.serial
        return copy
    }

    /// 「逐台重连」：跨设备的幂等动作，直接放在主菜单一级。
    ///
    /// 以前套了一层「全部设备 ▸」子菜单，但里面只有这一项 ——
    /// 多一次点击却没多任何信息。现在直接平铺，⌘R 绑定在此。
    func addAllDevicesItems(to menu: NSMenu, s: Status) {
        guard !s.devEntries.isEmpty || !s.endpoints.isEmpty else { return }
        let count = max(s.devEntries.count, s.endpoints.count, 1)
        // 文案必须和设备子菜单里的「重连这台设备」区分开：
        //   子菜单里  = 定向重连（只查该设备自己的端点，不扫描）
        //   主菜单这条 = 全量恢复（逐台校验 + 通过 USB 切换 TCP）
        let title = count > 1 ? L.t("dev.all.recover", String(count))
                              : L.t("dev.all.recoverOne")
        let rec = NSMenuItem(title: "  " + title,
                             action: #selector(recoverAllDevices), keyEquivalent: "r")
        rec.target = self
        rec.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                            accessibilityDescription: nil)
        rec.toolTip = L.t("dev.all.recover.tip")
        menu.addItem(rec)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // 每次展开菜单都实时重新采集，保证与 TUI 展示一致
        _ = menu
        let s = loadStatus()
        status = s
        lastLoadedAt = Date()
        updateIcon(s)
        menu.removeAllItems()

        // ---- 守护状态 ----
        let modeText = s.mode == "launchd" ? L.t("daemon.mode.launchd")
            : (s.mode == "manual" ? L.t("daemon.mode.manual") : "")
        var headTitle = s.running ? L.t("daemon.running") : L.t("daemon.stopped")
        if s.running && !modeText.isEmpty {
            headTitle += L.t("daemon.modeFormat", modeText)
        }
        menu.addItem(disabledItem(headTitle))

        if !s.loadError.isEmpty {
            menu.addItem(disabledItem("  ⚠ \(s.loadError)"))
        }

        // ================= 分区一：状态 + 设备 =================
        // 状态区：顶部 1–2 行说清「现在什么情况、需不需要我动手」
        addStatusItems(to: menu, s: s)

        if s.devEntries.isEmpty {
            if s.endpoints.isEmpty {
                menu.addItem(disabledItem(L.t("device.none")))
            } else {
                for ep in s.endpoints {
                    let it = NSMenuItem(title: "  ✓ \(ep)", action: #selector(copyEndpoint(_:)),
                                        keyEquivalent: "")
                    it.target = self
                    it.toolTip = L.t("device.copyTip")
                    menu.addItem(it)
                }
            }
        } else {
            addDeviceItems(to: menu, s: s)
        }

        // ================= 分区二：操作 =================
        // 守护开关、重连、打开设置页、日志、TUI —— 用户日常真正会点的动作
        menu.addItem(.separator())

        // 守护开关：与设备数无关
        menu.addItem(daemonToggleItem(s))
        // 重连统一收敛在「设备」区的「全部设备 → 逐台重连」（带 ⌘R），
        // 这里不再重复，避免同一个动作出现在两处。

        // 插着 USB 且尚未开启 TCP 模式时，提供一键触发（无需等守护的节流周期）
        if s.hasUSB && s.autoTcpip && !s.tcpipListen {
            let usbDevs = s.devEntries.filter { $0.isUsb && $0.usable }
            let tcp = NSMenuItem(title: L.t("menu.enableTcpip"),
                                 action: #selector(enableTcpipNow), keyEquivalent: "t")
            tcp.target = self
            tcp.toolTip = L.t("menu.enableTcpip.tip", s.tcpipPort)
            tcp.representedObject = usbDevs.map { $0.serial }
            pendingTcpipSerials = usbDevs.map { $0.serial }
            menu.addItem(tcp)
        }

        // 设置页入口统一在「设备」区（每台设备自带「无线调试 / 开发者选项」），
        // 这里不再重复。只有「有设备但设备区没用上 devEntries」（旧脚本兜底）时才补，
        // 避免同一个动作在菜单里出现两次。
        if s.devEntries.isEmpty, !s.allDevices.isEmpty {
            let openWireless = NSMenuItem(title: L.t("menu.phoneWireless"),
                                          action: #selector(openPhoneWirelessSettings),
                                          keyEquivalent: "w")
            openWireless.target = self
            openWireless.toolTip = L.t("menu.phone.tip.connected")
            menu.addItem(openWireless)

            let openDev = NSMenuItem(title: L.t("menu.phoneDev"),
                                     action: #selector(openPhoneDevSettings), keyEquivalent: "")
            openDev.target = self
            openDev.toolTip = L.t("menu.phone.tip.dev")
            menu.addItem(openDev)
        }

        let log = NSMenuItem(title: L.t("menu.viewLog"), action: #selector(showLog),
                             keyEquivalent: "l")
        log.target = self
        menu.addItem(log)

        // 一键打开终端 TUI：图形界面里看不完的诊断/修复操作在那里
        let tui = NSMenuItem(title: L.t("menu.openTUI"),
                             action: #selector(openTUI), keyEquivalent: "u")
        tui.target = self
        tui.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        tui.toolTip = L.t("menu.openTUI.tip")
        menu.addItem(tui)

        // ================= 分区三：更多信息 =================
        // 环境 / 链路质量 / adb devices 都收进一个子菜单，主菜单保持精简
        addMoreInfoItems(to: menu, s: s)

        // ================= 底部：设置 / 关于 / 退出 =================
        menu.addItem(.separator())

        let settings = NSMenuItem(title: L.t("menu.settings"), action: nil, keyEquivalent: "")
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        let settingsMenu = NSMenu()
        let languageItem = NSMenuItem(title: L.t("menu.language"), action: nil, keyEquivalent: "")
        languageItem.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        let languageMenu = NSMenu()
        for lang in AppLanguage.allCases {
            let item = NSMenuItem(title: lang.displayName,
                                  action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang
            item.state = (L.current == lang) ? .on : .off
            if lang == .system {
                item.image = NSImage(systemSymbolName: "globe",
                                     accessibilityDescription: nil)
            }
            languageMenu.addItem(item)
        }
        languageItem.submenu = languageMenu
        settingsMenu.addItem(languageItem)
        settings.submenu = settingsMenu
        menu.addItem(settings)

        // 版本号常驻主菜单：不必打开「关于」就能确认当前跑的是哪个版本，
        // 排查问题、确认更新是否生效时都要靠它。
        var menuVersion = L.t("about.version", APP_VERSION)
        if !APP_BUILD.isEmpty { menuVersion += L.t("about.buildSuffix", APP_BUILD) }
        menu.addItem(disabledItem("  " + menuVersion))

        // 关于：版本详情与「检查更新」入口
        let about = NSMenuItem(title: L.t("menu.about"), action: #selector(showAbout),
                               keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: L.t("menu.quit"), action: #selector(quitApp),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// 守护开关项（两个分区都要用，抽出来避免重复代码）
    func daemonToggleItem(_ s: Status) -> NSMenuItem {
        let toggle = NSMenuItem(
            title: s.running ? L.t("menu.stopDaemon") : L.t("menu.startDaemon"),
            action: #selector(toggleDaemon), keyEquivalent: "")
        toggle.target = self
        return toggle
    }

    /// 「更多信息」子菜单：环境状态、链路质量、adb devices。
    /// 这些是「看」而不是「做」的内容，运行时不需要出现在主菜单里。
    /// 主菜单顶部状态区：把「当前能不能用、需不需要动作」压缩成 1–2 行。
    ///
    /// 设计原则：
    ///   - 正常状态**不报喜**（不再有「连接正常」这种同义反复），只陈述客观事实：
    ///     连了几台、走的什么通道
    ///   - 异常状态**必须报**，并且和「怎么办」写在同一行/紧邻行
    ///   - 只在真正影响决策时才多占一行（USB 可拔、TCP 待切换、mDNS 被屏蔽）
    /// 只读的细节（本机 IP、发现方式、累计流量、adb devices）留在「更多信息」里。
    func addStatusItems(to menu: NSMenu, s: Status) {
        // ① 主状态行：设备数量 + 通道构成
        let wifiCount = s.devEntries.filter { $0.isWifi && $0.usable }.count
        let usbCount = s.devEntries.filter { $0.isUsb && $0.usable }.count
        let total = s.devEntries.filter { $0.usable }.count
        var main: String

        if !s.running && total == 0 {
            main = L.t("status.daemonDown")
        } else if total == 0 {
            main = L.t("status.noDevice")
        } else {
            var parts: [String] = []
            if wifiCount > 0 { parts.append(L.t("status.countWifi", String(wifiCount))) }
            if usbCount > 0 { parts.append(L.t("status.countUsb", String(usbCount))) }
            main = L.t("status.connected", parts.joined(separator: L.t("status.sep")))
        }
        // 未授权/离线设备单独计数：这是「看得见但用不了」，必须明确说
        let bad = s.devEntries.count - total
        if bad > 0 { main += "  " + L.t("status.badDevices", String(bad)) }
        if !s.running && total > 0 {
            main += "  " + L.t("status.daemonOffSuffix")
        }
        menu.addItem(disabledItem(main))

        // ② 当前存在的「需要注意但不致命」的情况，每条一行，带可执行提示
        for line in statusNotes(s) {
            if line.action == nil {
                menu.addItem(disabledItem(line.text, tooltip: line.tip))
            } else {
                let it = NSMenuItem(title: line.text, action: #selector(runDiagAction(_:)),
                                    keyEquivalent: "")
                it.target = self
                it.toolTip = line.tip
                menu.addItem(it)
            }
        }

        // ③ 真正的故障：诊断结论（只有 warn / error 才出现，正常时不占位）
        let diag = localizedDiag(s)
        if !diag.title.isEmpty && s.diagLevel != "ok" {
            let icon = s.diagLevel == "warn" ? "!" : "✗"
            menu.addItem(disabledItem("  [\(icon)] \(diag.title)",
                                      tooltip: diag.hint.isEmpty ? nil : diag.hint))
            if !s.diagAction.isEmpty {
                let fix = NSMenuItem(title: L.t("diag.actionPrefix") + actionLabel(s.diagAction),
                                     action: #selector(runDiagAction(_:)), keyEquivalent: "")
                fix.target = self
                fix.toolTip = diag.hint
                menu.addItem(fix)
            }
        }
    }

    /// 状态区里「值得多说一句」的情况。顺序按紧急程度：
    /// 能让你省事的（USB 可拔）→ 正在进行的（TCP 切换中）→ 环境限制（mDNS 被屏蔽）
    func statusNotes(_ s: Status) -> [(text: String, tip: String?, action: String?)] {
        var out: [(text: String, tip: String?, action: String?)] = []

        // USB 只是把无线连接"拉起来"的手段；连上之后插着线反而是累赘，值得提示可拔
        let wifiOK = s.devEntries.contains { $0.isWifi && $0.usable }
        if wifiOK && s.hasUSB {
            out.append((L.t("status.note.usbCanUnplug"), L.t("status.note.usbCanUnplug.tip"),
                        nil))
        }
        // 插着 USB 但还没切 TCP：守护正在处理，告诉用户不用动手
        if s.hasUSB && s.autoTcpip && !s.tcpipListen && !wifiOK {
            out.append((L.t("status.note.tcpPending"), L.t("status.note.tcpPending.tip"),
                        nil))
        }
        // mDNS 状态：正常和异常都展示。
        // 用户需要知道"以后新设备能不能自动被发现"——这条信息在正常时同样有价值
        // （看到「可用」就知道换机/换网后能自动连），异常时才需要额外解释原因。
        // 已有连接时才有意义；完全没设备时诊断行会直接报，这里不重复。
        if s.devEntries.contains(where: { $0.usable }) {
            if s.mdnsOK {
                out.append((L.t("status.note.mdnsOK"), L.t("status.note.mdnsOK.tip"), nil))
            } else if s.mdnsState == "stalled" {
                // adb server 的 mDNS 曾卡死，但已通过重启恢复 —— 与"网络屏蔽"完全不同的成因
                out.append((L.t("status.note.mdnsStalled"),
                            L.t("status.note.mdnsStalled.tip"), nil))
            } else if (Int(s.mdnsEmptyTurns) ?? 0) < 3 {
                // 刚失效不久，可能只是抖动，先不急着下"被屏蔽"的结论
                out.append((L.t("status.note.mdnsFlaky"),
                            L.t("status.note.mdnsFlaky.tip"), nil))
            } else {
                out.append((L.t("status.note.mdnsBlocked"),
                            L.t("status.note.mdnsBlocked.tip"), nil))
            }
        }
        return out
    }

    func addMoreInfoItems(to menu: NSMenu, s: Status) {
        let item = NSMenuItem(title: L.t("more.header"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        let sub = NSMenu()

        // ---- 环境细节（「能不能用」已经在主菜单状态区说过了，这里只放排查用的细节）----
        var env: [String] = []
        var how: [String] = []
        if !s.usbFound.isEmpty { how.append(L.t("env.discovery.usb")) }
        if !s.knownFound.isEmpty { how.append(L.t("env.discovery.known")) }
        if s.mdnsOK { how.append(L.t("env.discovery.mdns")) }
        env.append(L.t("env.discovery")
                   + (how.isEmpty ? L.t("env.discovery.none")
                                  : how.joined(separator: L.t("env.discovery.sep"))))
        if s.autoTcpip && s.tcpipListen {
            env.append(L.t("env.tcp") + L.t("env.tcp.on", s.tcpipPort))
        } else if !s.autoTcpip {
            env.append(L.t("env.tcp") + L.t("env.tcp.autoOff"))
        }
        for line in env { sub.addItem(disabledItem(line)) }
        if !s.macIP.isEmpty { sub.addItem(disabledItem(L.t("env.host") + s.macIP)) }
        // 传输速率：只在有设备时显示
        if !s.allDevices.isEmpty && !s.rateDownHuman.isEmpty {
            sub.addItem(disabledItem(L.t("env.rate.line", s.rateDownHuman, s.rateUpHuman),
                                     tooltip: L.t("env.rate.tip")))
            if !s.rateTotalDown.isEmpty {
                sub.addItem(disabledItem(L.t("env.rate.total", s.rateTotalDown,
                                             s.rateTotalUp)))
            }
        }

        // ---- 链路数据采集时间 + adb devices ----
        // 刷新入口已提到主菜单一级，这里只保留"数据有多新"这一读数。
        sub.addItem(.separator())
        let age = netAgeText(s)
        if !age.isEmpty {
            sub.addItem(disabledItem(L.t("net.age.line", age)))
        }
        let devs = NSMenuItem(title: L.t("menu.adbDevices"), action: #selector(openDevices),
                              keyEquivalent: "d")
        devs.target = self
        sub.addItem(devs)

        item.submenu = sub
        menu.addItem(item)
    }

    /// 切换界面语言：立即重建菜单与关于窗口
    @objc func selectLanguage(_ sender: NSMenuItem) {
        guard let lang = sender.representedObject as? AppLanguage else { return }
        L.setLanguage(lang)
        statusItem.button?.toolTip = L.t("app.tooltip")
        let reopen = aboutWindow?.isVisible == true
        aboutWindow?.close()
        aboutWindow = nil
        if reopen { showAbout() }
    }

    /// 诊断结论本地化。
    /// 脚本只给 `DIAG_CODE` 枚举（见 adb-wifi.sh 的 cmd_diag），文案在本 App 渲染；
    /// 旧脚本没有 DIAG_CODE、或 App 尚未收录新 code 时，回退到脚本下发的中文。
    func localizedDiag(_ s: Status) -> (title: String, hint: String) {
        let titleKey = "diag." + s.diagCode + ".title"
        let hintKey = "diag." + s.diagCode + ".hint"
        guard !s.diagCode.isEmpty, L.has(titleKey), L.has(hintKey) else {
            return (s.diagTitle, s.diagHint)
        }
        // 部分文案需要 tcpip 端口（%@）
        let port = s.tcpipPort.isEmpty ? "5555" : s.tcpipPort
        return (L.t(titleKey, port), L.t(hintKey, port))
    }

    /// 把动作 ID 翻译成用户能看懂的文字
    func actionLabel(_ action: String) -> String {
        switch action {
        case "usb_help": return L.t("action.usb_help")
        case "manual_connect": return L.t("action.manual_connect")
        case "phone_dev_settings": return L.t("action.phone_dev_settings")
        case "phone_wireless": return L.t("action.phone_wireless")
        case "reconnect_now": return L.t("action.reconnect_now")
        case "start_daemon": return L.t("action.start_daemon")
        default: return action
        }
    }

    /// 执行诊断给出的处理动作。
    /// 菜单栏无法承载输入框等复杂交互，涉及输入或引导的动作用弹窗+复制命令实现。
    @objc func runDiagAction(_ sender: NSMenuItem) {
        let action = status.diagAction
        switch action {
        case "start_daemon":
            busy = true
            DispatchQueue.global().async {
                let r = runScript(["start"], timeout: 60)
                DispatchQueue.main.async {
                    self.busy = false
                    self.flash(title: L.t("flash.daemon"), text: r.out.trimmingCharacters(in: .whitespacesAndNewlines))
                    self.refresh()
                }
            }
        case "reconnect_now":
            refresh()
            flash(title: L.t("flash.reconnect"), text: L.t("flash.refreshed"))
        case "usb_help":
            showTextWindow(title: L.t("help.usb.title"), content: L.t("help.usb.body"))
        case "manual_connect":
            let cmd = L.t("help.manual.cmd")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
            showTextWindow(title: L.t("help.manual.title"),
                           content: L.t("help.manual.body", cmd))
        case "phone_dev_settings", "phone_wireless":
            // 跳转策略统一收敛在 adb-wifi.sh 的 open 子命令里（多 ROM 自适应），
            // 菜单栏、TUI、命令行三处行为一致，避免各自实现导致体验不一。
            let page = action == "phone_wireless" ? "wireless" : "dev"
            let r = runScript(["open", page], timeout: 60, env: KV_ENV)
            handleOpenResult(r.out, page: page, withFlash: false)
        default:
            showTextWindow(title: L.t("help.tui.title"), content: L.t("help.tui.body"))
        }
    }

    /// 统一渲染 `open` 子命令的结果。
    /// 脚本以 kv 模式返回 RESULT/PAGE/TITLE/WIFI_TOGGLE（见 adb-wifi.sh 文件头
    /// 「输出协议」），界面文案完全由本地 i18n 渲染，不再解析脚本里的中文。
    func handleOpenResult(_ out: String, page: String, withFlash: Bool, serial: String = "") {
        let kv = parseKV(out)
        let result = kv["RESULT"] ?? "failed"
        let toggle = kv["WIFI_TOGGLE"] ?? "unknown"
        let label = page == "wireless" ? L.t("phone.wireless") : L.t("phone.dev")
        // 多设备时务必在文案里标明是哪台，否则用户无法确认操作落到了哪台手机
        let who = serial.isEmpty ? "" : L.t("dev.onDevice", deviceLabel(serial))

        switch result {
        case "opened":
            if withFlash { flash(title: L.t("flash.opened"), text: L.t("flash.checkPhone")) }
            var body = L.t("phone.open.body", label)
            if !who.isEmpty { body = who + "\n\n" + body }
            if toggle == "off" { body += "\n\n" + L.t("phone.open.toggleOff") }
            else if toggle == "unknown" { body += "\n\n" + L.t("phone.open.toggleUnknown") }
            showTextWindow(title: L.t("phone.openTitle", label), content: body)
        case "partial":
            // 只能带到开发者选项页，无线调试要用户自己点
            if withFlash { flash(title: L.t("flash.opened"), text: L.t("flash.manualWireless")) }
            var body = L.t("phone.open.partial")
            if !who.isEmpty { body = who + "\n\n" + body }
            if toggle == "off" { body += "\n\n" + L.t("phone.open.toggleOff") }
            showTextWindow(title: L.t("phone.open.partialTitle"), content: body)
        case "need_usb", "no_device":
            if withFlash { flash(title: L.t("flash.openFailed"), text: L.t("flash.connectFirst")) }
            showTextWindow(title: L.t("phone.open.failedTitle"),
                           content: who.isEmpty ? L.t("phone.open.noDevice")
                                                : who + "\n\n" + L.t("phone.open.noDevice"))
        default:
            if withFlash { flash(title: L.t("flash.openFailed"), text: L.t("flash.connectFirst")) }
            showTextWindow(title: L.t("phone.open.failedTitle"),
                           content: who.isEmpty ? L.t("phone.open.failedBody")
                                                : who + "\n\n" + L.t("phone.open.failedBody"))
        }
    }

    /// 把序列号渲染成用户看得懂的名字（优先机型）
    func deviceLabel(_ serial: String) -> String {
        if let d = status.devEntries.first(where: { $0.serial == serial }) {
            if !d.model.isEmpty {
                d.isWifi ? "\(d.model) · \(serial)" : d.model + " · " + L.t("dev.tag.usb")
            } else {
                serial
            }
        } else {
            serial
        }
    }

    @objc func copyEndpoint(_ sender: NSMenuItem) {
        let ep = sender.title.replacingOccurrences(of: "  ✓ ", with: "")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ep, forType: .string)
        flash(title: L.t("flash.copied"), text: ep)
    }

    @objc func copySerial(_ sender: NSMenuItem) {
        let serial = (sender.representedObject as? String) ?? ""
        guard !serial.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(serial, forType: .string)
        flash(title: L.t("flash.copied"), text: serial)
    }

    @objc func toggleDaemon() {
        busy = true
        let wasRunning = status.running
        DispatchQueue.global().async {
            let r = runScript([wasRunning ? "stop" : "start"])
            DispatchQueue.main.async {
                self.busy = false
                self.flash(title: wasRunning ? L.t("flash.stopped") : L.t("flash.started"), text: r.out.trimmingCharacters(in: .whitespacesAndNewlines))
                self.refresh()
            }
        }
    }

    /// 恢复无线连接（「全部设备 → 逐台重连」，⌘R）。
    ///
    /// 统一走 `recover --all`：无论几台设备都按同一套流程——
    /// 逐台校验已有端点 + 通过各自的 USB 通道尝试建立 TCP，
    /// **不做整段网段扫描**（那会在多设备时把网络扫一遍，代价高且收益低）。
    /// 以前单设备走 `recover`（含网段扫描）、多设备走 `--all`，行为不一致，
    /// 现在合并为一条路径，结果也统一用列表呈现。
    @objc func recoverConnection() {
        guard !busy else { return }
        busy = true
        DispatchQueue.global().async {
            let r = runScript(["recover", "--all"], timeout: 180, env: KV_ENV)
            let kv = parseKV(r.out)
            DispatchQueue.main.async {
                self.busy = false
                self.handleRecoverAllResult(kv)
                self.refresh()
            }
        }
    }

    /// 单台设备重连：只针对这台，只在它的记忆端点 / 自己的 USB 通道上找，
    /// 不做整段网段扫描（多设备时那样会拖慢网络）。
    @objc func reconnectDevice(_ sender: NSMenuItem) {
        guard let serial = sender.representedObject as? String, !serial.isEmpty else { return }
        guard !busy else { return }
        busy = true
        flash(title: L.t("dev.reconnect.flash"), text: deviceLabel(serial))
        DispatchQueue.global().async {
            let r = runScript(["recover", "--serial", serial], timeout: 90, env: KV_ENV)
            let kv = parseKV(r.out)
            DispatchQueue.main.async {
                self.busy = false
                let res = kv["RESULT"] ?? "failed"
                let ep = kv["ENDPOINT"] ?? serial
                if res == "already" || res == "recovered" {
                    self.flash(title: L.t("flash.recovered"), text: "\(self.deviceLabel(serial)) → \(ep)")
                } else {
                    self.showTextWindow(title: L.t("recover.failed.title"),
                                        content: L.t("dev.reconnect.failed.body",
                                                     self.deviceLabel(serial)))
                }
                self.refresh()
            }
        }
    }

    /// 手动刷新链路质量：绕过 60 秒缓存，立即同步采集一次。
    /// 链路数据本来由守护异步刷新，但用户刚换网络/挪动手机时想立刻看新数据，
    /// 不该被缓存卡住。
    @objc func refreshLinkQuality(_ sender: NSMenuItem) {
        guard !busy else { return }
        let serial = (sender.representedObject as? String) ?? ""
        busy = true
        flash(title: L.t("net.refresh.flash"),
              text: serial.isEmpty ? L.t("net.refresh.flash.tip")
                                   : deviceLabel(serial))
        // 指定了设备就只刷这一台，其余设备的缓存数据原样保留
        var args = ["netinfo-refresh"]
        if !serial.isEmpty { args.append(serial) }
        DispatchQueue.global().async {
            let r = runScript(args, timeout: 60, env: KV_ENV)
            DispatchQueue.main.async {
                self.busy = false
                let ok = parseKV(r.out)["REFRESHED"] == "1"
                self.flash(title: ok ? L.t("net.refresh.done")
                                     : L.t("net.refresh.failed"),
                           text: ok ? (serial.isEmpty ? L.t("net.refresh.done.tip")
                                                      : self.deviceLabel(serial))
                                    : L.t("net.refresh.failed.tip"))
                self.refresh()
            }
        }
    }

    /// 数据采集距今多久（用于让用户判断看到的链路数据是否新鲜）
    func netAgeText(_ s: Status) -> String {
        guard let at = Double(s.netAt), at > 0 else { return "" }
        let age = max(0, Int(Date().timeIntervalSince1970 - at))
        if age < 60 { return L.t("net.age.sec", String(age)) }
        return L.t("net.age.min", String(age / 60))
    }

    /// 「全部设备 → 逐台重连」：带明确意图的批量恢复（用户点了才知道会逐台尝试）
    @objc func recoverAllDevices() {
        guard !busy else { return }
        busy = true
        DispatchQueue.global().async {
            let r = runScript(["recover", "--all"], timeout: 180, env: KV_ENV)
            let kv = parseKV(r.out)
            DispatchQueue.main.async {
                self.busy = false
                self.handleRecoverAllResult(kv)
                self.refresh()
            }
        }
    }

    /// 批量恢复结果的渲染
    func handleRecoverAllResult(_ kv: [String: String]) {
        let done = Int(kv["DONE_COUNT"] ?? "0") ?? 0
        guard done > 0 else {
            showTextWindow(title: L.t("recover.failed.title"), content: L.t("recover.failed.body"))
            return
        }
        var lines: [String] = []
        for i in 1...done {
            let serial = kv["DEV_\(i)_SERIAL"] ?? ""
            let r = kv["DEV_\(i)_RESULT"] ?? "failed"
            let ep = kv["DEV_\(i)_ENDPOINT"] ?? ""
            let via = kv["DEV_\(i)_VIA"] ?? ""
            let mark = (r == "already" || r == "recovered") ? "✓" : "✗"
            var line = "\(mark) \(deviceLabel(serial))  "
            switch r {
            case "already":   line += L.t("dev.all.recover.already")
            case "recovered": line += L.t("dev.all.recover.recovered", ep, via)
            default:          line += L.t("dev.all.recover.failed")
            }
            lines.append(line)
        }
        let okCount = kv["OK_COUNT"] ?? "0"
        let failCount = kv["FAIL_COUNT"] ?? "0"
        let allOK = (kv["OK"] ?? "0") == "1"
        flash(title: allOK ? L.t("flash.recovered") : L.t("recover.failed.title"),
              text: L.t("dev.all.recover.flash", okCount, failCount))
        var body = L.t("dev.all.recover.body", okCount, failCount) + "\n\n"
        body += lines.joined(separator: "\n")
        showTextWindow(title: L.t("dev.all.recover.title"), content: body)
    }

    /// 一键开启 TCP 模式：通过 USB 对手机执行 adb tcpip，然后立即无线连接。
    /// 这是「插上 USB 就自动搞定」的手动触发版，主要给想立刻生效的场景用，
    /// 不必等守护那边的节流周期。真正的自动化由守护的 ensure_tcpip 完成。
    /// 多台 USB 设备时逐台处理（representedObject 里带着待处理的序列号列表）。
    @objc func enableTcpipNow() {
        var serials = pendingTcpipSerials
        if serials.isEmpty {
            serials = status.devEntries.filter { $0.isUsb && $0.usable }.map { $0.serial }
        }
        if serials.isEmpty, let only = status.allDevices.first(where: { !$0.0.contains(":") })?.0 {
            serials = [only]
        }
        guard !serials.isEmpty else {
            showTextWindow(title: L.t("usb.none.title"),
                           content: L.t("usb.none.body"))
            return
        }
        guard !busy else { return }
        busy = true
        let port = status.tcpipPort.isEmpty ? "5555" : status.tcpipPort
        DispatchQueue.global().async {
            var results: [(serial: String, ok: Bool, message: String)] = []
            for serial in serials {
                results.append(self.enableTcpipOne(serial, port: port))
            }
            DispatchQueue.main.async {
                self.busy = false
                let okCount = results.filter { $0.ok }.count
                let body = results
                    .map { "\($0.ok ? "✓" : "✗") \($0.serial)\n    \($0.message)" }
                    .joined(separator: "\n\n")
                self.flash(title: okCount == results.count ? L.t("flash.tcpOn")
                                                           : L.t("flash.tcpFail"),
                           text: L.t("dev.usb.tcpip.flash", String(okCount), String(results.count)))
                self.showTextWindow(title: L.t("menu.enableTcpip"), content: body)
                self.refresh()
            }
        }
    }

    /// 对单台 USB 设备执行 tcpip + 连接，返回结果（不碰 UI，供主线程之外调用）
    func enableTcpipOne(_ serial: String, port: String) -> (serial: String, ok: Bool, message: String) {
        let tcpip = shellCode("/usr/bin/env", ["adb", "-s", serial, "tcpip", port])
        var msg = tcpip.out.trimmingCharacters(in: .whitespacesAndNewlines)
        var ok = tcpip.code == 0
        if ok {
            var ip = shell("/usr/bin/env", ["adb", "-s", serial, "shell",
                "ip -4 addr show wlan0 | grep -oE 'inet [0-9.]+' | head -1 | cut -d' ' -f2"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if ip.isEmpty {
                ip = shell("/usr/bin/env", ["adb", "-s", serial, "shell",
                    "ip -4 route get 1.1.1.1 | grep -oE 'src [0-9.]+' | cut -d' ' -f2"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            sleep(3)
            if !ip.isEmpty {
                let c = shell("/usr/bin/env", ["adb", "connect", "\(ip):\(port)"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                msg = c
                ok = c.contains("connected")
            } else {
                msg = L.t("err.noWifiIP")
                ok = false
            }
        }
        return (serial, ok, msg)
    }

    /// 一键在手机上打开「无线调试」页面并定位到开关。
    /// 具体跳转策略（多 ROM 自适应）由 adb-wifi.sh 的 open 子命令实现，
    /// 与 TUI、命令行共用同一套逻辑。
    /// 多设备时必须带上具体设备，否则脚本只能"自动挑一台"，结果不可预期。
    @objc func openPhoneWirelessSettings() {
        jumpToPhoneSettings(page: "wireless", serial: nil)
    }

    @objc func openPhoneDevSettings() {
        jumpToPhoneSettings(page: "dev", serial: nil)
    }

    @objc func openWirelessForDevice(_ sender: NSMenuItem) {
        jumpToPhoneSettings(page: "wireless", serial: sender.representedObject as? String)
    }

    @objc func openDevForDevice(_ sender: NSMenuItem) {
        jumpToPhoneSettings(page: "dev", serial: sender.representedObject as? String)
    }

    /// 对所有在线设备逐台打开设置页（逐台串行，避免同时拉起多份 adb）

    func jumpToPhoneSettings(page: String, serial: String?) {
        guard !busy else { return }
        busy = true
        var args = ["open", page]
        if let serial, !serial.isEmpty { args += ["--serial", serial] }
        let target = serial ?? ""
        DispatchQueue.global().async {
            let r = runScript(args, timeout: 60, env: KV_ENV)
            DispatchQueue.main.async {
                self.busy = false
                self.handleOpenResult(r.out, page: page, withFlash: true, serial: target)
                self.refresh()
            }
        }
    }

    @discardableResult
    func shell(_ path: String, _ args: [String]) -> String {
        shellCode(path, args).out
    }

    /// 与 shell 相同，但同时返回退出码（用于不依赖英文输出文案的判定）
    func shellCode(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:"
            + NSHomeDirectory() + "/Library/Android/sdk/platform-tools"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "") }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: d, encoding: .utf8) ?? "")
    }

    @objc func openDevices() {
        let out = shell("/usr/bin/env", ["adb", "devices", "-l"])
        showTextWindow(title: "adb devices -l", content: out)
    }

    // MARK: - 打开终端 TUI

    /// 一键在终端里打开 TUI（交互式诊断/修复界面）。
    ///
    /// 做法：写一个 `.command` 文件再交给系统打开。
    /// 为什么不直接写 AppleScript / osascript：
    ///   1. 控制 Terminal/iTerm 需要「自动化」TCC 授权，正式签名版还要额外 entitlement；
    ///   2. 各终端（iTerm2）的 AppleScript 方言不一致，容易在别人机器上失败。
    /// `open` 一个 .command 会交给用户当前的默认终端执行，零权限、跨终端都可用。
    @objc func openTUI() {
        let binDir = (SCRIPT as NSString).deletingLastPathComponent
        let rootDir = (binDir as NSString).deletingLastPathComponent
        let entry = rootDir + "/adbwifi"
        guard FileManager.default.fileExists(atPath: entry) else {
            showTextWindow(title: L.t("tui.missing.title"),
                           content: L.t("tui.missing.body", entry))
            return
        }

        let dir = NSHomeDirectory() + "/Library/Application Support/adb-wifi-manager"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/open-tui.command"
        let body = """
        #!/bin/bash
        # 由菜单栏「打开终端 TUI」自动生成，每次覆盖
        cd \(shellQuote(rootDir)) && ./adbwifi
        """
        do {
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        } catch {
            showTextWindow(title: L.t("tui.missing.title"),
                           content: L.t("tui.missing.body", path))
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// 单引号包裹（路径含空格时也安全）
    func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func logPath() -> String {
        NSHomeDirectory() + "/Library/Application Support/adb-wifi-manager/logs/adb-wifi.log"
    }

    @objc func showLog() {
        let p = logPath()
        let content = (try? String(contentsOfFile: p, encoding: .utf8)) ?? L.t("log.empty")
        showTextWindow(title: L.t("log.title"), content: String(content.suffix(50_000)))
    }

    func showTextWindow(title: String, content: String) {
        if let w = logWindow {
            w.title = title
            logTextView?.string = content
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        w.title = title
        w.center()
        w.isReleasedWhenClosed = false

        let scroll = NSScrollView(frame: w.contentLayoutRect)
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        let tv = NSTextView(frame: w.contentLayoutRect)
        tv.isEditable = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.string = content
        tv.autoresizingMask = [.width, .height]
        scroll.documentView = tv
        w.contentView?.addSubview(scroll)

        logWindow = w
        logTextView = tv
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 轻量反馈：在菜单栏图标处短暂显示结果文字，无需系统通知权限
    func flash(title: String, text: String) {
        guard let button = statusItem.button else { return }
        let prevImage = button.image
        let prevTitle = button.title
        let short = text.count > 28 ? String(text.prefix(28)) + "…" : text
        button.image = nil
        button.title = " \(title): \(short) "
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self = self else { return }
            button.image = prevImage
            button.title = prevTitle
            // 强制按最新状态重新选图（状态可能已在提示期间变化）
            self.currentIconState = ""
            self.refresh()
        }
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - 关于 / 版本更新

    var aboutWindow: NSWindow?
    var checkUpdateButton: NSButton?
    var checkAlphaButton: NSButton?

    /// 已检查到、可安装的更新
    var pendingStable: (tag: String, url: String, notes: String)?
    var pendingAlpha: (tag: String, url: String, notes: String)?
    var installingUpdate = false
    var lastAutoCheck = Date.distantPast

    /// Alpha 入口自身显示检查状态（与正式版按钮一致，不占用状态行）
    enum AlphaState {
        case idle, checking, updateAvailable, installing, installFailed, upToDate, notFound, failed
    }
    var alphaState: AlphaState = .idle
    var latestAlphaTag = ""
    var alphaError = ""

    /// 正式版按钮状态机：检查结果直接体现在按钮文案上，不再弹窗
    enum StableState {
        case idle, checking, updateAvailable, upToDate, installFailed, failed, installing
    }
    var stableState: StableState = .idle
    var stableError = ""

    /// 主更新按钮当前代表哪个通道（Alpha 检查出更新后会接管主按钮）
    var primaryChannel: UpdateChannel = .stable

    /// 更新通道：正式版走 releases/latest，Alpha 只取预发布
    enum UpdateChannel {
        case stable, alpha
    }

    @objc func showAbout() {
        if aboutWindow == nil { aboutWindow = makeAboutWindow() }
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 打开关于即自动检查正式版（60 秒内不重复请求）；结果直接显示在按钮上
        if stableState != .checking && stableState != .installing
            && Date().timeIntervalSince(lastAutoCheck) > 60 {
            runUpdateCheck(.stable)
        }
    }

    func makeAboutWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        w.title = L.t("about.title")
        w.isReleasedWhenClosed = false
        w.center()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        w.contentView?.addSubview(stack)

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
            ?? NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
        ])
        stack.addArrangedSubview(icon)

        let name = NSTextField(labelWithString: "ADB WiFi")
        name.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        stack.addArrangedSubview(name)

        var verText = L.t("about.version", APP_VERSION)
        if !APP_BUILD.isEmpty { verText += L.t("about.buildSuffix", APP_BUILD) }
        let ver = NSTextField(labelWithString: verText)
        ver.font = NSFont.systemFont(ofSize: 11)
        ver.textColor = .secondaryLabelColor
        stack.addArrangedSubview(ver)

        let desc = NSTextField(wrappingLabelWithString: L.t("about.desc"))
        desc.alignment = .center
        desc.font = NSFont.systemFont(ofSize: 11)
        desc.textColor = .secondaryLabelColor
        desc.widthAnchor.constraint(equalToConstant: 360).isActive = true
        stack.addArrangedSubview(desc)

        stack.setCustomSpacing(16, after: desc)

        // 正式版是主入口：大号默认按钮 + 加粗，视觉上明显突出
        let check = NSButton(title: L.t("about.check"), target: self, action: #selector(checkStableUpdates))
        check.bezelStyle = .rounded
        check.controlSize = .large
        check.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        check.keyEquivalent = "\r"
        check.toolTip = L.t("about.checkTip")
        check.translatesAutoresizingMaskIntoConstraints = false
        check.widthAnchor.constraint(equalToConstant: 260).isActive = true
        checkUpdateButton = check
        stack.addArrangedSubview(check)
        stack.setCustomSpacing(12, after: check)

        // Alpha 入口自身完成「状态 + 动作」，不再额外占一行状态文字
        let alpha = NSButton(title: L.t("about.alpha.idle"), target: self, action: #selector(checkAlphaUpdates))
        alpha.bezelStyle = .inline
        alpha.isBordered = false
        alpha.toolTip = L.t("about.alpha.tip")
        checkAlphaButton = alpha
        refreshAlphaLink()
        stack.addArrangedSubview(alpha)

        stack.setCustomSpacing(18, after: alpha)

        let links = NSStackView()
        links.orientation = .horizontal
        links.spacing = 16
        let home = NSButton(title: L.t("about.link.home"), target: self, action: #selector(openRepo))
        let issues = NSButton(title: L.t("about.link.issues"), target: self, action: #selector(openIssues))
        let releases = NSButton(title: L.t("about.link.releases"), target: self, action: #selector(openReleases))
        for b in [home, issues, releases] {
            b.bezelStyle = .inline
            b.isBordered = false
            b.contentTintColor = .linkColor
            b.font = NSFont.systemFont(ofSize: 11)
            links.addArrangedSubview(b)
        }
        stack.addArrangedSubview(links)

        stack.setCustomSpacing(18, after: links)

        let close = NSButton(title: L.t("about.close"), target: self, action: #selector(closeAbout))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        stack.addArrangedSubview(close)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: w.contentView!.centerXAnchor),
            stack.topAnchor.constraint(equalTo: w.contentView!.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: w.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: w.contentView!.trailingAnchor, constant: -24),
        ])
        return w
    }

    @objc func closeAbout() {
        aboutWindow?.close()
    }

    @objc func openRepo() { openURL(REPO_URL) }
    @objc func openIssues() { openURL(REPO_URL + "/issues") }
    @objc func openReleases() { openURL(RELEASES_URL) }

    func openURL(_ s: String) {
        guard let u = URL(string: s) else { return }
        NSWorkspace.shared.open(u)
    }

    /// 拆分版本号：v0.0.2-alpha.2 →（[0,0,2], "alpha.2"）
    func splitVersion(_ s: String) -> (nums: [Int], pre: String) {
        var v = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if v.hasPrefix("v") { v.removeFirst() }
        let parts = v.split(separator: "-", maxSplits: 1).map(String.init)
        let nums = parts[0].split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        return (nums, parts.count > 1 ? parts[1] : "")
    }

    /// 比较预发布后缀：alpha.2 < alpha.10（数字按数值比，而非字典序）
    func comparePrerelease(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map(String.init)
        let y = b.split(separator: ".").map(String.init)
        for i in 0..<max(x.count, y.count) {
            if i >= x.count { return -1 }
            if i >= y.count { return 1 }
            let p = x[i], q = y[i]
            if let n = Int(p), let m = Int(q) {
                if n != m { return n < m ? -1 : 1 }
            } else if p != q {
                return p < q ? -1 : 1
            }
        }
        return 0
    }

    func isNewer(_ remote: String, than local: String) -> Bool {
        let a = splitVersion(remote), b = splitVersion(local)
        for i in 0..<max(a.nums.count, b.nums.count) {
            let x = i < a.nums.count ? a.nums[i] : 0
            let y = i < b.nums.count ? b.nums[i] : 0
            if x != y { return x > y }
        }
        // 主版本相同：正式版 > 预发布版；同为预发布再比后缀
        if a.pre == b.pre { return false }
        if a.pre.isEmpty { return true }
        if b.pre.isEmpty { return false }
        return comparePrerelease(a.pre, b.pre) > 0
    }

    /// 主更新按钮：根据当前展示的通道执行检查 / 安装
    @objc func checkStableUpdates() {
        guard stableState != .checking, stableState != .installing,
              alphaState != .installing else { return }

        // 主按钮当前展示的是 Alpha 更新：点击安装 / 重试 Alpha
        if primaryChannel == .alpha,
           alphaState == .updateAvailable || alphaState == .installFailed,
           let p = pendingAlpha {
            installUpdate(p, channel: .alpha)
            return
        }

        if let p = pendingStable, isNewer(p.tag, than: APP_VERSION) {
            installUpdate(p, channel: .stable)
            return
        }
        runUpdateCheck(.stable, autoInstall: true)
    }

    /// Alpha 入口只负责检查；结果展示到主按钮，安装由主按钮执行
    @objc func checkAlphaUpdates() {
        guard alphaState != .checking, alphaState != .installing,
              stableState != .checking, stableState != .installing else { return }
        runUpdateCheck(.alpha)
    }

    func runUpdateCheck(_ channel: UpdateChannel, autoInstall: Bool = false) {
        if channel == .stable {
            primaryChannel = .stable
            stableState = .checking
            stableError = ""
            setStableButtonTitle()
            lastAutoCheck = Date()
        } else {
            alphaState = .checking
            refreshAlphaLink()
        }
        checkAlphaButton?.isEnabled = false

        fetchLatestVersion(channel) { result in
            DispatchQueue.main.async {
                self.refreshAlphaLink()

                switch result {
                case .success(let info) where !info.tag.isEmpty:
                    if channel == .stable {
                        if self.isNewer(info.tag, than: APP_VERSION) {
                            self.pendingStable = info
                            self.stableState = .updateAvailable
                            self.stableError = ""
                            self.primaryChannel = .stable
                            if autoInstall { self.installUpdate(info) }
                        } else {
                            self.pendingStable = nil
                            self.stableState = .upToDate
                            self.stableError = ""
                            self.primaryChannel = .stable
                        }
                    } else {
                        self.latestAlphaTag = info.tag
                        self.alphaError = ""
                        if self.isNewer(info.tag, than: APP_VERSION) {
                            self.pendingAlpha = info
                            self.alphaState = .updateAvailable
                            // Alpha 检查出更新后接管主按钮
                            self.primaryChannel = .alpha
                        } else {
                            self.pendingAlpha = nil
                            self.alphaState = .upToDate
                            if self.primaryChannel == .alpha { self.primaryChannel = .stable }
                        }
                        self.refreshAlphaLink()
                    }

                case .success:
                    self.pendingStable = nil
                    self.pendingAlpha = nil
                    if channel == .stable {
                        self.stableState = .failed
                        self.stableError = L.t("about.status.noVersion")
                    } else {
                        self.alphaState = .failed
                        self.alphaError = L.t("about.alpha.errNoVersion")
                        self.refreshAlphaLink()
                    }

                case .failure(let err):
                    if channel == .stable {
                        self.pendingStable = nil
                        self.stableState = .failed
                        self.stableError = (err as NSError).code == 404
                            ? L.t("about.status.noStable")
                            : L.t("about.status.failed", err.localizedDescription)
                    } else {
                        self.pendingAlpha = nil
                        if (err as NSError).code == 404 {
                            self.alphaState = .notFound
                            self.alphaError = ""
                        } else {
                            self.alphaState = .failed
                            self.alphaError = err.localizedDescription
                        }
                        if self.primaryChannel == .alpha { self.primaryChannel = .stable }
                        self.refreshAlphaLink()
                    }
                }

                self.setStableButtonTitle()
            }
        }
    }

    /// 主更新按钮：Alpha 检查出更新时接管按钮，否则显示正式版状态
    func setStableButtonTitle() {
        let btn = checkUpdateButton
        var tip = L.t("about.checkTip")

        if primaryChannel == .alpha {
            switch alphaState {
            case .installing:
                btn?.title = L.t("about.installing")
                btn?.isEnabled = false
                tip = pendingAlpha.map { L.t("about.tip.installing", $0.tag) } ?? L.t("about.installing")
                btn?.toolTip = tip
                return
            case .installFailed:
                btn?.title = L.t("about.alpha.installFailed")
                btn?.isEnabled = true
                tip = alphaError.isEmpty ? L.t("about.alpha.installFailed") : alphaError
                btn?.toolTip = tip
                return
            case .updateAvailable:
                btn?.title = pendingAlpha.map { L.t("about.alpha.download", $0.tag) } ?? L.t("about.check")
                btn?.isEnabled = true
                if let p = pendingAlpha {
                    tip = L.t("about.tip.updateAvailable", APP_VERSION, p.tag)
                }
                btn?.toolTip = tip
                return
            default:
                break
            }
        }

        switch stableState {
        case .checking:
            btn?.title = L.t("about.checking")
            btn?.isEnabled = false
            tip = L.t("about.status.checking")
        case .installing:
            btn?.title = L.t("about.installing")
            btn?.isEnabled = false
            tip = pendingStable.map { L.t("about.tip.installing", $0.tag) } ?? L.t("about.installing")
        case .installFailed:
            btn?.title = L.t("about.installFailed")
            btn?.isEnabled = true
            tip = stableError.isEmpty ? L.t("about.installFailed") : stableError
        case .failed:
            btn?.title = L.t("about.checkFailed")
            btn?.isEnabled = true
            tip = stableError.isEmpty ? L.t("about.checkFailed") : stableError
        case .upToDate:
            btn?.title = L.t("about.upToDate")
            btn?.isEnabled = true
            tip = L.t("about.tip.upToDate", APP_VERSION)
        case .updateAvailable:
            btn?.title = pendingStable.map { L.t("about.downloadInstall", $0.tag) } ?? L.t("about.check")
            btn?.isEnabled = true
            if let p = pendingStable {
                tip = L.t("about.tip.updateAvailable", APP_VERSION, p.tag)
            }
        case .idle:
            btn?.title = L.t("about.check")
            btn?.isEnabled = true
        }
        btn?.toolTip = tip
    }

    /// Alpha 入口：文字本身就是检查状态（蓝色下划线超链接）
    func refreshAlphaLink() {
        let text: String
        var enabled = true
        var tip = L.t("about.alpha.tip")
        switch alphaState {
        case .idle:
            text = L.t("about.alpha.idle")
        case .checking:
            text = L.t("about.alpha.checking")
            enabled = false
            tip = L.t("about.alpha.checking")
        case .installing:
            text = pendingAlpha.map { L.t("about.alpha.installingTag", $0.tag) }
                ?? L.t("about.alpha.installing")
            enabled = false
            tip = text
        case .updateAvailable:
            text = pendingAlpha.map { L.t("about.alpha.available", $0.tag) } ?? L.t("about.alpha.idle")
            tip = pendingAlpha.map { L.t("about.alpha.tip.available", $0.tag) } ?? L.t("about.alpha.tip")
        case .installFailed:
            // 安装失败必须可见（不只藏在 tooltip 里），点击直接重试安装
            text = L.t("about.alpha.installFailed")
            tip = alphaError.isEmpty ? L.t("about.alpha.installFailed") : alphaError
        case .upToDate:
            text = L.t("about.alpha.upToDate")
            tip = latestAlphaTag.isEmpty ? L.t("about.alpha.upToDate")
                                         : L.t("about.alpha.tip.upToDate", latestAlphaTag)
        case .notFound:
            text = L.t("about.alpha.notFound")
            tip = L.t("about.alpha.tip.notFound")
        case .failed:
            text = L.t("about.alpha.failed")
            tip = alphaError.isEmpty ? L.t("about.alpha.failed") : alphaError
        }
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        checkAlphaButton?.attributedTitle = attr
        checkAlphaButton?.isEnabled = enabled
        checkAlphaButton?.toolTip = tip
    }

    /// 下载新版本 App → 校验签名/公证 → 退出当前进程后替换并启动新版本。
    /// 正式版与 Alpha 走**同一条自动安装链路**，只是状态展示位置不同：
    /// 正式版体现在「检查正式版更新」按钮上，Alpha 体现在其文字链上。
    /// 只替换菜单栏 App；守护脚本仍由 install.sh / get.sh 维护。
    func installUpdate(_ info: (tag: String, url: String, notes: String),
                       channel: UpdateChannel = .stable) {
        guard !installingUpdate, isNewer(info.tag, than: APP_VERSION) else { return }
        let version = info.tag.hasPrefix("v") ? String(info.tag.dropFirst()) : info.tag
        let asset = "AdbWifiBar-\(version)-universal.zip"
        let zipURL = "https://github.com/\(REPO_SLUG)/releases/download/v\(version)/\(asset)"
        let destApp = NSHomeDirectory() + "/Applications/AdbWifiBar.app"
        let tmp = NSTemporaryDirectory() + "AdbWifiBarUpdate-\(UUID().uuidString)"

        installingUpdate = true
        primaryChannel = channel
        updateLog("开始更新 channel=\(channel == .stable ? "stable" : "alpha") tag=\(info.tag) url=\(zipURL)")
        checkAlphaButton?.isEnabled = false
        checkUpdateButton?.isEnabled = false
        if channel == .stable {
            stableState = .installing
        } else {
            alphaState = .installing
        }
        setStableButtonTitle()
        refreshAlphaLink()

        DispatchQueue.global(qos: .userInitiated).async {
            let zip = tmp + "/update.zip"
            let unpack = tmp + "/unpack"
            var failure: String?

            // 临时目录必须显式创建：curl -o 不会自动建父目录，否则报
            // “Failure writing output to destination”并立即失败
            do {
                try FileManager.default.createDirectory(atPath: tmp,
                                                        withIntermediateDirectories: true)
            } catch {
                failure = L.t("update.err.tempDir", error.localizedDescription)
            }

            if failure == nil {
                let dl = self.shellCode("/usr/bin/curl", [
                    "-fL", "--retry", "3", "--retry-delay", "2",
                    "--max-time", "300", "-o", zip, zipURL])
                let attrs = try? FileManager.default.attributesOfItem(atPath: zip)
                let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
                if size == 0 {
                    // 把 curl 的原因（HTTP 状态/网络错误）带出来，不只是“下载失败”
                    let detail = dl.out.trimmingCharacters(in: .whitespacesAndNewlines)
                    failure = detail.isEmpty
                        ? L.t("update.err.download")
                        : L.t("update.err.downloadDetail", String(detail.suffix(300)))
                }
            }

            if failure == nil {
                let un = self.shellCode("/usr/bin/ditto", ["-x", "-k", zip, unpack])
                if un.code != 0 {
                    let detail = un.out.trimmingCharacters(in: .whitespacesAndNewlines)
                    failure = detail.isEmpty ? L.t("update.err.package")
                                            : L.t("update.err.packageDetail", String(detail.suffix(300)))
                }
            }
            let newApp = unpack + "/AdbWifiBar.app"
            if failure == nil && !FileManager.default.fileExists(atPath: newApp) {
                failure = L.t("update.err.package")
            }
            if failure == nil { updateLog("校验通过：\(newApp)") }

            // 校验 Apple 签名与公证票据，避免安装被篡改的包。
            // 注意：spctl 成功时**不输出任何内容**（仅 exit 0），所以必须用退出码判定，
            // 不能用输出里是否包含 "accepted"；-vv 只为失败时能拿到原因。
            if failure == nil {
                let verify = self.shellCode("/usr/sbin/spctl",
                                            ["-a", "-t", "exec", "-vv", newApp])
                if verify.code != 0 {
                    let detail = verify.out.trimmingCharacters(in: .whitespacesAndNewlines)
                    failure = L.t("update.err.signature",
                                  detail.isEmpty ? L.t("update.err.unknown") : detail)
                }
            }

            if let f = failure {
                updateLog("更新失败：\(f)")
                DispatchQueue.main.async {
                    self.installingUpdate = false
                    self.checkAlphaButton?.isEnabled = true
                    self.checkUpdateButton?.isEnabled = true
                    if channel == .stable {
                        self.stableState = .installFailed
                        self.stableError = f
                    } else {
                        self.alphaState = .installFailed
                        self.alphaError = f
                    }
                    self.primaryChannel = channel
                    self.setStableButtonTitle()
                    self.refreshAlphaLink()
                }
                return
            }

            // 等当前进程退出后再替换 App，避免“自己替换自己”导致异常
            let script = tmp + "/apply-update.sh"
            let body = """
            #!/bin/bash
            set -u
            APP="$1"; NEW="$2"; PID="$3"; TMPDIR_UPD="$4"
            # 最多等 15 秒，避免进程未退出时脚本永久挂起
            for _ in $(seq 1 150); do
              kill -0 "$PID" 2>/dev/null || break
              sleep 0.1
            done
            mkdir -p "$(dirname "$APP")"
            # 结束任何仍在运行的旧副本（同 bundle id 会让 LaunchServices 拒绝启动新版本）
            pkill -f "$APP/Contents/MacOS/AdbWifiBar" 2>/dev/null || true
            sleep 0.5
            rm -rf "$APP"
            /usr/bin/ditto "$NEW" "$APP"
            /usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
            # 清掉单实例锁：正常退出会自动释放，这里只防御异常退出的残留
            rm -f "$HOME/Library/Application Support/adb-wifi-manager/menubar.lock"
            # 让 LaunchServices 重新读取 bundle（否则可能仍指向刚被删除的旧路径）
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
              -f "$APP" >/dev/null 2>&1 || true
            /usr/bin/open "$APP"
            rm -rf "$TMPDIR_UPD"
            """
            do {
                try body.write(toFile: script, atomically: true, encoding: .utf8)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = [script, destApp, newApp,
                               "\(ProcessInfo.processInfo.processIdentifier)", tmp]
                try p.run()
                updateLog("已启动替换脚本，等当前进程退出后安装 \(info.tag)")
            } catch {
                updateLog("无法启动替换脚本：\(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.installingUpdate = false
                    self.checkAlphaButton?.isEnabled = true
                    self.checkUpdateButton?.isEnabled = true
                    if channel == .stable {
                        self.stableState = .installFailed
                        self.stableError = error.localizedDescription
                    } else {
                        self.alphaState = .installFailed
                        self.alphaError = error.localizedDescription
                    }
                    self.primaryChannel = channel
                    self.setStableButtonTitle()
                    self.refreshAlphaLink()
                }
                return
            }

            DispatchQueue.main.async {
                self.primaryChannel = channel
                if channel == .stable {
                    self.stableState = .installing
                } else {
                    self.alphaState = .installing
                }
                self.setStableButtonTitle()
                self.refreshAlphaLink()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// 取最新版本。
    /// 正式版：releases/latest（GitHub 已排除 prerelease），无 Release 时回退到正式 tag；
    /// Alpha：/releases 中第一个 prerelease，无 prerelease 时回退到带后缀的 tag。
    func fetchLatestVersion(_ channel: UpdateChannel,
                            completion: @escaping (Result<(tag: String, url: String, notes: String), Error>) -> Void) {
        switch channel {
        case .stable:
            fetchJSON("https://api.github.com/repos/\(REPO_SLUG)/releases/latest") { res in
                switch res {
                case .success(let obj):
                    let d = obj as? [String: Any] ?? [:]
                    completion(.success((
                        tag: d["tag_name"] as? String ?? "",
                        url: d["html_url"] as? String ?? RELEASES_URL,
                        notes: d["body"] as? String ?? "")))
                case .failure(let err):
                    self.fetchLatestTag(prerelease: false) { res2 in
                        switch res2 {
                        case .success(let info):
                            completion(.success(info))
                        case .failure:
                            let code = (err as NSError).code
                            completion(.failure(code == 404 ? Self.notFoundError() : err))
                        }
                    }
                }
            }

        case .alpha:
            fetchJSON("https://api.github.com/repos/\(REPO_SLUG)/releases?per_page=30") { res in
                switch res {
                case .success(let obj):
                    let arr = obj as? [[String: Any]] ?? []
                    if let r = arr.first(where: { ($0["prerelease"] as? Bool) == true }),
                       let tag = r["tag_name"] as? String, !tag.isEmpty {
                        completion(.success((
                            tag: tag,
                            url: r["html_url"] as? String ?? RELEASES_URL,
                            notes: r["body"] as? String ?? "")))
                    } else {
                        self.fetchLatestTag(prerelease: true, completion: completion)
                    }
                case .failure(let e):
                    let code = (e as NSError).code
                    completion(.failure(code == 404 ? Self.notFoundError() : e))
                }
            }
        }
    }

    /// 从 tags 里取最高版本；prerelease 为 true 时只取带预发布后缀的 tag
    func fetchLatestTag(prerelease: Bool,
                        completion: @escaping (Result<(tag: String, url: String, notes: String), Error>) -> Void) {
        fetchJSON("https://api.github.com/repos/\(REPO_SLUG)/tags?per_page=100") { res in
            switch res {
            case .success(let obj):
                let arr = obj as? [[String: Any]] ?? []
                var best: String?
                for t in arr {
                    guard let name = t["name"] as? String, !name.isEmpty else { continue }
                    let isPre = name.contains("-")
                    if prerelease != isPre { continue }
                    if let b = best {
                        if self.isNewer(name, than: b) { best = name }
                    } else {
                        best = name
                    }
                }
                if let tag = best {
                    completion(.success((tag: tag, url: RELEASES_URL, notes: "")))
                } else {
                    completion(.failure(Self.notFoundError()))
                }
            case .failure(let e):
                completion(.failure(e))
            }
        }
    }

    static func notFoundError() -> NSError {
        NSError(domain: "AdbWifiBar", code: 404, userInfo: [
            NSLocalizedDescriptionKey: L.t("err.noRelease")])
    }

    func fetchJSON(_ urlStr: String, _ completion: @escaping (Result<Any, Error>) -> Void) {
        guard let url = URL(string: urlStr) else {
            completion(.failure(NSError(domain: "AdbWifiBar", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L.t("err.badURL")])))
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("AdbWifiBar/\(APP_VERSION)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { completion(.failure(err)); return }
            guard let http = resp as? HTTPURLResponse else {
                completion(.failure(NSError(domain: "AdbWifiBar", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: L.t("err.noResponse")])))
                return
            }
            guard (200..<300).contains(http.statusCode), let data = data else {
                completion(.failure(NSError(domain: "AdbWifiBar", code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: L.t("err.http", http.statusCode)])))
                return
            }
            do {
                completion(.success(try JSONSerialization.jsonObject(with: data)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
}

// MARK: - 单实例保护
//
// 三层防护，按可靠性从高到低：
//   1) Info.plist 的 LSMultipleInstancesProhibited —— 拦 LaunchServices 启动（open -n）
//   2) 本文件末尾的运行时互斥（flock 独占锁）—— 拦直接执行二进制文件等绕过 1 的情况
//   3) 启动时清理「同一 App 的旧进程」—— 处理更新/重装后新旧副本共存
//
// 为什么用 flock 而不是分布式通知/NSRunningApplication：
//   - NSRunningApplication 只知道「有没有同名 App 在跑」，无法区分路径，
//     开发预览版（build/）和正式版（~/Applications/）会互相误判
//   - flock 以「锁文件 + 独占」语义工作，进程退出（含崩溃）时内核自动释放，不会残留死锁

/// 单实例守卫：拿不到锁说明已有实例在跑，直接退出当前进程。
enum SingleInstance {
    /// 锁文件放在用户级别目录，同一用户的开发版/正式版共享同一把锁
    /// （两者操作的是同一份 adb 状态与菜单栏位置，本就不该同时存在）
    static func lockPath() -> String {
        let dir = NSHomeDirectory() + "/Library/Application Support/adb-wifi-manager"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/menubar.lock"
    }

    /// 尝试取得独占锁。成功返回 fd（需全程持有），失败返回 nil。
    static func acquire() -> Int32? {
        let path = lockPath()
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        // LOCK_NB：拿不到立即返回失败，不阻塞（避免第二个实例卡住）
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
        // 写入当前 pid，便于排查「谁占着锁」
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        ftruncate(fd, 0)
        _ = pid.data(using: .utf8).map { write(fd, ($0 as NSData).bytes, $0.count) }
        return fd
    }

    /// 激活已运行的实例：让它的菜单栏图标被看到（菜单栏项无法程序化高亮，
    /// 这里只做一次轻量提示；用户点到图标即可看到当前状态）
    static func notifyExisting() {
        // 通过用户通知告知「已在运行」，避免用户以为没启动成功
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e",
            "display notification \"菜单栏中已有一个实例在运行\" with title \"ADB WiFi\""]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// 退出时清理锁文件内容（不删除文件本身，避免竞态）
    static func release(_ fd: Int32) {
        ftruncate(fd, 0)
        flock(fd, LOCK_UN)
        close(fd)
    }
}

/// 清理「旧版本副本」：更新时新 App 覆盖到 ~/Applications，但旧进程可能仍在运行，
/// 表现为菜单栏有图标、点开却是旧版本，且新旧两边状态不同步。
///
/// 判定条件（必须同时满足才杀）：
///   1. 进程的可执行路径以 /Contents/MacOS/AdbWifiBar 结尾（是同一个 App 的可执行文件）
///   2. 该路径与本进程路径**不同**（同一路径的是「正常重复启动」，交给 flock 处理，不能杀）
///   3. 该路径对应的 .app 已经不存在，或就是本 App 会被替换的同一目标位置
/// 这样既能清掉更新残留，又不会误杀用户正在使用的另一个正常副本。
enum StaleInstance {
    static func terminateStaleCopies() {
        let me = ProcessInfo.processInfo.processIdentifier
        let myExe = (Bundle.main.executableURL ?? URL(fileURLWithPath: "")).path
        guard !myExe.isEmpty else { return }
        let myApp = Bundle.main.bundleURL.path

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return }

        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let sp = trimmed.firstIndex(of: " ") else { continue }
            let pidStr = String(trimmed[trimmed.startIndex..<sp])
            let cmd = String(trimmed[trimmed.index(after: sp)...])
                .trimmingCharacters(in: .whitespaces)
            guard let pid = pid_t(pidStr), pid != me else { continue }
            // 条件 1：是同一个 App 的可执行文件
            guard cmd.hasSuffix("/Contents/MacOS/AdbWifiBar") else { continue }
            // 条件 2：路径不同（同路径的是正常重复启动，交给 flock）
            guard cmd != myExe else { continue }
            // 条件 3：该旧副本依附的 .app 已不存在（更新时被替换/删除后残留的进程），
            // 或指向的正是本 App 的位置（同一安装目标，说明是上一轮的旧进程）。
            // 若旧副本位于另一个**仍然存在**的 .app 里（例如开发用的 build/ 副本），
            // 那是一个独立的合法实例，不清理。
            // AdbWifiBar → MacOS → Contents → Xxx.app
            let oldAppPath = URL(fileURLWithPath: cmd)
                .deletingLastPathComponent()   // Contents/MacOS
                .deletingLastPathComponent()   // Contents
                .deletingLastPathComponent()   // Xxx.app
                .path
            let gone = !FileManager.default.fileExists(atPath: oldAppPath)
            guard gone || oldAppPath == myApp else { continue }
            kill(pid, SIGTERM)
        }
    }
}

// ---- 单实例守卫（必须在 NSApplication 初始化前完成）----
//
// 顺序很关键：**先清理旧进程，再取锁**。
// 反过来的话，新版本启动时旧版本仍持有锁，本进程会在 acquire() 处直接退出，
// 永远走不到清理那一步 —— 表现为"更新后菜单栏还是旧版本"。
//
// 唯一安全的清理对象：**本进程所在 App 包之外的、同一 App 的旧副本**
// （典型场景：更新时新 App 装到 ~/Applications，旧 App 进程还在跑）。
// 绝不能杀掉「已有一个正常实例」的情况，否则用户双击图标就会把正在用的实例顶掉。
StaleInstance.terminateStaleCopies()
guard let instanceLock = SingleInstance.acquire() else {
    // 走到这里说明：同一路径下已有健康实例在运行 —— 这是正常的重复启动，
    // 提示用户后安静退出，不动那个实例。
    SingleInstance.notifyExisting()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 仅菜单栏，不占 Dock
let delegate = AppDelegate()
app.delegate = delegate
app.run()
SingleInstance.release(instanceLock)
