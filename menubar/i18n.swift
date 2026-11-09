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
        "env.tcp": "TCP 模式：",
        "env.tcp.on": "已开启（端口 %@）",
        "env.tcp.pending": "待开启（插着 USB，稍候自动切换）",
        "env.tcp.off": "未开启（插 USB 可自动开启）",
        "env.tcp.autoOff": "已关闭（AUTO_TCPIP=0）",
        "env.discovery": "发现方式：",
        "env.discovery.usb": "USB 读取",
        "env.discovery.known": "记忆端点",
        "env.discovery.mdns": "mDNS",
        "env.discovery.none": "无",
        "env.host": "  本机：",
        "env.phone": "  手机：",
        "env.rate.tip": "adb 传输速率（↓ 手机→Mac，↑ Mac→手机）",
        "env.rate.total": "  累计：收 %@ MB / 发 %@ MB",

        "menu.stopDaemon": "停止守护服务",
        "menu.startDaemon": "启动守护服务",
        "menu.recover": "立即恢复无线连接（无需 USB）",
        "menu.reconnect": "重新连接一次",
        "menu.recover.tip.none": "无需 USB：自动查找并连接手机",
        "menu.recover.tip.has": "断开后按记忆端点/网段扫描重新连接",
        "menu.enableTcpip": "立即开启 TCP 模式（免手动开无线调试）",
        "menu.enableTcpip.tip": "通过 USB 执行 adb tcpip %@，之后即可无线连接",
        "menu.adbDevices": "打开 adb devices",
        "menu.phoneWireless": "在手机上打开「无线调试」…",
        "menu.phoneDev": "在手机上打开「开发者选项」…",
        "menu.phone.tip.connected": "直接在手机上定位到无线调试开关",
        "menu.phone.tip.dev": "打开开发者选项页",
        "menu.phone.tip.disconnected": "请先连接手机",
        "menu.viewLog": "查看日志…",
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
        "about.alpha.download": "下载 Alpha %@",
        "about.alpha.tip": "预发布版本：功能最新，但可能不稳定",
        "about.alpha.tip.download": "打开 Alpha 版本下载页",
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
        "env.tcp": "TCP 模式：",
        "env.tcp.on": "已開啟（連接埠 %@）",
        "env.tcp.pending": "待開啟（插著 USB，稍候自動切換）",
        "env.tcp.off": "未開啟（插 USB 可自動開啟）",
        "env.tcp.autoOff": "已關閉（AUTO_TCPIP=0）",
        "env.discovery": "發現方式：",
        "env.discovery.usb": "USB 讀取",
        "env.discovery.known": "記憶端點",
        "env.discovery.mdns": "mDNS",
        "env.discovery.none": "無",
        "env.host": "  本機：",
        "env.phone": "  手機：",
        "env.rate.tip": "adb 傳輸速率（↓ 手機→Mac，↑ Mac→手機）",
        "env.rate.total": "  累計：收 %@ MB / 發 %@ MB",

        "menu.stopDaemon": "停止守護服務",
        "menu.startDaemon": "啟動守護服務",
        "menu.recover": "立即恢復無線連線（無需 USB）",
        "menu.reconnect": "重新連線一次",
        "menu.recover.tip.none": "無需 USB：自動尋找並連線手機",
        "menu.recover.tip.has": "斷線後按記憶端點/網段掃描重新連線",
        "menu.enableTcpip": "立即開啟 TCP 模式（免手動開無線偵錯）",
        "menu.enableTcpip.tip": "透過 USB 執行 adb tcpip %@，之後即可無線連線",
        "menu.adbDevices": "開啟 adb devices",
        "menu.phoneWireless": "在手機上開啟「無線偵錯」…",
        "menu.phoneDev": "在手機上開啟「開發人員選項」…",
        "menu.phone.tip.connected": "直接定位到手機的無線偵錯開關",
        "menu.phone.tip.dev": "開啟開發人員選項頁面",
        "menu.phone.tip.disconnected": "請先連接手機",
        "menu.viewLog": "查看日誌…",
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
        "about.alpha.download": "下載 Alpha %@",
        "about.alpha.tip": "預發布版本：功能最新，但可能不穩定",
        "about.alpha.tip.download": "開啟 Alpha 版本下載頁",
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
        "env.tcp.pending": "pending (USB connected, switching soon)",
        "env.tcp.off": "disabled (plug in USB to enable)",
        "env.tcp.autoOff": "disabled (AUTO_TCPIP=0)",
        "env.discovery": "Discovery: ",
        "env.discovery.usb": "USB",
        "env.discovery.known": "remembered endpoint",
        "env.discovery.mdns": "mDNS",
        "env.discovery.none": "none",
        "env.host": "  Host: ",
        "env.phone": "  Phone: ",
        "env.rate.tip": "adb transfer rate (↓ phone→Mac, ↑ Mac→phone)",
        "env.rate.total": "  Total: down %@ MB / up %@ MB",

        "menu.stopDaemon": "Stop daemon",
        "menu.startDaemon": "Start daemon",
        "menu.recover": "Restore wireless connection (no USB)",
        "menu.reconnect": "Reconnect once",
        "menu.recover.tip.none": "No USB needed: find and connect automatically",
        "menu.recover.tip.has": "Rescan remembered endpoints / subnet and reconnect",
        "menu.enableTcpip": "Enable TCP mode now (no manual toggle)",
        "menu.enableTcpip.tip": "Run adb tcpip %@ over USB, then connect wirelessly",
        "menu.adbDevices": "Open adb devices",
        "menu.phoneWireless": "Open \"Wireless debugging\" on phone…",
        "menu.phoneDev": "Open \"Developer options\" on phone…",
        "menu.phone.tip.connected": "Jump straight to the wireless debugging toggle",
        "menu.phone.tip.dev": "Open the developer options page",
        "menu.phone.tip.disconnected": "Connect a phone first",
        "menu.viewLog": "View log…",
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
        "about.alpha.download": "Download Alpha %@",
        "about.alpha.tip": "Pre-release: newest features, may be unstable",
        "about.alpha.tip.download": "Open the Alpha download page",
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
    ]
}
