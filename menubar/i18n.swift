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
        "about.alpha.download": "下载并安装 Alpha %@",
        "about.alpha.installing": "正在下载并安装…",
        "about.alpha.installingTag": "正在下载并安装 Alpha %@…",
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
        "recover.result.already": "当前已有可用连接：%@",
        "recover.result.alreadyNoEp": "当前已有可用连接",
        "recover.result.recovered": "已恢复无线连接：%@",
        "recover.result.recoveredNoEp": "已恢复无线连接",
        "recover.failed.tcpip": "切换到 TCP 模式后仍未连接成功。\n\n可能原因与处理：\n  1) 手机重启过 → tcpip 模式已失效，需插一次 USB\n  2) 手机未连 Wi-Fi，或与 Mac 不在同一网段\n  3) 手机改回 USB 模式了 → 插 USB 后会自动切换",
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
        "about.alpha.download": "下載並安裝 Alpha %@",
        "about.alpha.installing": "正在下載並安裝…",
        "about.alpha.installingTag": "正在下載並安裝 Alpha %@…",
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
        1. 用傳輸線把手機連到這台 Mac
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
        "recover.result.already": "目前已有可用連線：%@",
        "recover.result.alreadyNoEp": "目前已有可用連線",
        "recover.result.recovered": "已恢復無線連線：%@",
        "recover.result.recoveredNoEp": "已恢復無線連線",
        "recover.failed.tcpip": "切換到 TCP 模式後仍未連線成功。\n\n可能原因與處理：\n  1) 手機重新開機過 → tcpip 模式已失效，需插一次 USB\n  2) 手機未連 Wi-Fi，或與 Mac 不在同一網段\n  3) 手機改回 USB 模式了 → 插 USB 後會自動切換",
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
        "about.alpha.download": "Download & Install Alpha %@",
        "about.alpha.installing": "Downloading and installing…",
        "about.alpha.installingTag": "Downloading and installing Alpha %@…",
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
        "recover.result.already": "Already connected: %@",
        "recover.result.alreadyNoEp": "Already connected",
        "recover.result.recovered": "Wireless connection restored: %@",
        "recover.result.recoveredNoEp": "Wireless connection restored",
        "recover.failed.tcpip": "Switched to TCP mode but still could not connect.\n\nPossible causes:\n  1) The phone rebooted → tcpip mode is gone, plug in USB once\n  2) The phone is not on Wi-Fi, or on a different subnet than this Mac\n  3) The phone fell back to USB mode → plugging in USB switches it back",
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
    ]
}
