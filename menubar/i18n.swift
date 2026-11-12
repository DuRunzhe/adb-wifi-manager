import Foundation

/// 界面语言。默认 .system：跟随系统语言（zh-Hant → 繁体，zh → 简中，其余英文）
enum AppLanguage: String, CaseIterable {
    case system
    case zhHans
    case zhHant
    case en

    /// 语言菜单里显示的名称（语言名用其本身语言；「跟随系统」固定双语，
    /// 即使误切到不认识的界面语言也能凭图标/双语找回）
    var displayName: String {
        switch self {
        case .system: return "跟随系统 / Follow System"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        }
    }

    /// 跟随系统时解析出的实际语言
    var resolved: AppLanguage {
        guard self == .system else { return self }
        let code = (Locale.preferredLanguages.first ?? "en").lowercased()
        if code.hasPrefix("zh-hant") || code.hasPrefix("zh-tw")
            || code.hasPrefix("zh-hk") || code.hasPrefix("zh-mo") {
            return .zhHant
        }
        if code.hasPrefix("zh") { return .zhHans }
        return .en
    }
}

/// 极简本地化：静态字典 + UserDefaults 持久化
final class L {
    static let shared = L()
    static let defaultsKey = "ADBWifiLanguage"

    private(set) var language: AppLanguage = .system
    private var table: [String: String] = [:]

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKey)
            ?? AppLanguage.system.rawValue
        apply(AppLanguage(rawValue: raw) ?? .system, persist: false)
    }

    private func apply(_ lang: AppLanguage, persist: Bool) {
        language = lang
        table = Self.tables[lang.resolved] ?? Self.tables[.en] ?? [:]
        if persist {
            UserDefaults.standard.set(lang.rawValue, forKey: Self.defaultsKey)
        }
    }

    static var current: AppLanguage { shared.language }

    static func setLanguage(_ lang: AppLanguage) {
        shared.apply(lang, persist: true)
    }

    static func t(_ key: String, _ args: CVarArg...) -> String {
        let format = shared.table[key] ?? key
        if args.isEmpty { return format }
        return String(format: format, arguments: args)
    }

    /// key 是否已收录。
    /// 用于「脚本下发了新 DIAG_CODE、但 App 版本尚未收录」的降级判断，
    /// 避免直接把 key 当文案显示出去。
    static func has(_ key: String) -> Bool { shared.table[key] != nil }

    // MARK: - 文案表

    private static let tables: [AppLanguage: [String: String]] = [
        .zhHans: zhHans,
        .zhHant: zhHant,
        .en: en,
    ]

    private static let zhHans: [String: String] = [
        "app.name": "ADB WiFi",
        "app.tooltip": "ADB WiFi",

        "daemon.running": "● 守护运行中",
        "daemon.stopped": "○ 守护已停止",
        "daemon.mode.launchd": "开机自启",
        "daemon.mode.manual": "手动启动",
        "daemon.modeFormat": "（%@）",
        "env.discovery.sep": "、",
        "device.none": "  没有无线设备连接",
        "device.copyTip": "点击复制该地址",
        "diag.actionPrefix": "  ▸ 处理：",

        "env.mdns": "mDNS：",
        "env.mdns.ok": "可用",
        "env.mdns.blocked": "被屏蔽",
        "env.usb": "USB：",
        "env.usb.connected": "已连接",
        "env.usb.disconnected": "未连接",
        "env.tcp": "无线连接方式：",
        "env.tcp.on": "已就绪（端口 %@）",
        "env.tcp.pending": "准备中（插着 USB，稍等会自动切过来）",
        "env.tcp.off": "还没开（插上 USB 就会自动打开）",
        "env.tcp.autoOff": "自动切换已关闭",
        "env.discovery": "发现方式：",
        "env.discovery.usb": "插 USB 读到的",
        "env.discovery.known": "上次连过的地址",
        "env.discovery.mdns": "mDNS",
        "env.discovery.none": "无",
        "env.host": "  本机：",
        "env.rate.tip": "adb 传输速率（↓ 手机→Mac，↑ Mac→手机）",
        "env.rate.total": "  累计：收 %@ MB / 发 %@ MB",

        "menu.stopDaemon": "停止守护服务",
        "menu.startDaemon": "启动守护服务",
        "menu.enableTcpip": "立即开启 TCP 模式（免手动开无线调试）",
        "menu.enableTcpip.tip": "通过 USB 执行 adb tcpip %@，之后即可无线连接",
        "menu.adbDevices": "打开 adb devices",
        "menu.phoneWireless": "在手机上打开「无线调试」…",
        "menu.phoneDev": "在手机上打开「开发者选项」…",
        "menu.phone.tip.connected": "直接在手机上定位到无线调试开关",
        "menu.phone.tip.dev": "打开开发者选项页",
        "menu.viewLog": "查看日志…",
        "menu.openTUI": "打开终端 TUI…",
        "menu.openTUI.tip": "在终端里打开交互界面（支持鼠标点选修复方案）",
        "menu.settings": "设置",
        "menu.language": "语言",
        "menu.about": "关于 ADB WiFi",
        "menu.quit": "退出菜单栏（守护继续运行）",

        "lang.system": "跟随系统",
        "lang.zhHans": "简体中文",
        "lang.zhHant": "繁體中文",
        "lang.en": "English",

        "about.title": "关于 ADB WiFi",
        "about.version": "版本 %@",
        "about.buildSuffix": "（build %@）",
        "about.desc": "菜单栏上的 Android 无线调试守护客户端\n连接状态、传输速率与一键恢复，随时可见。",
        "about.check": "检查正式版更新",
        "about.checkTip": "只检查正式发布版本（稳定推荐）",
        "about.checking": "检查中…",
        "about.upToDate": "已是最新版本，点击重查",
        "about.checkFailed": "检查失败，点击重试",
        "about.downloadInstall": "下载并安装 %@",
        "about.installing": "正在安装…",
        "about.alpha.prefix": "预发布通道：",
        "about.alpha.idle": "Alpha 预览版",
        "about.alpha.checking": "Alpha 检查中…",
        "about.alpha.upToDate": "Alpha 已最新，点击重查",
        "about.alpha.notFound": "Alpha 暂无版本，点击重查",
        "about.alpha.failed": "Alpha 检查失败，点击重试",
        "about.alpha.download": "下载并安装 Alpha %@",
        "about.alpha.installing": "正在下载并安装…",
        "about.alpha.installingTag": "正在下载并安装 Alpha %@…",
        "about.installFailed": "更新失败，点击重试",
        "about.tip.upToDate": "当前已是最新（%@）",
        "about.tip.updateAvailable": "当前 %@ → 可更新到 %@",
        "about.tip.installing": "正在下载并安装 %@，完成后自动重启",
        "about.tip.failed": "检查失败：%@",
        "about.alpha.available": "Alpha %@ 可用（点上方按钮更新）",
        "about.alpha.tip.available": "点上方按钮安装 Alpha %@",
        "about.alpha.installFailed": "Alpha 更新失败，点击重试",
        "about.alpha.tip": "预发布版本：功能最新，但可能不稳定",
        "about.alpha.tip.download": "点击后自动下载并安装，完成后自动重启",
        "about.alpha.tip.upToDate": "最新 Alpha：%@",
        "about.alpha.tip.notFound": "仓库暂无预发布版本",
        "about.link.home": "项目主页",
        "about.link.issues": "问题反馈",
        "about.link.releases": "版本发布",
        "about.close": "关闭",

        "about.status.checking": "正在检查正式版更新…",
        "about.status.upToDate": "当前已是最新（%@）",
        "about.status.updateAvailable": "当前 %@ → 可更新到 %@，点击上方按钮安装",
        "about.status.failed": "检查失败：%@，点击按钮重试",
        "about.status.noStable": "暂无正式版本，点击按钮重试",
        "about.status.noVersion": "检查失败：未获取到版本号，点击按钮重试",
        "about.status.downloading": "正在下载 %@…",
        "about.status.installing": "安装中，App 将自动重启…",
        "about.status.updateFailed": "更新失败：%@，点击按钮重试",
        "about.status.updateLauncherFailed": "更新失败：无法启动更新进程（%@）",

        "action.usb_help": "插上 USB 自动读取端口",
        "action.manual_connect": "输入 IP:端口 连接",
        "action.phone_dev_settings": "在手机上打开开发者选项",
        "action.phone_wireless": "在手机上打开无线调试",
        "action.reconnect_now": "重新诊断",
        "action.start_daemon": "启动守护",

        "flash.daemon": "守护",
        "flash.stopped": "守护已停止",
        "flash.started": "守护已启动",
        "flash.copied": "已复制",
        "flash.recovered": "已恢复",
        "flash.reconnect": "重新诊断",
        "flash.refreshed": "已刷新",
        "flash.tcpOn": "TCP 模式已开启",
        "flash.tcpFail": "TCP 模式开启失败",
        "flash.opened": "已打开",
        "flash.checkPhone": "请看手机屏幕",
        "flash.manualWireless": "请手动点无线调试",
        "flash.openFailed": "打开失败",
        "flash.connectFirst": "请确认手机已连接",
        "phone.openTitle": "在手机上打开「%@」",
        "usb.none.title": "未检测到 USB 设备",
        "recover.failed.title": "未能恢复无线连接",
        "phone.wireless": "无线调试",
        "phone.dev": "开发者选项",
        "log.title": "adb-wifi 日志",

        // ---- 错误与提示 ----
        "err.scriptFailed": "无法执行脚本：%@",
        "err.timeout": "执行超时",
        "err.noStatus": "无法读取设备状态",
        "err.noWifiIP": "已切换 TCP 模式，但未取到手机 Wi-Fi IP",
        "err.noRelease": "仓库暂未发布任何版本，可打开版本发布页手动查看。",
        "err.badURL": "无效的地址",
        "err.noResponse": "未收到服务器响应",
        "err.http": "GitHub 返回 HTTP %d",

        // ---- 帮助弹窗 ----
        "help.usb.title": "如何用 USB 自动读取端口",
        "help.usb.body": """
        插上 USB 线即可自动恢复连接。

        步骤：
        1. 用数据线把手机连到这台 Mac
        2. 手机弹窗「允许 USB 调试」→ 点允许
        3. 菜单会自动刷新并读取手机的真实端口

        原理：无线调试端口每次随机分配，通过 USB 读取不受网络
        屏蔽影响，是最可靠的方式。
        """,
        "help.manual.title": "手动连接（命令已复制到剪贴板）",
        "help.manual.cmd": "adb connect <手机IP>:<端口>",
        "help.manual.body": """
        请先在手机上查看地址：
          设置 → 开发者选项 → 无线调试 → 页面顶部显示 IP:端口

        然后在终端里执行（菜单栏无法输入，复制下面命令改好再执行）：
          %@

        或者打开终端 TUI 完成（推荐，可点选）：
          cd ~/mycode/adb-wifi-manager && ./adbwifi

        提示：连接过一次后地址会被记住，之后掉线能自动重连。
        """,
        "help.tui.title": "需要进一步处理",
        "help.tui.body": """
        请打开终端 TUI 查看完整解决方案（支持点选操作）：
          cd ~/mycode/adb-wifi-manager && ./adbwifi
        """,
        "usb.none.body": "请先用 USB 线连接手机并允许 USB 调试，\n再点击此菜单项。",

        // ---- 手机设置页跳转（协议 RESULT / PAGE / WIFI_TOGGLE）----
        "phone.open.body": "已在手机上打开「%@」页面。",
        "phone.open.toggleOff": "当前「无线调试」开关未开启，请在手机上点开。",
        "phone.open.toggleUnknown": "该 ROM 可能不暴露无线调试开关状态，请在手机上确认。",
        "phone.open.partialTitle": "已打开开发者选项",
        "phone.open.partial": "该 ROM 未能直接定位到「无线调试」页，请在列表中手动点击「无线调试」。",
        "phone.open.failedTitle": "打开设置失败",
        "phone.open.noDevice": "未检测到已连接的设备。请先用 USB 线或无线连接手机，再试一次。",
        "phone.open.failedBody": "无法在手机上打开设置页。\n请确认手机已解锁并允许 USB 调试，或改用终端 TUI 排查。",

        // ---- 恢复无线连接（协议 RESULT / ENDPOINT / VIA / ERROR）----
        "recover.failed.body": "未能恢复无线连接。\n\n可能原因与处理：\n  1) 手机重启过 → tcpip 模式已失效，需插一次 USB（守护会自动恢复）\n  2) 手机未连 Wi-Fi，或与 Mac 不在同一网段\n  3) 手机改回 USB 模式了 → 插 USB 后会自动切换",

        // ---- 更新失败原因 ----
        "update.err.download": "下载失败，请检查网络后重试",
        "update.err.downloadDetail": "下载失败：%@",
        "update.err.tempDir": "无法创建临时目录：%@",
        "update.err.package": "安装包内容异常",
        "update.err.packageDetail": "安装包解压失败：%@",
        "update.err.signature": "签名校验失败：%@",
        "update.err.unknown": "未知原因",
        "about.alpha.errNoVersion": "未获取到版本号",

        "log.empty": "（暂无日志）",
        "tui.missing.title": "找不到 TUI 入口",
        "tui.missing.body": "未找到：%@\n请确认脚本目录完整（应包含 adbwifi 与 bin/adbwifi-tui.py）。",

        // ---- 诊断结论（key 由脚本的 DIAG_CODE 拼接：diag.<CODE>.title / .hint）----
        "diag.DAEMON_DOWN_NO_DEVICE.title": "守护未运行且无设备连接",
        "diag.DAEMON_DOWN_NO_DEVICE.hint": "点击「启动守护」开始自动连接",
        "diag.CONNECTED_MDNS.title": "连接正常",
        "diag.CONNECTED_MDNS.hint": "mDNS 自动发现可用",
        "diag.CONNECTED_VIA_TCPIP_USB.title": "设备已连接（USB 自动转 TCP）",
        "diag.CONNECTED_VIA_TCPIP_USB.hint": "TCP 端口 %@ 已开启，可安全拔掉 USB",
        "diag.CONNECTED_VIA_TCPIP_WIRELESS.title": "设备已连接（无线 %@ 端口）",
        "diag.CONNECTED_VIA_TCPIP_WIRELESS.hint": "USB 已拔出，无线连接独立保持正常",
        "diag.CONNECTED_VIA_KNOWN.title": "设备已连接（mDNS 被屏蔽）",
        "diag.CONNECTED_VIA_KNOWN.hint": "靠记忆端点维持，端口变化后需重连",
        "diag.DEV_OPTIONS_OFF.title": "手机「开发者选项」未开启",
        "diag.DEV_OPTIONS_OFF.hint": "插着 USB，可在手机上自动打开设置页",
        "diag.USB_AUTO_TCPIP_PENDING.title": "USB 已连接，正在自动建立无线连接",
        "diag.USB_AUTO_TCPIP_PENDING.hint": "守护将自动切换 TCP 模式（端口 %@），无需手动开无线调试",
        "diag.ADB_WIFI_OFF.title": "手机「无线调试」开关未打开",
        "diag.ADB_WIFI_OFF.hint": "插着 USB，可在手机上自动打开设置页",
        "diag.USB_CONNECTED_NO_WIRELESS.title": "USB 已连接，尚未建立无线连接",
        "diag.USB_CONNECTED_NO_WIRELESS.hint": "正在读取端口，稍候自动连接",
        "diag.NO_DEVICE_MDNS_OK.title": "未发现设备（mDNS 正常）",
        "diag.NO_DEVICE_MDNS_OK.hint": "请确认手机已开启无线调试且同一 Wi-Fi",
        "diag.NO_DEVICE_MDNS_BLOCKED.title": "未发现设备，且此网络屏蔽 mDNS",
        "diag.NO_DEVICE_MDNS_BLOCKED.hint": "插 USB 自动读端口 / 手动输入 IP:端口",
        // ---- 链路质量（多设备）----
        "net.macbattery.line": "Mac 电量 %@%%（%@）",
        "net.macbattery.charging": "充电中",
        "net.macbattery.charged": "已充满",
        "net.macbattery.ac": "外接电源",
        "net.macbattery.discharging": "使用电池",
        // ---- 多设备：设备列表与批量动作（dev.*）----
        "dev.tag.wifi": "无线",
        "dev.tag.usb": "USB",
        "dev.state.offline": "离线",
        "dev.state.unauthorized": "未授权",
        "dev.copy": "复制设备地址",
        "dev.phone.wireless": "无线调试",
        "dev.phone.dev": "开发者选项",
        "dev.phone.tip.unusable": "该设备当前不可用（离线或未授权）",
        "dev.onDevice": "操作设备：%@",
        "dev.all.recover": "无线断了？恢复全部 %@ 台",
        "dev.all.recover.tip": "会挨个检查每台手机：还在线的跳过，掉线的尝试重新连上；插着 USB 的会自动转成无线",
        "dev.all.recover.title": "全部设备重连结果",
        "dev.all.recover.body": "成功 %@ 台 / 失败 %@ 台",
        "dev.all.recover.already": "已在线",
        "dev.all.recover.recovered": "已恢复 %@（%@）",
        "dev.all.recover.failed": "恢复失败",
        "dev.all.recover.flash": "成功 %@ 台 / 失败 %@ 台",
        "dev.usb.tcpip.flash": "成功 %@ 台 / 失败 %@ 台",
        "open.result.opened": "已打开",
        "open.result.partial": "已到开发者选项，请手动点「无线调试」",
        "open.result.need_usb": "需要 USB 连接",
        "open.result.no_device": "设备不可用",
        "open.result.failed": "打开失败",
        "more.header": "更多信息",
        "env.rate.line": "↓ %@   ↑ %@",
        "dev.reconnect": "只重连这台",
        "dev.reconnect.tip": "只处理这一台，不影响其他手机。用它之前连过的地址重试；地址变了就改用上面那条\"恢复全部\"",
        "dev.reconnect.flash": "正在重连…",
        "dev.reconnect.failed.body": "未能恢复 %@ 的无线连接。\n\n可能原因：\n  1) 手机重启过，tcpip 模式已失效 → 插一次 USB（守护会自动恢复）\n  2) 手机未连 Wi-Fi，或与 Mac 不在同一网段\n  3) 手机 IP 变了 → 交给「全部设备 → 逐台重连」找回来",
        // ---- 主菜单顶部状态区（status.*）----
        "status.sep": " + ",
        "status.countWifi": "无线 %@ 台",
        "status.countUsb": "USB %@ 台",
        "status.connected": "已连接 %@",
        "status.badDevices": "（%@ 台不可用）",
        "status.noDevice": "未连接任何设备",
        "status.daemonDown": "守护未运行，当前无设备",
        "status.daemonOffSuffix": "· 守护未运行",
        "status.note.usbCanUnplug": "USB 已可拔线",
        "status.note.usbCanUnplug.tip": "无线连接已独立建立，拔掉数据线不影响调试",
        "status.note.tcpPending": "正在切换 TCP 模式，无需手动操作",
        "status.note.tcpPending.tip": "守护会自动执行 adb tcpip 并连接，稍候即可拔线",
        "status.note.mdnsBlocked": "此网络屏蔽 mDNS",
        "status.note.mdnsBlocked.tip": "新设备无法自动发现，换 IP 后可能掉线，需要手动连接或插一次 USB",
        // ---- 链路指标：单位 / 分级 / 算法说明（net.*）----
        "net.rtt.tip": "计算方式：Mac 对手机 IP 执行 ping -c 12，取平均往返时间。\n\n评价标准（局域网）：<20 ms 优秀｜20–50 ms 一般｜>50 ms 较差。\n\n注意：若「本次采样区间」跨度很大（如 5~225 ms），说明该 Wi-Fi 本身延迟抖动严重（常见于 AP 负载高、节能、Mesh 中继），此时均值只能看趋势，不代表稳定水平。\n\n影响：adb 采用块级应答协议，每个包都要等确认，RTT 越高吞吐上限越低。",
        "net.rtt.range": "本次采样区间：%@ ~ %@ ms（抖动幅度）",
        "net.signal.tip": "计算方式：读取手机上报的信号强度（dBm）。\n\n评价标准：>-50 极佳｜-50~-60 优秀｜-60~-70 良好｜-70~-80 偏弱｜<-80 很差。\n\n影响：信号越弱，手机和路由器之间的连接档次就越低、重发的数据越多，直接拉低最高速度。",
        "net.signal.mac": "Mac 侧信号：%@ dBm（对比用，两端越接近越好）",
        "net.ap.line": "AP %@ · 信道 %@ · %@ MHz · BSSID %@",
        "net.ap.tip": "BSSID：%@\nMac 所在信道：%@\n\n说明：同一 SSID 下 BSSID 不同 = 连了不同的 AP。两端的 BSSID 不一致时会跨 AP 转发，RTT 会明显抬高。",
        "net.usb.line": "USB 直连（不经过 Wi-Fi）",
        "net.usb.tip": "USB 设备走本地总线，没有网络往返延迟，也不受信号和信道影响，通常比无线的 adb 更快更稳。",
        "net.battery.line": "手机电量 %@%%（%@）",
        "net.battery.lineNoCharge": "手机电量 %@%%",
        "net.battery.charging": "充电中",
        "net.battery.tip": "计算方式：读取手机 dumpsys battery 的 level 与 status。\n\n影响：电量低于 15% 时系统会主动限制 Wi-Fi 与后台传输性能，此时延迟和速率波动会变大。",
        // ---- adb 吞吐量：可用空间 / 平均 / 最大（net.tp.*）----
        "net.tp.negligible": "<0.1",
        // ---- adb 吞吐量：上限 / 平均 / 最大 + 评级（net.tp.*）----
        "net.tp.tip": "adb 传输速度的三个数字：\n\n【上限】%@ Mbps × 60% ≈ %@ MB/s\n手机和路由器握手时定下的最高速率，打个六折才是实际能用的（无线要分时收发，还有协议开销）。它代表这台设备理论上最快能到多少。\n\n【平均】最近 10 分钟里有传输时的平均速度，代表日常典型水平。\n\n【最大】同期峰值，决定传大文件要多久。\n\n数据来源：Mac 上统计的 adb 连接流量，不含其他 App。",
        "net.tp.tip.usage": "评级依据：最大值 ÷ 上限 = %@%%。\n\n≥30%% 良好：连接健康，网速用起来了。\n10–30%% 一般：还有提升空间，通常是延迟高或有干扰。\n<10%% 偏低：瓶颈不在网速本身。adb 传输每发一块都要等手机回一个确认，延迟一高速度就上不去——50 ms 以上往往只能跑到 1–3 MB/s，这时该做的是靠近路由器、换 5GHz、别跨 AP，而不是换更快的 Wi-Fi。",
        // ---- 链路分级：等级词 + 量表 + 分档界线（net.*.grade.* / *.scale）----
        "net.rtt.grade.good": "优秀", "net.rtt.grade.fair": "一般", "net.rtt.grade.poor": "较差",
        "net.rtt.scale": "<20 / 20-50 / >50 分档",
        "net.signal.grade.excellent": "极佳", "net.signal.grade.good": "优秀",
        "net.signal.grade.ok": "良好", "net.signal.grade.weak": "偏弱", "net.signal.grade.bad": "很差",
        "net.signal.scale": "5 档，见 tooltip",
        "net.tp.grade.good": "良好", "net.tp.grade.fair": "一般", "net.tp.grade.poor": "偏低",
        "net.tp.scale": "≥30% / 10-30% / <10% 分档",
        "net.rtt.line": "延迟 %@ ms %@ %@（%@）",
        "net.signal.line": "信号 %@ dBm %@ %@（%@）",
        "net.tp.main": "传输速度 上限 %@ MB/s · 平均 %@ · 最大 %@ %@ %@（占上限 %@%%）",
        "net.tp.idle": "传输速度 上限 %@ MB/s · 暂无传输（%@）",
        // ---- 链路质量手动刷新 ----
        "net.refresh": "重新测一次速度",
        "net.refresh.tip": "跳过 60 秒缓存，重新采集延迟 / 信号 / 吞吐 / 电量（约 3 秒）",
        "net.refresh.flash": "正在刷新链路质量…",
        "net.refresh.flash.tip": "重新采集中，约需 3 秒",
        "net.refresh.done": "链路质量已刷新",
        "net.refresh.done.tip": "数据已更新",
        "net.refresh.failed": "刷新失败",
        "net.refresh.failed.tip": "设备可能无响应，请稍后重试或按「逐台重连」",
        "net.age.line": "数据是 %@前的",
        "net.age.sec": "%@ 秒",
        "net.age.min": "%@ 分钟",
        "dev.all.recoverOne": "无线断了？点这里恢复",
        "status.note.mdnsOK": "mDNS 正常，新设备可自动发现",
        "status.note.mdnsOK.tip": "手机开启无线调试后，会被自动发现并连上，无需手动输入地址。",
        "status.note.mdnsStalled": "mDNS 曾卡死，已自动重启恢复",
        "status.note.mdnsStalled.tip": "adb 后台服务的 mDNS 模块偶尔会失效（不是网络问题）。工具已自动重启 adb 并恢复，无需处理。",
        "status.note.mdnsFlaky": "mDNS 暂时没响应，正在重试",
        "status.note.mdnsFlaky.tip": "可能是网络瞬时抖动。连续多轮为空才会判定为屏蔽，届时工具会自动重启一次 adb 再确认。",
        "dev.ap.same": "🔗",
        "dev.ap.maybe": "🔗",
        "dev.ap.different": "⚠",
        "dev.ap.same.tip": "🔗 表示手机和这台电脑接在同一个 AP 下，互传不经过其他节点，延迟最低。",
        "dev.ap.maybe.tip": "🔗 表示信道相同，大概率接在同一个 AP 下。",
        "dev.ap.different.tip": "⚠ 表示手机和这台电脑不在同一个 AP 下，流量要经路由器转发，延迟会明显变高。",
    ]

    private static let zhHant: [String: String] = [
        "app.name": "ADB WiFi",
        "app.tooltip": "ADB WiFi",

        "daemon.running": "● 守護進程執行中",
        "daemon.stopped": "○ 守護進程已停止",
        "daemon.mode.launchd": "開機自啟",
        "daemon.mode.manual": "手動啟動",
        "daemon.modeFormat": "（%@）",
        "env.discovery.sep": "、",
        "device.none": "  沒有無線裝置連接",
        "device.copyTip": "點擊複製該位址",
        "diag.actionPrefix": "  ▸ 處理：",

        "env.mdns": "mDNS：",
        "env.mdns.ok": "可用",
        "env.mdns.blocked": "被封鎖",
        "env.usb": "USB：",
        "env.usb.connected": "已連接",
        "env.usb.disconnected": "未連接",
        "env.tcp": "無線連線方式：",
        "env.tcp.on": "已就緒（連接埠 %@）",
        "env.tcp.pending": "準備中（插著 USB，稍等會自動切過來）",
        "env.tcp.off": "還沒開（插上 USB 就會自動打開）",
        "env.tcp.autoOff": "自動切換已關閉",
        "env.discovery": "發現方式：",
        "env.discovery.usb": "插 USB 讀到的",
        "env.discovery.known": "上次連過的位址",
        "env.discovery.mdns": "mDNS",
        "env.discovery.none": "無",
        "env.host": "  本機：",
        "env.rate.tip": "adb 傳輸速率（↓ 手機→Mac，↑ Mac→手機）",
        "env.rate.total": "  累計：收 %@ MB / 發 %@ MB",

        "menu.stopDaemon": "停止守護服務",
        "menu.startDaemon": "啟動守護服務",
        "menu.enableTcpip": "立即開啟 TCP 模式（免手動開無線偵錯）",
        "menu.enableTcpip.tip": "透過 USB 執行 adb tcpip %@，之後即可無線連線",
        "menu.adbDevices": "開啟 adb devices",
        "menu.phoneWireless": "在手機上開啟「無線偵錯」…",
        "menu.phoneDev": "在手機上開啟「開發人員選項」…",
        "menu.phone.tip.connected": "直接定位到手機的無線偵錯開關",
        "menu.phone.tip.dev": "開啟開發人員選項頁面",
        "menu.viewLog": "查看日誌…",
        "menu.openTUI": "開啟終端機 TUI…",
        "menu.openTUI.tip": "在終端機裡開啟互動介面（支援滑鼠點選修復方案）",
        "menu.settings": "設定",
        "menu.language": "語言",
        "menu.about": "關於 ADB WiFi",
        "menu.quit": "結束選單列（守護繼續執行）",

        "lang.system": "跟隨系統",
        "lang.zhHans": "简体中文",
        "lang.zhHant": "繁體中文",
        "lang.en": "English",

        "about.title": "關於 ADB WiFi",
        "about.version": "版本 %@",
        "about.buildSuffix": "（build %@）",
        "about.desc": "選單列上的 Android 無線偵錯守護用戶端\n連線狀態、傳輸速率與一鍵恢復，隨時可見。",
        "about.check": "檢查正式版更新",
        "about.checkTip": "只檢查正式發布版本（穩定推薦）",
        "about.checking": "檢查中…",
        "about.upToDate": "已是最新版本，點擊重查",
        "about.checkFailed": "檢查失敗，點擊重試",
        "about.downloadInstall": "下載並安裝 %@",
        "about.installing": "正在安裝…",
        "about.alpha.prefix": "預發布通道：",
        "about.alpha.idle": "Alpha 預覽版",
        "about.alpha.checking": "Alpha 檢查中…",
        "about.alpha.upToDate": "Alpha 已最新，點擊重查",
        "about.alpha.notFound": "Alpha 暫無版本，點擊重查",
        "about.alpha.failed": "Alpha 檢查失敗，點擊重試",
        "about.alpha.download": "下載並安裝 Alpha %@",
        "about.alpha.installing": "正在下載並安裝…",
        "about.alpha.installingTag": "正在下載並安裝 Alpha %@…",
        "about.installFailed": "更新失敗，點擊重試",
        "about.tip.upToDate": "目前已是最新（%@）",
        "about.tip.updateAvailable": "目前 %@ → 可更新至 %@",
        "about.tip.installing": "正在下載並安裝 %@，完成後自動重新啟動",
        "about.tip.failed": "檢查失敗：%@",
        "about.alpha.available": "Alpha %@ 可用（點上方按鈕更新）",
        "about.alpha.tip.available": "點上方按鈕安裝 Alpha %@",
        "about.alpha.installFailed": "Alpha 更新失敗，點擊重試",
        "about.alpha.tip": "預發布版本：功能最新，但可能不穩定",
        "about.alpha.tip.download": "點擊後自動下載並安裝，完成後自動重新啟動",
        "about.alpha.tip.upToDate": "最新 Alpha：%@",
        "about.alpha.tip.notFound": "倉庫暫無預發布版本",
        "about.link.home": "專案首頁",
        "about.link.issues": "問題回報",
        "about.link.releases": "版本發布",
        "about.close": "關閉",

        "about.status.checking": "正在檢查正式版更新…",
        "about.status.upToDate": "目前已是最新（%@）",
        "about.status.updateAvailable": "目前 %@ → 可更新至 %@，點擊上方按鈕安裝",
        "about.status.failed": "檢查失敗：%@，點擊按鈕重試",
        "about.status.noStable": "暫無正式版本，點擊按鈕重試",
        "about.status.noVersion": "檢查失敗：未取得版本號，點擊按鈕重試",
        "about.status.downloading": "正在下載 %@…",
        "about.status.installing": "安裝中，App 將自動重新啟動…",
        "about.status.updateFailed": "更新失敗：%@，點擊按鈕重試",
        "about.status.updateLauncherFailed": "更新失敗：無法啟動更新程序（%@）",

        "action.usb_help": "插上 USB 自動讀取連接埠",
        "action.manual_connect": "輸入 IP:連接埠 連線",
        "action.phone_dev_settings": "在手機上開啟開發人員選項",
        "action.phone_wireless": "在手機上開啟無線偵錯",
        "action.reconnect_now": "重新診斷",
        "action.start_daemon": "啟動守護",

        "flash.daemon": "守護",
        "flash.stopped": "守護已停止",
        "flash.started": "守護已啟動",
        "flash.copied": "已複製",
        "flash.recovered": "已恢復",
        "flash.reconnect": "重新診斷",
        "flash.refreshed": "已重新整理",
        "flash.tcpOn": "TCP 模式已開啟",
        "flash.tcpFail": "TCP 模式開啟失敗",
        "flash.opened": "已開啟",
        "flash.checkPhone": "請看手機螢幕",
        "flash.manualWireless": "請手動點無線偵錯",
        "flash.openFailed": "開啟失敗",
        "flash.connectFirst": "請確認手機已連線",
        "phone.openTitle": "在手機上開啟「%@」",
        "usb.none.title": "未偵測到 USB 裝置",
        "recover.failed.title": "無法恢復無線連線",
        "phone.wireless": "無線偵錯",
        "phone.dev": "開發人員選項",
        "log.title": "adb-wifi 日誌",

        // ---- 錯誤與提示 ----
        "err.scriptFailed": "無法執行腳本：%@",
        "err.timeout": "執行逾時",
        "err.noStatus": "無法讀取裝置狀態",
        "err.noWifiIP": "已切換 TCP 模式，但未取得手機 Wi-Fi IP",
        "err.noRelease": "儲存庫尚未發布任何版本，可開啟版本發布頁手動查看。",
        "err.badURL": "無效的位址",
        "err.noResponse": "未收到伺服器回應",
        "err.http": "GitHub 傳回 HTTP %d",

        // ---- 說明視窗 ----
        "help.usb.title": "如何用 USB 自動讀取連接埠",
        "help.usb.body": """
        插上 USB 線即可自動恢復連線。

        步驟：
        1. 用傳輸線把手機連到這臺 Mac
        2. 手機彈窗「允許 USB 偵錯」→ 點允許
        3. 選單會自動重新整理並讀取手機的真實連接埠

        原理：無線偵錯連接埠每次隨機分配，透過 USB 讀取不受網路
        封鎖影響，是最可靠的方式。
        """,
        "help.manual.title": "手動連線（指令已複製到剪貼簿）",
        "help.manual.cmd": "adb connect <手機IP>:<連接埠>",
        "help.manual.body": """
        請先在手機上查看位址：
          設定 → 開發人員選項 → 無線偵錯 → 頁面頂端顯示 IP:連接埠

        然後在終端機裡執行（選單列無法輸入，複製下面指令改好再執行）：
          %@

        或開啟終端機 TUI 完成（推薦，可點選）：
          cd ~/mycode/adb-wifi-manager && ./adbwifi

        提示：連線過一次後位址會被記住，之後斷線能自動重連。
        """,
        "help.tui.title": "需要進一步處理",
        "help.tui.body": """
        請開啟終端機 TUI 查看完整解決方案（支援點選操作）：
          cd ~/mycode/adb-wifi-manager && ./adbwifi
        """,
        "usb.none.body": "請先用 USB 線連接手機並允許 USB 偵錯，\n再點擊此選單項目。",

        // ---- 手機設定頁跳轉（協議 RESULT / PAGE / WIFI_TOGGLE）----
        "phone.open.body": "已在手機上開啟「%@」頁面。",
        "phone.open.toggleOff": "目前「無線偵錯」開關未開啟，請在手機上點開。",
        "phone.open.toggleUnknown": "此 ROM 可能不公開無線偵錯開關狀態，請在手機上確認。",
        "phone.open.partialTitle": "已開啟開發人員選項",
        "phone.open.partial": "此 ROM 未能直接定位到「無線偵錯」頁，請在清單中手動點擊「無線偵錯」。",
        "phone.open.failedTitle": "開啟設定失敗",
        "phone.open.noDevice": "未偵測到已連線的裝置。請先用 USB 線或無線連接手機，再試一次。",
        "phone.open.failedBody": "無法在手機上開啟設定頁。\n請確認手機已解鎖並允許 USB 偵錯，或改用終端機 TUI 排查。",

        // ---- 恢復無線連線（協議 RESULT / ENDPOINT / VIA / ERROR）----
        "recover.failed.body": "無法恢復無線連線。\n\n可能原因與處理：\n  1) 手機重新開機過 → tcpip 模式已失效，需插一次 USB（守護會自動恢復）\n  2) 手機未連 Wi-Fi，或與 Mac 不在同一網段\n  3) 手機改回 USB 模式了 → 插 USB 後會自動切換",

        // ---- 更新失敗原因 ----
        "update.err.download": "下載失敗，請檢查網路後重試",
        "update.err.downloadDetail": "下載失敗：%@",
        "update.err.tempDir": "無法建立臨時目錄：%@",
        "update.err.package": "安裝包內容異常",
        "update.err.packageDetail": "安裝包解壓縮失敗：%@",
        "update.err.signature": "簽章驗證失敗：%@",
        "update.err.unknown": "未知原因",
        "about.alpha.errNoVersion": "未取得版本號",

        "log.empty": "（暫無日誌）",
        "tui.missing.title": "找不到 TUI 入口",
        "tui.missing.body": "未找到：%@\n請確認腳本目錄完整（應包含 adbwifi 與 bin/adbwifi-tui.py）。",

        // ---- 診斷結論（key 由腳本的 DIAG_CODE 拼接：diag.<CODE>.title / .hint）----
        "diag.DAEMON_DOWN_NO_DEVICE.title": "守護進程未執行且無裝置連線",
        "diag.DAEMON_DOWN_NO_DEVICE.hint": "點擊「啟動守護」開始自動連線",
        "diag.CONNECTED_MDNS.title": "連線正常",
        "diag.CONNECTED_MDNS.hint": "mDNS 自動發現可用",
        "diag.CONNECTED_VIA_TCPIP_USB.title": "裝置已連線（USB 自動轉 TCP）",
        "diag.CONNECTED_VIA_TCPIP_USB.hint": "TCP 連接埠 %@ 已開啟，可安全拔掉 USB",
        "diag.CONNECTED_VIA_TCPIP_WIRELESS.title": "裝置已連線（無線 %@ 連接埠）",
        "diag.CONNECTED_VIA_TCPIP_WIRELESS.hint": "USB 已拔出，無線連線獨立保持正常",
        "diag.CONNECTED_VIA_KNOWN.title": "裝置已連線（mDNS 被封鎖）",
        "diag.CONNECTED_VIA_KNOWN.hint": "靠記憶端點維持，連接埠變化後需重連",
        "diag.DEV_OPTIONS_OFF.title": "手機「開發人員選項」未開啟",
        "diag.DEV_OPTIONS_OFF.hint": "插著 USB，可在手機上自動開啟設定頁",
        "diag.USB_AUTO_TCPIP_PENDING.title": "USB 已連接，正在自動建立無線連線",
        "diag.USB_AUTO_TCPIP_PENDING.hint": "守護將自動切換 TCP 模式（連接埠 %@），無需手動開無線偵錯",
        "diag.ADB_WIFI_OFF.title": "手機「無線偵錯」開關未開啟",
        "diag.ADB_WIFI_OFF.hint": "插著 USB，可在手機上自動開啟設定頁",
        "diag.USB_CONNECTED_NO_WIRELESS.title": "USB 已連接，尚未建立無線連線",
        "diag.USB_CONNECTED_NO_WIRELESS.hint": "正在讀取連接埠，稍候自動連線",
        "diag.NO_DEVICE_MDNS_OK.title": "未發現裝置（mDNS 正常）",
        "diag.NO_DEVICE_MDNS_OK.hint": "請確認手機已開啟無線偵錯且同一 Wi-Fi",
        "diag.NO_DEVICE_MDNS_BLOCKED.title": "未發現裝置，且此網路封鎖 mDNS",
        "diag.NO_DEVICE_MDNS_BLOCKED.hint": "插 USB 自動讀連接埠 / 手動輸入 IP:連接埠",

        // ---- 鏈路品質 ----
        // ---- 鏈路品質（多裝置）----
        "net.macbattery.line": "Mac 電量 %@%%（%@）",
        "net.macbattery.charging": "充電中",
        "net.macbattery.charged": "已充滿",
        "net.macbattery.ac": "外接電源",
        "net.macbattery.discharging": "使用電池",
        // ---- 多裝置：裝置列表與批次動作（dev.*）----
        "dev.tag.wifi": "無線",
        "dev.tag.usb": "USB",
        "dev.state.offline": "離線",
        "dev.state.unauthorized": "未授權",
        "dev.copy": "複製裝置位址",
        "dev.phone.wireless": "無線偵錯",
        "dev.phone.dev": "開發人員選項",
        "dev.phone.tip.unusable": "該裝置目前不可用（離線或未授權）",
        "dev.onDevice": "操作裝置：%@",
        "dev.all.recover": "無線斷了？恢復全部 %@ 臺",
        "dev.all.recover.tip": "會逐臺檢查每支手機：還在線的跳過，斷線的嘗試重新連上；接著 USB 的會自動轉為無線",
        "dev.all.recover.title": "全部裝置重新連線結果",
        "dev.all.recover.body": "成功 %@ 臺 / 失敗 %@ 臺",
        "dev.all.recover.already": "已線上",
        "dev.all.recover.recovered": "已恢復 %@（%@）",
        "dev.all.recover.failed": "恢復失敗",
        "dev.all.recover.flash": "成功 %@ 臺 / 失敗 %@ 臺",
        "dev.usb.tcpip.flash": "成功 %@ 臺 / 失敗 %@ 臺",
        "open.result.opened": "已開啟",
        "open.result.partial": "已到開發人員選項，請手動點「無線偵錯」",
        "open.result.need_usb": "需要 USB 連線",
        "open.result.no_device": "裝置不可用",
        "open.result.failed": "開啟失敗",
        "more.header": "更多資訊",
        "env.rate.line": "↓ %@   ↑ %@",
        "dev.reconnect": "只重新連線這臺",
        "dev.reconnect.tip": "只處理這一臺，不影響其他手機。用它之前連過的位址重試；位址變了就改用上面那條「恢復全部」",
        "dev.reconnect.flash": "正在重新連線…",
        "dev.reconnect.failed.body": "無法恢復 %@ 的無線連線。\n\n可能原因：\n  1) 手機重新開機過，tcpip 模式已失效 → 插一次 USB（守護會自動恢復）\n  2) 手機未連 Wi-Fi，或與 Mac 不在同一網段\n  3) 手機 IP 變了 → 交給「全部裝置 → 逐臺重新連線」找回",
        // ---- 主選單頂部狀態區（status.*）----
        "status.sep": " + ",
        "status.countWifi": "無線 %@ 臺",
        "status.countUsb": "USB %@ 臺",
        "status.connected": "已連線 %@",
        "status.badDevices": "（%@ 臺不可用）",
        "status.noDevice": "未連線任何裝置",
        "status.daemonDown": "守護未執行，目前無裝置",
        "status.daemonOffSuffix": "· 守護未執行",
        "status.note.usbCanUnplug": "USB 已可拔線",
        "status.note.usbCanUnplug.tip": "無線連線已獨立建立，拔掉資料線不影響偵錯",
        "status.note.tcpPending": "正在切換 TCP 模式，無需手動操作",
        "status.note.tcpPending.tip": "守護會自動執行 adb tcpip 並連線，稍候即可拔線",
        "status.note.mdnsBlocked": "此網路封鎖 mDNS",
        "status.note.mdnsBlocked.tip": "新裝置無法自動發現，換 IP 後可能斷線，需要手動連線或插一次 USB",
        // ---- 鏈路指標：單位 / 分級 / 演算法說明（net.*）----
        "net.rtt.tip": "計算方式：Mac 對手機 IP 執行 ping -c 12，取平均往返時間。\n\n評價標準（區域網路）：<20 ms 優異｜20–50 ms 一般｜>50 ms 較差。\n\n注意：若「本次取樣區間」跨度很大（如 5~225 ms），說明該 Wi-Fi 本身延遲抖動嚴重（常見於 AP 負載高、節能、Mesh 中繼），此時均值只能看趨勢。\n\n影響：adb 採用區塊級應答協定，每個封包都要等確認。",
        "net.rtt.range": "本次取樣區間：%@ ~ %@ ms（抖動幅度）",
        "net.signal.tip": "計算方式：讀取手機 dumpsys wifi 上報的 RSSI（接收訊號強度，單位 dBm）。\n\n評價標準：>-50 極佳｜-50~-60 優異｜-60~-70 良好｜-70~-80 偏弱｜<-80 很差。\n\n影響：訊號越弱，Wi-Fi 調變檔位越低、重傳越多，直接壓低協商速率。",
        "net.signal.mac": "Mac 端訊號：%@ dBm（對比用，兩端越接近越好）",
        "net.ap.line": "AP %@ · 頻道 %@ · %@ MHz · BSSID %@",
        "net.ap.tip": "BSSID：%@\nMac 所在頻道：%@\n\n說明：同一 SSID 下 BSSID 不同 = 連了不同的 AP。兩端 BSSID 不一致時會跨 AP 轉發，RTT 會明顯抬高。",
        "net.usb.line": "USB 直連（不經過 Wi-Fi）",
        "net.usb.tip": "USB 裝置走本地匯流排，沒有網路往返延遲，也不受訊號和頻道影響，通常比無線的 adb 更快更穩。",
        "net.battery.line": "手機電量 %@%%（%@）",
        "net.battery.lineNoCharge": "手機電量 %@%%",
        "net.battery.charging": "充電中",
        "net.battery.tip": "計算方式：讀取手機 dumpsys battery 的 level 與 status。\n\n影響：電量低於 15% 時系統會主動限制 Wi-Fi 與背景傳輸效能，延遲與速率波動會變大。",
        // ---- adb 吞吐量：可用空間 / 平均 / 最大（net.tp.*）----
        "net.tp.negligible": "<0.1",
        // ---- adb 吞吐量：上限 / 平均 / 最大 + 評級（net.tp.*）----
        "net.tp.tip": "adb 傳輸速度的三個數字：\n\n【上限】%@ Mbps × 60% ≈ %@ MB/s\n手機和路由器握手時定下的最高速率，打六折才是實際能用的。它代表這臺裝置理論上最快能到多少。\n\n【平均】最近 10 分鐘內有傳輸時的平均速度。\n\n【最大】同期峰值，決定傳大檔案要多久。\n\n資料來源：Mac 端統計的 adb 連線流量，不含其他 App。",
        "net.tp.tip.usage": "評級依據：最大值 ÷ 上限 = %@%%。\n\n≥30%% 良好：鏈路健康。\n10–30%% 一般：還有提升空間，通常是延遲或頻道干擾。\n<10%% 偏低：瓶頸不在頻寬。adb 是區塊級應答協定，每個封包都要等一個 RTT——若 RTT >50 ms，速度會被壓到 1–3 MB/s，此時應縮短延遲而非升級 Wi-Fi。",
        // ---- 鏈路分級：等級詞 + 量表 + 分檔界線（net.*.grade.* / *.scale）----
        "net.rtt.grade.good": "優異", "net.rtt.grade.fair": "一般", "net.rtt.grade.poor": "較差",
        "net.rtt.scale": "<20 優異｜20–50 一般｜>50 較差",
        "net.signal.grade.excellent": "極佳", "net.signal.grade.good": "優異",
        "net.signal.grade.ok": "良好", "net.signal.grade.weak": "偏弱", "net.signal.grade.bad": "很差",
        "net.signal.scale": ">-50 極佳｜-50~-60 優異｜-60~-70 良好｜-70~-80 弱｜<-80 差",
        "net.tp.grade.good": "良好", "net.tp.grade.fair": "一般", "net.tp.grade.poor": "偏低",
        "net.tp.scale": "佔上限 ≥30% 良好｜10–30% 一般｜<10% 偏低",
        "net.rtt.line": "延遲 %@ ms %@ %@（%@）",
        "net.signal.line": "訊號 %@ dBm %@ %@（%@）",
        "net.tp.main": "傳輸速度 上限 %@ MB/s · 平均 %@ · 最大 %@ %@ %@（佔上限 %@%%）",
        "net.tp.idle": "傳輸速度 上限 %@ MB/s · 暫無傳輸（%@）",
        // ---- 鏈路品質手動刷新 ----
        "net.refresh": "重新測一次速度",
        "net.refresh.tip": "跳過 60 秒快取，重新採集延遲 / 訊號 / 吞吐 / 電量（約 3 秒）",
        "net.refresh.flash": "正在刷新鏈路品質…",
        "net.refresh.flash.tip": "重新採集中，約需 3 秒",
        "net.refresh.done": "鏈路品質已刷新",
        "net.refresh.done.tip": "資料已更新",
        "net.refresh.failed": "刷新失敗",
        "net.refresh.failed.tip": "裝置可能無回應，請稍後重試或按「逐臺重新連線」",
        "net.age.line": "資料是 %@前的",
        "net.age.sec": "%@ 秒",
        "net.age.min": "%@ 分鐘",
        "dev.all.recoverOne": "無線斷了？點這裡恢復",
        "status.note.mdnsOK": "mDNS 正常，新裝置可自動發現",
        "status.note.mdnsOK.tip": "手機開啟無線偵錯後，會自動被發現並連上，無需手動輸入位址。",
        "status.note.mdnsStalled": "mDNS 曾卡住，已自動重啟恢復",
        "status.note.mdnsStalled.tip": "adb 背景服務的 mDNS 模組偶爾會失效（不是網路問題）。工具已自動重啟 adb 並恢復，無需處理。",
        "status.note.mdnsFlaky": "mDNS 暫時沒回應，正在重試",
        "status.note.mdnsFlaky.tip": "可能是網路瞬時抖動。連續多輪為空才會判定為封鎖，屆時工具會自動重啟一次 adb 再確認。",
        "dev.ap.same": "🔗",
        "dev.ap.maybe": "🔗",
        "dev.ap.different": "⚠",
        "dev.ap.same.tip": "🔗 表示手機和這臺電腦接在同一個 AP 下，互傳不經過其他節點，延遲最低。",
        "dev.ap.maybe.tip": "🔗 表示頻道相同，大概率接在同一個 AP 下。",
        "dev.ap.different.tip": "⚠ 表示手機和這臺電腦不在同一個 AP 下，流量要經路由器轉發，延遲會明顯變高。",
    ]

    private static let en: [String: String] = [
        "app.name": "ADB WiFi",
        "app.tooltip": "ADB WiFi",

        "daemon.running": "● Daemon running",
        "daemon.stopped": "○ Daemon stopped",
        "daemon.mode.launchd": "auto-start",
        "daemon.mode.manual": "manual",
        "daemon.modeFormat": " (%@)",
        "env.discovery.sep": ", ",
        "device.none": "  No wireless device connected",
        "device.copyTip": "Click to copy",
        "diag.actionPrefix": "  ▸ Fix: ",

        "env.mdns": "mDNS: ",
        "env.mdns.ok": "available",
        "env.mdns.blocked": "blocked",
        "env.usb": "USB: ",
        "env.usb.connected": "connected",
        "env.usb.disconnected": "not connected",
        "env.tcp": "TCP mode: ",
        "env.tcp.on": "enabled (port %@)",
        "env.tcp.pending": "preparing (USB plugged in, switching soon)",
        "env.tcp.off": "not on yet (plug in USB to enable it)",
        "env.tcp.autoOff": "auto-switch off",
        "env.discovery": "Discovery: ",
        "env.discovery.usb": "USB",
        "env.discovery.known": "remembered endpoint",
        "env.discovery.mdns": "mDNS",
        "env.discovery.none": "none",
        "env.host": "  Host: ",
        "env.rate.tip": "adb transfer rate (↓ phone→Mac, ↑ Mac→phone)",
        "env.rate.total": "  Total: down %@ MB / up %@ MB",

        "menu.stopDaemon": "Stop daemon",
        "menu.startDaemon": "Start daemon",
        "menu.enableTcpip": "Enable TCP mode now (no manual toggle)",
        "menu.enableTcpip.tip": "Run adb tcpip %@ over USB, then connect wirelessly",
        "menu.adbDevices": "Open adb devices",
        "menu.phoneWireless": "Open \"Wireless debugging\" on phone…",
        "menu.phoneDev": "Open \"Developer options\" on phone…",
        "menu.phone.tip.connected": "Jump straight to the wireless debugging toggle",
        "menu.phone.tip.dev": "Open the developer options page",
        "menu.viewLog": "View log…",
        "menu.openTUI": "Open Terminal TUI…",
        "menu.openTUI.tip": "Open the interactive terminal UI (clickable repair actions)",
        "menu.settings": "Settings",
        "menu.language": "Language",
        "menu.about": "About ADB WiFi",
        "menu.quit": "Quit menu bar (daemon keeps running)",

        "lang.system": "Follow System",
        "lang.zhHans": "简体中文",
        "lang.zhHant": "繁體中文",
        "lang.en": "English",

        "about.title": "About ADB WiFi",
        "about.version": "Version %@",
        "about.buildSuffix": " (build %@)",
        "about.desc": "Android wireless-debugging daemon in your menu bar\nConnection status, transfer rate and one-click recovery.",
        "about.check": "Check for Stable Updates",
        "about.checkTip": "Check stable releases only (recommended)",
        "about.checking": "Checking…",
        "about.upToDate": "Up to date, click to recheck",
        "about.checkFailed": "Check failed, click to retry",
        "about.downloadInstall": "Download & Install %@",
        "about.installing": "Installing…",
        "about.alpha.prefix": "Pre-release: ",
        "about.alpha.idle": "Alpha preview",
        "about.alpha.checking": "Alpha checking…",
        "about.alpha.upToDate": "Alpha up to date, click to recheck",
        "about.alpha.notFound": "No Alpha releases, click to recheck",
        "about.alpha.failed": "Alpha check failed, click to retry",
        "about.alpha.download": "Download & Install Alpha %@",
        "about.alpha.installing": "Downloading and installing…",
        "about.alpha.installingTag": "Downloading and installing Alpha %@…",
        "about.installFailed": "Update failed, click to retry",
        "about.tip.upToDate": "Up to date (%@)",
        "about.tip.updateAvailable": "%@ → %@ available",
        "about.tip.installing": "Downloading and installing %@, the app will relaunch",
        "about.tip.failed": "Check failed: %@",
        "about.alpha.available": "Alpha %@ available (use the button above)",
        "about.alpha.tip.available": "Use the button above to install Alpha %@",
        "about.alpha.installFailed": "Alpha update failed, click to retry",
        "about.alpha.tip": "Pre-release: newest features, may be unstable",
        "about.alpha.tip.download": "Downloads and installs automatically, then relaunches",
        "about.alpha.tip.upToDate": "Latest Alpha: %@",
        "about.alpha.tip.notFound": "No pre-release versions published",
        "about.link.home": "Project Home",
        "about.link.issues": "Report an Issue",
        "about.link.releases": "Releases",
        "about.close": "Close",

        "about.status.checking": "Checking stable updates…",
        "about.status.upToDate": "Up to date (%@)",
        "about.status.updateAvailable": "%@ → %@ available, click the button above",
        "about.status.failed": "Check failed: %@, click to retry",
        "about.status.noStable": "No stable release yet, click to retry",
        "about.status.noVersion": "Check failed: no version returned, click to retry",
        "about.status.downloading": "Downloading %@…",
        "about.status.installing": "Installing, the app will relaunch…",
        "about.status.updateFailed": "Update failed: %@, click to retry",
        "about.status.updateLauncherFailed": "Update failed: cannot start updater (%@)",

        "action.usb_help": "Plug in USB to read the port",
        "action.manual_connect": "Enter IP:port to connect",
        "action.phone_dev_settings": "Open Developer options on phone",
        "action.phone_wireless": "Open Wireless debugging on phone",
        "action.reconnect_now": "Run diagnostics again",
        "action.start_daemon": "Start daemon",

        "flash.daemon": "Daemon",
        "flash.stopped": "Daemon stopped",
        "flash.started": "Daemon started",
        "flash.copied": "Copied",
        "flash.recovered": "Restored",
        "flash.reconnect": "Re-check",
        "flash.refreshed": "Refreshed",
        "flash.tcpOn": "TCP mode enabled",
        "flash.tcpFail": "TCP mode failed",
        "flash.opened": "Opened",
        "flash.checkPhone": "Check your phone",
        "flash.manualWireless": "Tap Wireless debugging manually",
        "flash.openFailed": "Failed to open",
        "flash.connectFirst": "Connect a phone first",
        "phone.openTitle": "Open \"%@\" on phone",
        "usb.none.title": "No USB device detected",
        "recover.failed.title": "Could not restore wireless connection",
        "phone.wireless": "Wireless debugging",
        "phone.dev": "Developer options",
        "log.title": "adb-wifi log",

        // ---- errors / notices ----
        "err.scriptFailed": "Cannot run script: %@",
        "err.timeout": "Timed out",
        "err.noStatus": "Cannot read device status",
        "err.noWifiIP": "Switched to TCP mode but no phone Wi-Fi IP was found",
        "err.noRelease": "No release published yet, open the releases page manually.",
        "err.badURL": "Invalid URL",
        "err.noResponse": "No response from server",
        "err.http": "GitHub returned HTTP %d",

        // ---- help dialogs ----
        "help.usb.title": "Read the port over USB",
        "help.usb.body": """
        Plugging in a USB cable restores the connection automatically.

        Steps:
        1. Connect the phone to this Mac with a data cable
        2. Tap "Allow USB debugging" on the phone
        3. The menu refreshes and reads the phone's real port

        Why: the wireless debugging port is random on every start.
        Reading it over USB is immune to network filtering and
        therefore the most reliable path.
        """,
        "help.manual.title": "Manual connect (command copied)",
        "help.manual.cmd": "adb connect <IP>:<PORT>",
        "help.manual.body": """
        First read the address on the phone:
          Settings → Developer options → Wireless debugging → IP:PORT at the top

        Then run this in Terminal (the menu bar cannot take input,
        paste the command below and fill in your values):
          %@

        Or use the terminal TUI instead (recommended, clickable):
          cd ~/mycode/adb-wifi-manager && ./adbwifi

        Tip: a successful endpoint is remembered and reconnected later.
        """,
        "help.tui.title": "Further action needed",
        "help.tui.body": """
        Open the terminal TUI for the full walkthrough (clickable):
          cd ~/mycode/adb-wifi-manager && ./adbwifi
        """,
        "usb.none.body": "Connect the phone with a USB cable and allow USB debugging,\nthen click this menu item again.",

        // ---- phone settings jump (protocol RESULT / PAGE / WIFI_TOGGLE) ----
        "phone.open.body": "Opened \"%@\" on the phone.",
        "phone.open.toggleOff": "The wireless debugging toggle is off. Turn it on in the phone.",
        "phone.open.toggleUnknown": "This ROM may not expose the toggle state. Please confirm on the phone.",
        "phone.open.partialTitle": "Developer options opened",
        "phone.open.partial": "This ROM could not jump straight to wireless debugging. Tap \"Wireless debugging\" in the list.",
        "phone.open.failedTitle": "Could not open settings",
        "phone.open.noDevice": "No connected device found. Connect the phone over USB or Wi-Fi and try again.",
        "phone.open.failedBody": "Could not open the settings page on the phone.\nMake sure the phone is unlocked and USB debugging is allowed, or use the terminal TUI.",

        // ---- connection recovery (protocol RESULT / ENDPOINT / VIA / ERROR) ----
        "recover.failed.body": "Could not restore the wireless connection.\n\nPossible causes:\n  1) The phone rebooted → tcpip mode is gone, plug in USB once (the daemon restores it)\n  2) The phone is not on Wi-Fi, or on a different subnet than this Mac\n  3) The phone fell back to USB mode → plugging in USB switches it back",

        // ---- update failure reasons ----
        "update.err.download": "Download failed. Check your network and retry.",
        "update.err.downloadDetail": "Download failed: %@",
        "update.err.tempDir": "Cannot create temp directory: %@",
        "update.err.package": "Unexpected contents in the package",
        "update.err.packageDetail": "Failed to unpack the package: %@",
        "update.err.signature": "Signature verification failed: %@",
        "update.err.unknown": "unknown reason",
        "about.alpha.errNoVersion": "No version number returned",

        "log.empty": "(no log yet)",
        "tui.missing.title": "TUI entry not found",
        "tui.missing.body": "Not found: %@\nMake sure the install directory contains adbwifi and bin/adbwifi-tui.py.",

        // ---- diagnostics (key = diag.<DIAG_CODE>.title / .hint) ----
        "diag.DAEMON_DOWN_NO_DEVICE.title": "Daemon not running and no device connected",
        "diag.DAEMON_DOWN_NO_DEVICE.hint": "Click \"Start daemon\" to connect automatically",
        "diag.CONNECTED_MDNS.title": "Connected",
        "diag.CONNECTED_MDNS.hint": "mDNS auto-discovery is available",
        "diag.CONNECTED_VIA_TCPIP_USB.title": "Connected (USB auto-switched to TCP)",
        "diag.CONNECTED_VIA_TCPIP_USB.hint": "TCP port %@ is open, you can unplug USB safely",
        "diag.CONNECTED_VIA_TCPIP_WIRELESS.title": "Connected (wireless, port %@)",
        "diag.CONNECTED_VIA_TCPIP_WIRELESS.hint": "USB unplugged, the wireless link stands on its own",
        "diag.CONNECTED_VIA_KNOWN.title": "Connected (mDNS blocked)",
        "diag.CONNECTED_VIA_KNOWN.hint": "Kept alive by a remembered endpoint; reconnect if the port changes",
        "diag.DEV_OPTIONS_OFF.title": "Developer options are off on the phone",
        "diag.DEV_OPTIONS_OFF.hint": "USB is plugged in, the settings page can be opened on the phone",
        "diag.USB_AUTO_TCPIP_PENDING.title": "USB connected, establishing wireless link",
        "diag.USB_AUTO_TCPIP_PENDING.hint": "The daemon switches to TCP mode (port %@) automatically, no manual toggle needed",
        "diag.ADB_WIFI_OFF.title": "Wireless debugging is off on the phone",
        "diag.ADB_WIFI_OFF.hint": "USB is plugged in, the settings page can be opened on the phone",
        "diag.USB_CONNECTED_NO_WIRELESS.title": "USB connected, no wireless link yet",
        "diag.USB_CONNECTED_NO_WIRELESS.hint": "Reading the port, connecting shortly",
        "diag.NO_DEVICE_MDNS_OK.title": "No device found (mDNS works)",
        "diag.NO_DEVICE_MDNS_OK.hint": "Make sure wireless debugging is on and both devices share the same Wi-Fi",
        "diag.NO_DEVICE_MDNS_BLOCKED.title": "No device found and this network blocks mDNS",
        "diag.NO_DEVICE_MDNS_BLOCKED.hint": "Plug in USB to read the port, or enter IP:PORT manually",

        // ---- link quality ----
        // ---- link quality (multi-device) ----
        "net.macbattery.line": "Mac battery %@%% (%@)",
        "net.macbattery.charging": "charging",
        "net.macbattery.charged": "charged",
        "net.macbattery.ac": "AC power",
        "net.macbattery.discharging": "on battery",
        // ---- Multi-device: device list & batch actions (dev.*) ----
        "dev.tag.wifi": "Wi-Fi",
        "dev.tag.usb": "USB",
        "dev.state.offline": "offline",
        "dev.state.unauthorized": "unauthorized",
        "dev.copy": "Copy device address",
        "dev.phone.wireless": "Wireless debugging",
        "dev.phone.dev": "Developer options",
        "dev.phone.tip.unusable": "This device is unavailable (offline or unauthorized)",
        "dev.onDevice": "Device: %@",
        "dev.all.recover": "Wireless dropped? Restore all %@",
        "dev.all.recover.tip": "Checks each phone in turn: online ones are skipped, dropped ones are reconnected; USB devices are switched to wireless automatically",
        "dev.all.recover.title": "Reconnect results",
        "dev.all.recover.body": "%@ succeeded / %@ failed",
        "dev.all.recover.already": "online",
        "dev.all.recover.recovered": "restored %@ (%@)",
        "dev.all.recover.failed": "failed",
        "dev.all.recover.flash": "%@ succeeded / %@ failed",
        "dev.usb.tcpip.flash": "%@ succeeded / %@ failed",
        "open.result.opened": "opened",
        "open.result.partial": "reached Developer options, tap Wireless debugging manually",
        "open.result.need_usb": "needs USB",
        "open.result.no_device": "device unavailable",
        "open.result.failed": "failed to open",
        "more.header": "More info",
        "env.rate.line": "↓ %@   ↑ %@",
        "dev.reconnect": "Reconnect just this one",
        "dev.reconnect.tip": "Affects only this phone. Retries the address it used before; if the address changed, use \"Restore all\" above instead",
        "dev.reconnect.flash": "Reconnecting…",
        "dev.reconnect.failed.body": "Could not restore the wireless connection for %@.\n\nPossible causes:\n  1) Phone rebooted, tcpip mode lost → plug in USB once\n  2) Phone not on Wi-Fi, or on a different subnet\n  3) Phone IP changed → use “All devices → Reconnect each device”",
        // ---- Top status area (status.*) ----
        "status.sep": " + ",
        "status.countWifi": "%@ Wi-Fi",
        "status.countUsb": "%@ USB",
        "status.connected": "Connected: %@",
        "status.badDevices": " (%@ unavailable)",
        "status.noDevice": "No device connected",
        "status.daemonDown": "Daemon not running, no device",
        "status.daemonOffSuffix": "· daemon off",
        "status.note.usbCanUnplug": "USB cable can be unplugged",
        "status.note.usbCanUnplug.tip": "The wireless link is up on its own; unplugging won't affect debugging",
        "status.note.tcpPending": "Switching to TCP mode, no action needed",
        "status.note.tcpPending.tip": "The daemon runs adb tcpip and connects automatically",
        "status.note.mdnsBlocked": "mDNS blocked on this network",
        "status.note.mdnsBlocked.tip": "New devices can't be auto-discovered; you may lose the link if the IP changes",
        // ---- Link metrics: units / grades / method (net.*) ----
        "net.rtt.tip": "Method: Mac runs ping -c 12 against the phone IP and takes the average round trip.\n\nScale (LAN): <20 ms good | 20–50 ms fair | >50 ms poor.\n\nNote: a very wide sample range (e.g. 5–225 ms) means the Wi-Fi itself jitters heavily (busy AP, power saving, mesh relaying); the average is then only a trend.\n\nImpact: adb is block-level request/response, so higher RTT caps throughput.",
        "net.rtt.range": "Sample range: %@ ~ %@ ms (jitter)",
        "net.signal.tip": "Method: reads the signal strength (dBm) reported by the phone.\n\nScale: >-50 excellent | -50~-60 good | -60~-70 ok | -70~-80 weak | <-80 very weak.\n\nImpact: a weaker signal lowers the connection tier and increases retransmissions, which directly caps the top speed.",
        "net.signal.mac": "Mac-side signal: %@ dBm (for comparison)",
        "net.ap.line": "AP %@ · channel %@ · %@ MHz · BSSID %@",
        "net.ap.tip": "BSSID: %@\nMac channel: %@\n\nNote: same SSID with different BSSID means different APs; cross-AP forwarding raises RTT noticeably.",
        "net.usb.line": "Direct USB (not over Wi-Fi)",
        "net.usb.tip": "USB devices use the local bus: no network round-trip, no signal or channel effects — usually faster and steadier than wireless adb.",
        "net.battery.line": "Phone battery %@%% (%@)",
        "net.battery.lineNoCharge": "Phone battery %@%%",
        "net.battery.charging": "charging",
        "net.battery.tip": "Method: reads level and status from the phone's dumpsys battery.\n\nImpact: below 15% the system throttles Wi-Fi and background transfers, increasing latency and rate jitter.",
        // ---- adb throughput: ceiling / average / peak (net.tp.*) ----
        "net.tp.negligible": "<0.1",
        // ---- adb throughput: ceiling / avg / peak + grade (net.tp.*) ----
        "net.tp.tip": "Three numbers for adb transfer speed:\n\n[Ceiling] %@ Mbps × 60% ≈ %@ MB/s\nThe top rate the phone and router agreed on, discounted to 60% because the real usable figure is lower (shared airtime plus protocol overhead). It is the theoretical best for this device.\n\n[Average] Mean speed while transferring in the last 10 minutes — the typical day-to-day figure.\n\n[Peak] Highest sample in the same window — drives how long large transfers take.\n\nSource: adb traffic measured on the Mac, excluding other apps.",
        "net.tp.tip.usage": "Grade basis: peak ÷ ceiling = %@%%.\n\n≥30%% good: healthy connection, speed is being used.\n10–30%% fair: room to improve, usually high latency or interference.\n<10%% low: the bottleneck is not raw bandwidth. adb waits for an acknowledgement per block, so high latency caps the speed — above 50 ms you may only reach 1–3 MB/s. Move closer to the router, use 5 GHz, and avoid cross-AP hops rather than buying faster Wi-Fi.",
        // ---- Link grading: label + meter + thresholds (net.*.grade.* / *.scale) ----
        "net.rtt.grade.good": "good", "net.rtt.grade.fair": "fair", "net.rtt.grade.poor": "poor",
        "net.rtt.scale": "<20 good | 20–50 fair | >50 poor",
        "net.signal.grade.excellent": "excellent", "net.signal.grade.good": "good",
        "net.signal.grade.ok": "ok", "net.signal.grade.weak": "weak", "net.signal.grade.bad": "bad",
        "net.signal.scale": ">-50 excellent | -50~-60 good | -60~-70 ok | -70~-80 weak | <-80 bad",
        "net.tp.grade.good": "good", "net.tp.grade.fair": "fair", "net.tp.grade.poor": "low",
        "net.tp.scale": "≥30% of ceiling good | 10–30% fair | <10% low",
        "net.rtt.line": "Latency %@ ms %@ %@ (%@)",
        "net.signal.line": "Signal %@ dBm %@ %@ (%@)",
        "net.tp.main": "Transfer speed ceiling %@ MB/s · avg %@ · peak %@ %@ %@ (%@%% of ceiling)",
        "net.tp.idle": "Transfer speed ceiling %@ MB/s · no traffic (%@)",
        // ---- Manual link-quality refresh ----
        "net.refresh": "Measure speed again",
        "net.refresh.tip": "Skip the 60 s cache and re-sample latency / signal / throughput / battery (~3 s)",
        "net.refresh.flash": "Refreshing link quality…",
        "net.refresh.flash.tip": "Re-sampling, about 3 s",
        "net.refresh.done": "Link quality refreshed",
        "net.refresh.done.tip": "Data updated",
        "net.refresh.failed": "Refresh failed",
        "net.refresh.failed.tip": "Device may not respond; retry later or use Reconnect",
        "net.age.line": "Data from %@ ago",
        "net.age.sec": "%@ s",
        "net.age.min": "%@ min",
        "dev.all.recoverOne": "Wireless dropped? Restore it",
        "status.note.mdnsOK": "mDNS OK, new devices auto-discovered",
        "status.note.mdnsOK.tip": "Phones with wireless debugging on are found and connected automatically — no manual address entry.",
        "status.note.mdnsStalled": "mDNS stalled earlier, auto-restarted",
        "status.note.mdnsStalled.tip": "ADB's mDNS module occasionally drops out (not a network issue). The tool restarted adb and recovered it — no action needed.",
        "status.note.mdnsFlaky": "mDNS not responding, retrying",
        "status.note.mdnsFlaky.tip": "Possibly a brief network hiccup. Only persistent emptiness is treated as blocked, at which point the tool restarts adb once to confirm.",
        "dev.ap.same": "🔗",
        "dev.ap.maybe": "🔗",
        "dev.ap.different": "⚠",
        "dev.ap.same.tip": "🔗 means the phone and this Mac are on the same AP — direct path, lowest latency.",
        "dev.ap.maybe.tip": "🔗 means same channel — most likely the same AP.",
        "dev.ap.different.tip": "⚠ means the phone and this Mac are on different APs — traffic is forwarded by the router, raising latency.",
    ]
}
