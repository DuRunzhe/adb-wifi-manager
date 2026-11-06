# adb-wifi-manager

Mac 上的 Android **无线调试（Wireless Debugging）自动连接守护**。

打开手机「无线调试」后，自动发现 → 自动连接 → 掉线自动重连，支持开机自启。
提供 **终端图形界面（TUI）**，所有操作点选完成，无需记忆命令。

---

## 快速开始

```bash
cd ~/mycode/adb-wifi-manager
./adbwifi                 # ★ 打开图形界面（推荐，零参数）
```

首次使用先安装（开机自启 + 菜单栏 App）：

```bash
./install.sh
```

安装后：

- 守护进程由 **launchd** 托管，登录即启动、崩溃自动重启
- 菜单栏 App 安装到 `~/Applications/AdbWifiBar.app`（可在访达双击打开，或拖入「登录项」）

---

## 终端界面（TUI）

```bash
./adbwifi
```

打开后即可看到完整状态与诊断结果，**全部操作可用鼠标点击或键盘完成**：

```
 ADB 无线调试管理器   ● 守护运行中 (开机自启)              Q 退出  R 刷新  ? 帮助
 连接状态
✓ 192.168.17.212:38075
USB: 未连接
mDNS: 被屏蔽 ✗   发现方式: 记忆端点
本机: 192.168.17.173
 ⚠ 此网络屏蔽了 mDNS 广播，无法自动发现新的无线调试设备。按 Enter 查看解决方案
─────────────────────────────────────────────────────────────────────────
 诊断与解决方案  ↑↓ 选择   Enter 查看方案
 ▶ [✓] 设备已连接（但 mDNS 不可用）
   当前连接依靠「记忆端点」维持。...
   ▸ 手动添加新端口
  [i] 当前网络屏蔽了 mDNS 组播广播
─────────────────────────────────────────────────────────────────────────
 守护 停止   重新连接   手动连接   配对设备   设备列表   日志   帮助   退出
```

### 按键

| 键 | 作用 |
|---|---|
| `↑` `↓` | 在诊断项之间移动（也可鼠标点击 / 滚轮） |
| `Enter` | 查看并执行当前诊断项的解决方案 |
| `A` | 启动 / 停止后台守护（保持开机自启） |
| `S` | 立即重新连接 |
| `C` | 手动输入 `IP:端口` 连接 |
| `P` | 配对设备（Android 11+ 首次连接） |
| `D` | 查看设备列表 |
| `L` | 查看守护日志 |
| `R` | 重新诊断 |
| `?` | 帮助 |
| `Q` | 退出界面（守护继续在后台运行） |

底部按钮栏同样**支持鼠标点击**，诊断项也可直接点击。

> 鼠标滚轮：受 macOS 自带 ncurses 限制，「滚轮向下」事件无法与鼠标移动区分，
> 因此本工具只启用滚轮**向上**。列表/日志页请用 `↑` `↓`、`PgUp` `PgDn` 翻页（体验更稳定）。

### 环境要求

- 仅需 macOS 自带的 `/usr/bin/python3`（3.9+），**零第三方依赖**
- 已针对 macOS 自带 bash 3.2 与 ncurses 的缺失常量做过兼容处理
- 终端需支持 UTF-8；若不支持会自动降级为 `--cli` 纯文本模式

---

## ⚠ 网络无法自动发现时怎么办

这是实际使用中最常见的问题。**企业 Wi-Fi 常屏蔽 mDNS 组播广播**，而 Android 无线调试正是依赖 mDNS 广播端口的，
表现就是「怎么都发现不到设备」，但实际上配置完全没错。

工具会**自动识别**这种情况，并在界面顶部显示醒目横幅。

在对应诊断项上按 `Enter`，会给出以下可执行方案：

| 方案 | 操作 | 自动化程度 |
|---|---|---|
| **① 插 USB 自动读端口** ★推荐 | 插上数据线即可，工具读取手机真实端口后自动连接 | **全自动** |
| ② 手动输入 IP:端口 | 手机上看端口，按 `C` 输入一次，之后自动重连 | 半自动（仅首次） |
| ③ 手机端跳转页面 | 插 USB 时，工具可在手机上**自动打开**开发者选项 / 无线调试页 | 半自动 |
| ④ 换网络 | 手机热点或家庭 Wi-Fi 通常不屏蔽 | 手动 |
| ⑤ 找网管 | 关闭 Wi-Fi 的客户端隔离 / 组播隔离 | 手动 |

> 此外还能**自动识别**并引导修复：开发者选项未开启、无线调试开关未打开、
> 手机与电脑不在同一网段、守护未运行等情况。

```bash
./adbwifi --cli      # 纯文本诊断（不支持 curses 的终端 / 脚本调用）
```

---

## 命令

| 命令 | 说明 |
|---|---|
| `./bin/adb-wifi.sh start` | 启动守护（幂等，重复执行无副作用） |
| `./bin/adb-wifi.sh stop` | 停止守护，并取消 launchd 开机自启 |
| `./bin/adb-wifi.sh restart` | 重启 |
| `./bin/adb-wifi.sh status` | 查看运行状态、在线设备、最近日志 |
| `./bin/adb-wifi.sh log` | 实时跟随日志（Ctrl-C 退出） |
| `./bin/adb-wifi.sh once` | 前台跑一轮发现，用于排查问题 |
| `./bin/adb-wifi.sh open` | 在手机上直接打开「无线调试」页面 |
| `./bin/adb-wifi.sh open dev` | 在手机上打开「开发者选项」页面 |

日志位置：`~/Library/Application Support/adb-wifi-manager/logs/adb-wifi.log`

---

## 自动发现原理

Android 11+ 的「无线调试」端口是**每次随机分配**的，因此脚本用三种方式互补发现，任一可用即可：

| 方式 | 说明 | 可靠性 |
|---|---|---|
| **mDNS** | `adb mdns services` 读取 `_adb-tls-connect._tcp` 广播 | 标准方式，但**很多企业 Wi-Fi / AP 会屏蔽组播** |
| **USB 读取** | 手机插着 USB 时，读取其 adbd 实际监听端口，**端口 100% 准确** | 最可靠 |
| **端点记忆** | 记录连接成功过的 `IP:PORT`，掉线后重试 | 断线重连的主力 |

> ⚠️ **实测结论**：部分企业网络（如 Inkeverse-Office）会屏蔽 mDNS 组播，
> 此时仅靠 mDNS 完全发现不到设备。脚本已针对这种情况用「USB 读取」和「端点记忆」兜底。
> 若手机**从不插 USB**，第一次连接需要手动执行一次：
> `adb connect <手机IP>:<无线调试页面显示的端口>`

### 实时事件感知

设备变化**不是靠轮询等待**，而是由 `adb track-devices` 事件流驱动，毫秒级响应：

| 变化 | 感知方式 | 实测响应 |
|---|---|---|
| 无线连接断开 | `track-devices` 推送 `offline` | **1.5 秒内自动重连** |
| 设备重新上线 / 新设备加入 | `track-devices` 推送 `device` | 立即感知 |
| 插上 USB | 事件推送 + 读取真实端口 | 立即，并自动改用 USB 读取的端口 |
| 拔掉 USB | 事件推送 | 立即 |
| Mac 网络切换 | 网段比对 | 立即重启 adb |

实现要点：

- 守护进程内常驻 `adb track-devices`，事件写入 `state/events.log`
- 主循环的等待是**可被事件唤醒**的，事件到达即刻重新诊断，无需等满轮询间隔
- TUI 只 `stat` 事件文件（几乎零开销），有变化立刻重新诊断并重绘
- 菜单栏 App 用 `DispatchSource` 监听同一事件文件，变化即刷新；定时器仅作兜底

### 自动恢复覆盖的场景

- ✅ 无线连接断开 → 事件触发即刻重连（实测 **1.5 秒内**，旧版轮询需 ~10 秒）
- ✅ `adb server` 崩溃被杀 → 自动重启服务并重连
- ✅ Mac 切换 Wi-Fi / 网段变化 → 自动重启 adb server，清理失效端点
- ✅ 设备重启后端口变化 → 有 USB 连接时自动读取新端口
- ✅ 记录中的失效端点 → 自动清理，不会堆积

---

## 菜单栏 App

`~/Applications/AdbWifiBar.app`（编译产物在 `build/AdbWifiBar.app`），图标含义：

| 状态 | 图标 |
|---|---|
| 守护已停止 | 手机带斜杠 |
| 守护运行中，无设备 | 手机 |
| 已连接设备 | 手机 + 信号 |

> 图标位于菜单栏**左侧**（输入法左边附近），可用 `⌘` + 拖动调整位置。
> 若某些 SF Symbols 在当前 macOS 不存在，会自动降级到可用图标，最终回退到文字 `ADB`。

### 图标

菜单栏图标和 App 图标**用同一个 SF Symbol**（`iphone.radiowaves.left.and.right`），
但各自走最适合的渲染方式：

| 位置 | 实现 | 说明 |
|---|---|---|
| 菜单栏 | 系统 SF Symbol 直接渲染（`setIcon`） | 系统按菜单栏标准尺寸绘制、自动适配深浅色，清晰度最佳 |
| App 图标 | `menubar/gen-icon.swift` 生成 `.icns` | 深石板色圆角底 + 白色符号，在访达/启动台/`⌘Tab` 中易辨识 |

构建时自动生成：

| 文件 | 用途 |
|---|---|
| `Resources/icon_1024.png` | 1024 原始图（App 图标源） |
| `Resources/AdbWifiBar.icns` | 由原始图多倍率缩放打包（`Info.plist` 的 `CFBundleIconFile`） |

想换图标只需改 `gen-icon.swift` 顶部（App 图标）与 `main.swift` 里 `updateIcon`
的符号候选（菜单栏），然后重新编译。

> 早期版本试过让菜单栏也加载同一张 PNG，但 PNG 缩放后图形会明显变小
> （实测 42×28 → 30×20 像素），所以菜单栏改回系统符号渲染。

由于 `LSUIElement` 为 `true`（纯菜单栏程序、不占 Dock），App 图标主要在访达、启动台、
`⌘Tab` 与系统弹窗中出现。

### 菜单内容

展开菜单会**实时重新采集**状态（约 0.16 秒），与 TUI 使用**同一份 `diag` 数据源**，因此两边结论一致：

```
● 守护运行中（开机自启）
  没有无线设备连接
──
  [✗] 未发现设备，且此网络屏蔽 mDNS
        插 USB 自动读端口 / 手动输入 IP:端口
  ▸ 处理：插上 USB 自动读取端口
──
  mDNS：被屏蔽
  USB：未连接
  发现方式：无
  本机：192.168.17.173
```

诊断结论由脚本层 `DIAG_LEVEL / DIAG_TITLE / DIAG_HINT / DIAG_ACTION` 统一给出，
避免菜单栏与 TUI 各自判断导致信息不一致。点击「▸ 处理」可直接执行对应修复动作。

重新编译：

```bash
./menubar/build.sh
```

---

## 配置

配置项在 `bin/adb-wifi.sh` 顶部的「可配置项」区块。

也可在项目根目录新建 `config.sh`（脚本启动时自动加载，该文件不存在时无影响）：

```bash
CHECK_INTERVAL=10        # 轮询间隔（秒）
TCP_TIMEOUT=3            # TCP 探测超时
CONNECT_TIMEOUT=12       # 单次 adb connect 超时
CANDIDATE_PORTS="..."    # TCP 兜底探测端口
ENABLE_NOTIFY=1          # 连接成功时发系统通知

# 插 USB 自动开启无线（见下文「免手动」章节）
AUTO_TCPIP=1             # 1=插 USB 自动转 TCP 模式，0=关闭
TCPIP_PORT=5555          # tcpip 监听端口
TCPIP_RETRY_INTERVAL=60  # 切换失败后的重试间隔（秒）
```

> 直接改脚本顶部效果相同；`config.sh` 只是把个人配置与代码分离，方便后续 `git pull` 不被覆盖。

---

## 插上 USB 全自动连接（免手动开无线调试）

**目标**：插上 USB 后，什么都不用点，自动建立无线 adb 连接。

### 为什么不直接打开「无线调试」开关

Android 要求写入 `adb_wifi_enabled` 需要 `WRITE_SECURE_SETTINGS` 权限，
普通 adb shell 没有该权限，实测会抛：

```
java.lang.SecurityException: Permission denial: writing to settings requires:
android.permission.WRITE_SECURE_SETTINGS
```

这是系统安全设计，**无法用 adb 命令绕过**，所以「一键打开无线调试开关」做不到。

### 实际采用的方案：`adb tcpip`

`adb tcpip <端口>` 让 adbd 在指定端口额外监听 TCP，**不需要任何特殊权限**，
USB 连上且已授权即可执行。守护会自动完成整个链路：

```
插入 USB → 检测到无可用无线连接 → adb tcpip 5555 → 取手机 Wi-Fi IP
        → adb connect IP:5555 → 后续掉线自动重连
```

实测日志：

```
[INFO] USB 设备 fbbd8bac 未开无线调试，自动切换 TCP 模式(端口 5555) ...
[INFO]   ✓ 已通过 USB 自动建立无线连接: 192.168.17.212:5555
```

**生效后拔掉 USB 依然可用** —— TCP 监听与 USB 通道相互独立。

### 两套发现方式并行

| 方式 | 触发条件 | 特点 |
|---|---|---|
| 系统「无线调试」 | 手机上已手动开启 | 端口随机（10000+），重启手机端口会变 |
| **`adb tcpip`** | 插着 USB 且尚未连上 | **端口固定 5555，免手动，推荐** |

两者互不冲突：有无线调试端口就用现成的，没有再自动切 tcpip。

### 注意事项

- `adb tcpip` 会重启 adbd，当前 USB 连接会**短暂断开**（约 3 秒）后自动恢复
- **重启手机后** tcpip 模式会失效，需重新插一次 USB（守护会自动处理）
- 端口对同一 Wi-Fi 内的设备开放，首次连接需在手机上点「允许」。**公用网络慎用**
- 想关闭此功能：设 `AUTO_TCPIP=0`
- 手动触发：菜单栏「立即开启 TCP 模式」或 `adb tcpip 5555`

### 恢复成 USB 模式

```bash
adb usb
```

---

## 一键打开手机设置页

手动去 设置 → 开发者选项 → 无线调试 很绕，这里提供一键直达。

| 入口 | 操作 |
|---|---|
| 菜单栏 | 「在手机上打开「无线调试」…」（⌘W）／「在手机上打开「开发者选项」…」 |
| 命令行 | `./bin/adb-wifi.sh open` 或 `./bin/adb-wifi.sh open dev` |
| 终端 TUI | 诊断结论里的「在手机上自动打开无线调试页」 |
| 诊断自动触发 | 检测到"无线调试开关未打开"时，点击「▸ 处理」即跳转 |

### 兼容性做法

各 ROM 的设置页结构差异很大，脚本按可靠性**逐级尝试**：

| 顺序 | 方式 | 适用 |
|---|---|---|
| ① | `com.android.settings/.SubSettings` + `WirelessDebuggingFragment` | AOSP 通用；**MIUI 13/14 实测可精确命中** |
| ② | `com.android.settings/.Settings$WirelessDebuggingActivity` | 部分 ROM 的独立页面 |
| ③ | `android.settings.APPLICATION_DEVELOPMENT_SETTINGS` | 兜底：打开开发者选项，由用户点「无线调试」 |

**关键点**：判断①是否真的停在无线调试页，靠 `uiautomator dump` 读界面文本匹配
「无线调试」。因为部分 ROM（如 MIUI）的 `WirelessDebuggingActivity` 是空壳，
启动后会被静默重定向到设置首页 —— 只判断 `am start` 是否报错是不够的。

实测有效的跳转命令：

```bash
adb shell am start -n com.android.settings/.SubSettings \
  --es ':settings:show_fragment' \
  'com.android.settings.development.WirelessDebuggingFragment'
```

### 踩过的坑（均已规避）

- `uiautomator dump /dev/tty` 在 MIUI 上抛 `FileNotFoundException`，只输出异常堆栈
  → 改为 dump 到 `/sdcard/` 再 grep
- 手机端 `grep` 对 `'A\|B'` 这种 BRE 交替写法不可靠
  → 改为固定串分别匹配
- 中文关键字在某些 Shell 转义下匹配不到
  → 先试中文，失败再试 `wireless debugging`（英文系统覆盖）

连接 USB 或无线都可以跳转；有 USB 时优先用 USB，避免打断正在使用的无线连接。

---


## 常见问题

**Q：日志一直显示「未发现可用设备」？**
1. **最简单的办法：插上 USB**，守护会自动切换 TCP 模式并连上（见上文「插上 USB 全自动连接」）
2. 若不用 USB，则确认手机「无线调试」已打开（不是仅开「USB 调试」）
3. 确认手机和 Mac 在**同一 Wi-Fi**（注意别连到访客网络 / 5G 与 2.4G 隔离网络）
4. 企业网络可能屏蔽组播 → 参考上文，手动 `adb connect` 一次建立记忆端点
5. 执行 `./bin/adb-wifi.sh once` 看三种发现方式的输出

**Q：插了 USB 但还是没连上？**
1. 确认手机已允许「USB 调试」弹窗，`adb devices` 能看到设备且状态为 `device`
2. 查看日志里的 tcpip 输出：`grep tcpip ~/Library/Application\ Support/adb-wifi-manager/logs/adb-wifi.log`
3. 部分厂商 ROM 会限制 `adb tcpip`，此时只能手动开「无线调试」
4. 手机未连 Wi-Fi 时无法转 TCP，守护会跳过并提示

**Q：连接上了但 `adb devices` 显示 `unauthorized`？**
在手机上确认「允许 USB 调试」弹窗。若无效，删除 `~/.android/adbkey*` 后重启守护并重新授权。

**Q：想彻底卸载？**
```bash
./bin/adb-wifi.sh stop
rm -rf ~/mycode/adb-wifi-manager
rm -rf ~/Library/Application\ Support/adb-wifi-manager
rm -f ~/Library/LaunchAgents/com.durunzhe.adb-wifi-manager.plist
rm -rf ~/Applications/AdbWifiBar.app
```

---

## 目录结构

```
adb-wifi-manager/
├── bin/adb-wifi.sh                 # 守护脚本（核心逻辑，纯 bash，无依赖）
├── install.sh                      # 一键安装（launchd + 菜单栏 App）
├── launchd/*.plist                 # launchd 模板
├── menubar/main.swift              # 菜单栏 App 源码
├── menubar/build.sh                # 编译脚本
├── menubar/gen-icon.swift          # App 图标生成器（SF Symbol → png + icns）
├── Resources/                      # 生成的 App 图标资源
└── build/AdbWifiBar.app            # 编译产物
```

> 脚本刻意使用 bash 3.2 兼容写法：macOS 自带的 `/bin/bash` 是 3.2 版本，
> 在 `$(...)` 内使用 `case`、以及 `;&` 语法都会报语法错误，已全部规避。
