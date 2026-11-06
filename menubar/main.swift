// AdbWifiBar —— Android 无线调试连接状态菜单栏工具
//
// 一个极简的 macOS 菜单栏辅助程序：展示当前无线调试连接状态，
// 并可直接启动/停止后台守护服务。真正的连接逻辑由 adb-wifi.sh 负责。
//
// 编译: ./build.sh

import Cocoa

// MARK: - 配置

let APP_BUNDLE_ID = "com.durunzhe.adb-wifibar"

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

    // 情形 2：App 被复制到 ~/Applications 等位置，按常见目录依次查找
    let home = NSHomeDirectory()
    let candidates = [
        home + "/mycode/adb-wifi-manager/bin/adb-wifi.sh",
        home + "/opencode-work/adb-wifi-manager/bin/adb-wifi.sh",
        home + "/code/adb-wifi-manager/bin/adb-wifi.sh",
        home + "/Projects/adb-wifi-manager/bin/adb-wifi.sh",
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

// MARK: - 执行脚本

@discardableResult
func runScript(_ args: [String], timeout: TimeInterval = 20) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [SCRIPT] + args
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:"
        + NSHomeDirectory() + "/Library/Android/sdk/platform-tools"
    p.environment = env
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do {
        try p.run()
    } catch {
        return (-1, "无法执行脚本: \(error.localizedDescription)")
    }
    // 超时保护，避免界面卡死
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline {
        usleep(50_000)
    }
    if p.isRunning {
        p.terminate()
        return (-1, "执行超时")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// MARK: - 状态

struct Status {
    var running = false
    var pid = ""
    var mode = ""              // launchd / manual / stopped
    var endpoints: [String] = []
    var allDevices: [(String, String)] = []
    var hasUSB = false
    var usbFound: [String] = []
    var mdnsOK = false
    var knownFound: [String] = []
    var macIP = ""
    var devModel = ""
    // 结构化诊断结论（由脚本层统一给出，与 TUI 完全同源）
    var diagLevel = ""
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

/// 解析 KEY=VALUE 形式的 diag 输出
func loadStatus() -> Status {
    let r = runScript(["diag"], timeout: 20)
    var s = Status()
    s.raw = r.out
    var kv: [String: String] = [:]
    for line in r.out.split(separator: "\n") {
        guard let eq = line.firstIndex(of: "=") else { continue }
        let k = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
        let v = String(line[line.index(after: eq)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !k.isEmpty { kv[k] = v }
    }
    if kv.isEmpty {
        s.loadError = r.out.isEmpty ? "无法读取设备状态" : String(r.out.prefix(120))
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
    s.diagLevel = kv["DIAG_LEVEL"] ?? ""
    s.diagTitle = kv["DIAG_TITLE"] ?? ""
    s.diagHint = kv["DIAG_HINT"] ?? ""
    s.diagAction = kv["DIAG_ACTION"] ?? ""
    for item in splitCSV(kv["ALL_DEVICES"]) {
        let parts = item.split(separator: "|", maxSplits: 1).map(String.init)
        if parts.count == 2 { s.allDevices.append((parts[0], parts[1])) }
    }
    return s
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
        // 兜底轮询（事件监听失效时仍能更新），间隔比之前更短
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
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
    var lastLoadedAt = Date.distantPast

    var refreshing = false
    var lastRefreshAt = Date.distantPast

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

    func menuNeedsUpdate(_ menu: NSMenu) {
        // 每次展开菜单都实时重新采集，保证与 TUI 展示一致
        _ = menu
        let s = loadStatus()
        status = s
        lastLoadedAt = Date()
        updateIcon(s)
        menu.removeAllItems()

        // ---- 守护状态 ----
        let modeText = s.mode == "launchd" ? "开机自启" : (s.mode == "manual" ? "手动启动" : "")
        var headTitle = s.running ? "● 守护运行中" : "○ 守护已停止"
        if s.running && !modeText.isEmpty { headTitle += "（\(modeText)）" }
        menu.addItem(disabledItem(headTitle))

        if !s.loadError.isEmpty {
            menu.addItem(disabledItem("  ⚠ \(s.loadError)"))
        }

        // ---- 设备 ----
        if s.endpoints.isEmpty {
            menu.addItem(disabledItem("  没有无线设备连接"))
        } else {
            for ep in s.endpoints {
                let it = NSMenuItem(title: "  ✓ \(ep)", action: #selector(copyEndpoint(_:)), keyEquivalent: "")
                it.target = self
                it.toolTip = "点击复制该地址"
                menu.addItem(it)
            }
        }

        // ---- 诊断结论（与 TUI 同源，由脚本层 DIAG_* 字段给出）----
        if !s.diagTitle.isEmpty {
            menu.addItem(.separator())
            let icon = s.diagLevel == "ok" ? "✓" : (s.diagLevel == "warn" ? "!" : "✗")
            menu.addItem(disabledItem("  [\(icon)] \(s.diagTitle)"))
            if !s.diagHint.isEmpty {
                menu.addItem(disabledItem("        \(s.diagHint)"))
            }
            if !s.diagAction.isEmpty {
                let fix = NSMenuItem(title: "  ▸ 处理：\(actionLabel(s.diagAction))",
                                     action: #selector(runDiagAction(_:)), keyEquivalent: "")
                fix.target = self
                fix.toolTip = s.diagHint
                menu.addItem(fix)
            }
        }

        // ---- 环境信息 ----
        menu.addItem(.separator())
        var env: [String] = []
        env.append("mDNS：" + (s.mdnsOK ? "可用" : "被屏蔽"))
        env.append("USB：" + (s.hasUSB ? "已连接" : "未连接"))
        var how: [String] = []
        if !s.usbFound.isEmpty { how.append("USB 读取") }
        if !s.knownFound.isEmpty { how.append("记忆端点") }
        if s.mdnsOK { how.append("mDNS") }
        env.append("发现方式：" + (how.isEmpty ? "无" : how.joined(separator: "、")))
        for line in env {
            menu.addItem(disabledItem("  " + line))
        }
        if !s.macIP.isEmpty {
            menu.addItem(disabledItem("  本机：" + s.macIP))
        }
        if !s.devModel.isEmpty {
            menu.addItem(disabledItem("  手机：" + s.devModel))
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: s.running ? "停止守护服务" : "启动守护服务",
            action: #selector(toggleDaemon), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let reconnect = NSMenuItem(title: "立即重连一次", action: #selector(forceReconnect), keyEquivalent: "r")
        reconnect.target = self
        menu.addItem(reconnect)

        let devs = NSMenuItem(title: "打开 adb devices", action: #selector(openDevices), keyEquivalent: "d")
        devs.target = self
        menu.addItem(devs)

        let log = NSMenuItem(title: "查看日志…", action: #selector(showLog), keyEquivalent: "l")
        log.target = self
        menu.addItem(log)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出菜单栏（守护继续运行）", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// 把动作 ID 翻译成用户能看懂的文字
    func actionLabel(_ action: String) -> String {
        switch action {
        case "usb_help": return "插上 USB 自动读取端口"
        case "manual_connect": return "输入 IP:端口 连接"
        case "phone_dev_settings": return "在手机上打开开发者选项"
        case "phone_wireless": return "在手机上打开无线调试"
        case "reconnect_now": return "重新诊断"
        case "start_daemon": return "启动守护"
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
                    self.flash(title: "守护", text: r.out.trimmingCharacters(in: .whitespacesAndNewlines))
                    self.refresh()
                }
            }
        case "reconnect_now":
            refresh()
            flash(title: "重新诊断", text: "已刷新")
        case "usb_help":
            let msg = """
            插上 USB 线即可自动恢复连接。

            步骤：
            1. 用数据线把手机连到这台 Mac
            2. 手机弹窗「允许 USB 调试」→ 点允许
            3. 菜单会自动刷新并读取手机的真实端口

            原理：无线调试端口每次随机分配，通过 USB 读取不受网络
            屏蔽影响，是最可靠的方式。
            """
            showTextWindow(title: "如何用 USB 自动读取端口", content: msg)
        case "manual_connect":
            let cmd = "adb connect <手机IP>:<端口>"
            let msg = """
            请先在手机上查看地址：
              设置 → 开发者选项 → 无线调试 → 页面顶部显示 IP:端口

            然后在终端里执行（菜单栏无法输入，复制下面命令改好再执行）：
              \(cmd)

            或者打开终端 TUI 完成（推荐，可点选）：
              cd ~/mycode/adb-wifi-manager && ./adbwifi

            提示：连接过一次后地址会被记住，之后掉线能自动重连。
            """
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
            showTextWindow(title: "手动连接（命令已复制到剪贴板）", content: msg)
        case "phone_dev_settings", "phone_wireless":
            let serial = status.allDevices.first(where: { !$0.0.contains(":") })?.0 ?? ""
            if serial.isEmpty {
                showTextWindow(title: "需要 USB 连接",
                               content: "该操作需要先插上 USB 线连接手机，\n才能在手机上自动跳转设置页面。")
                return
            }
            let setting = action == "phone_wireless"
                ? "com.android.settings/.Settings$WirelessDebuggingActivity"
                : nil
            let args: [String] = setting != nil
                ? ["-s", serial, "shell", "am", "start", "-n", setting!]
                : ["-s", serial, "shell", "am", "start", "-a", "android.settings.APPLICATION_DEVELOPMENT_SETTINGS"]
            let out = shell("/usr/bin/env", ["adb"] + args)
            showTextWindow(title: "在手机上打开设置",
                           content: out.isEmpty ? "已发送跳转指令，请在手机上查看。" : out)
        default:
            let msg = """
            请打开终端 TUI 查看完整解决方案（支持点选操作）：
              cd ~/mycode/adb-wifi-manager && ./adbwifi
            """
            showTextWindow(title: "需要进一步处理", content: msg)
        }
    }

    @objc func copyEndpoint(_ sender: NSMenuItem) {
        let ep = sender.title.replacingOccurrences(of: "  ✓ ", with: "")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ep, forType: .string)
        flash(title: "已复制", text: ep)
    }

    @objc func toggleDaemon() {
        busy = true
        let wasRunning = status.running
        DispatchQueue.global().async {
            let r = runScript([wasRunning ? "stop" : "start"])
            DispatchQueue.main.async {
                self.busy = false
                self.flash(title: wasRunning ? "守护已停止" : "守护已启动", text: r.out.trimmingCharacters(in: .whitespacesAndNewlines))
                self.refresh()
            }
        }
    }

    @objc func forceReconnect() {
        busy = true
        DispatchQueue.global().async {
            // 断开所有无线设备，让守护立刻重新建立连接
            let list = self.status.endpoints
            for ep in list {
                _ = self.shell("/usr/bin/env", ["adb", "disconnect", ep])
            }
            var msg = list.isEmpty ? "当前无无线连接，守护会在发现问题后自动连接" : "已断开，守护将自动重连"
            if !list.isEmpty {
                _ = self.shell("/usr/bin/env", ["adb", "connect", list[0]])
                msg = "已触发重连: \(list[0])"
            }
            DispatchQueue.main.async {
                self.busy = false
                self.flash(title: "重连", text: msg)
                self.refresh()
            }
        }
    }

    @discardableResult
    func shell(_ path: String, _ args: [String]) -> String {
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
        do { try p.run() } catch { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }

    @objc func openDevices() {
        let out = shell("/usr/bin/env", ["adb", "devices", "-l"])
        showTextWindow(title: "adb devices -l", content: out)
    }

    func logPath() -> String {
        NSHomeDirectory() + "/Library/Application Support/adb-wifi-manager/logs/adb-wifi.log"
    }

    @objc func showLog() {
        let p = logPath()
        let content = (try? String(contentsOfFile: p, encoding: .utf8)) ?? "（暂无日志）"
        showTextWindow(title: "adb-wifi 日志", content: String(content.suffix(50_000)))
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
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 仅菜单栏，不占 Dock
let delegate = AppDelegate()
app.delegate = delegate
app.run()
