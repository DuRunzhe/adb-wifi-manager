# adb-wifi-manager

> Mac 上的 Android **无线调试自动连接守护** —— 让「插一次 USB，之后永远无线」成为现实。
>
> [English Documentation](README.en.md) · [性能目标](#性能目标与实现技术方案) · [技术方案](#性能目标与实现技术方案)

---

## 这个工程解决了什么问题

Android 开发中，用无线方式连接手机调试是刚需。但 Android 11+ 的无线调试机制有几个**天然的坑**，
导致开发者每天都要为「连上手机」浪费大量时间：

### 痛点 1：端口每次随机分配，连一次废一次

Android 11+ 的「无线调试」每次开启都会分配**随机端口**（如 `192.168.1.5:38845`）。手机重启、
切换网络、甚至只是关闭再打开开关，端口就变了，之前 `adb connect` 记下的地址立即失效。
**每次都要打开手机、进设置、翻到无线调试页、抄 IP 和端口、再手动连接。**

### 痛点 2：无线调试开关必须手动点，无法用命令打开

直觉上应该能 `adb shell settings put global adb_wifi_enabled 1` 直接打开，但 Android 要求
`WRITE_SECURE_SETTINGS` 权限，普通 adb shell 没有，实测直接抛异常：

```
java.lang.SecurityException: Permission denial: writing to settings requires:
android.permission.WRITE_SECURE_SETTINGS
```

这是系统安全设计，**无法绕过**。所以"自动化"这件事从第一步就卡住了。

### 痛点 3：企业网络屏蔽 mDNS，标准发现方式失效

Android 11+ 官方依赖 mDNS（`_adb-tls-connect._tcp`）广播服务。但**很多企业 Wi-Fi 和路由器
会屏蔽组播**，导致 `adb mdns services` 永远是空的，标准流程完全走不通。

### 痛点 4：掉线后无法自动恢复

即使一度连上，Wi-Fi 波动、电脑睡眠唤醒、手机息屏都会导致断开。而"重新连上"依赖记住之前的地址，
一旦地址失效就彻底失联，**只能重新插 USB 从头来过**。

---

### 本工程的解法

| 痛点 | 解法 |
|---|---|
| 端口随机、连一次废一次 | 改用 `adb tcpip 5555`，**端口固定**，一次生效长期可用 |
| 开关无法命令打开 | 插 USB 时自动执行 `adb tcpip`（**不需要该权限**），绕过限制 |
| mDNS 被屏蔽 | 五路发现并行：mDNS、USB 读取、端点记忆、tcpip 探测、**网段扫描** |
| 掉线无法恢复 | **持久记忆 + 网段扫描**，无需 USB 也能找回换了 IP 的手机 |

**最终效果**：插一次 USB，之后手机重启、换 IP、掉线、Mac 睡眠唤醒，
都能**自动恢复无线连接，全程不需要碰手机设置页**。

> 唯一仍需 USB 的场景：手机重启后（tcpip 模式失效）插一次即可，其余情况全自动。

---

## 快速开始

一键安装 / 更新（自动下载最新正式版，完成 launchd 与菜单栏 App 安装）：

```bash
curl -fsSL https://raw.githubusercontent.com/DuRunzhe/adb-wifi-manager/main/get.sh | bash
```

可选环境变量：

| 变量 | 说明 |
|---|---|
| `ADBWIFI_VERSION=0.0.3` | 指定版本，可传 Alpha（如 `0.0.2-alpha.1`） |
| `ADBWIFI_DIR=~/mycode/adb-wifi-manager` | 安装目录（默认即此路径） |
| `ADBWIFI_SKIP_INSTALL=1` | 只下载部署，不注册 launchd / 不安装 App |

例如安装指定版本：

```bash
curl -fsSL https://raw.githubusercontent.com/DuRunzhe/adb-wifi-manager/main/get.sh \
  | ADBWIFI_VERSION=0.0.2-alpha.1 bash
```

> 安装包会做 SHA256 校验；目录已存在时用发布包覆盖（保留 `config.sh`）。
> 若你用 git 管理源码，请改用 `git pull && ./install.sh`，避免覆盖工作区。

安装后：

```bash
cd ~/mycode/adb-wifi-manager
./adbwifi                 # ★ 打开图形界面（推荐，零参数）
```

- 守护进程由 **launchd** 托管，登录即启动、崩溃自动重启
- 菜单栏 App 安装到 `~/Applications/AdbWifiBar.app`（可在访达双击打开，或拖入「登录项」）

也可以从 [Releases](https://github.com/DuRunzhe/adb-wifi-manager/releases) 手动下载
`adb-wifi-manager-<version>.zip`，解压后执行 `./install.sh`（自带预编译 App，无需 Xcode）；
或在克隆的仓库里本地执行 `./install.sh`。

---

## 性能目标与实现技术方案

这个工具**7×24 常驻后台**，因此性能不是"锦上添花"而是硬性要求：
既要在断线瞬间快速反应，又要在连接稳定时不打扰系统。

### 性能目标

| 目标 | 指标 | 现状 |
|---|---|---|
| **响应速度** | 掉线到重连完成 ≤ 2 秒 | ✅ 实测 **0.9~1.5 秒** |
| **空闲开销** | 连接稳定时几乎不产生负载 | ✅ USB 探测跳过，平均活跃 adb 进程 **0.87** |
| **诊断延迟** | `diag` 响应（菜单栏每次菜单都调用） | ✅ **0.2~0.4 秒**（优化前最坏 16 秒） |
| **扫描效率** | /24 网段全扫的单次耗时 | ✅ **0.9 秒**（优化前 7.3 秒） |
| **内存驻留** | 守护常驻内存 | ✅ bash 进程，约数 MB |
| **依赖精简** | 除 adb 外不引入运行时依赖 | ✅ 纯 bash + 系统自带工具 |

### 核心设计原则

> **稳定时少做事，需要时才付出开销。**

大部分时间里手机是连着的，此时任何"探测"都是浪费。所有探测逻辑都以
「当前是否已有可用连接」为前提短路。

### 实现技术方案

#### 1. 事件驱动，而非轮询

不使用 `while sleep 10` 这种固定轮询，而是订阅 `adb track-devices` 事件流：

```
adb track-devices  →  events.log  →  主循环立即被唤醒
                                  →  TUI 检测文件变化重绘
                                  →  菜单栏 DispatchSource 刷新图标
```

事件写入 `state/events.log`，三个消费者共用同一份数据源——**TUI 与菜单栏的结论天然一致**，
不会出现"终端显示已连接、菜单栏显示未连接"的矛盾。

代价是等待期间需要轻量探测事件文件，优化后只保留 `sleep` 一个子进程：

```bash
# 优化前：每 0.25 秒 fork 一次 sleep + 一次 stat（等待 10 秒 = 80 个子进程）
sleep 0.25
now=$(stat -f%m "$evf")

# 优化后：内建变量判断时间，内建 -nt 比较文件（只剩 sleep）
sleep 0.3
if [ "$evf" -nt "$mark" ]; then ...
```

#### 2. 五路发现并行，互为兜底

单一发现方式在真实网络环境下都不可靠，因此同时准备五种手段：

| 顺序 | 方式 | 原理 | 触发条件 |
|---|---|---|---|
| ① | mDNS | `adb mdns services` 读 `_adb-tls-connect._tcp` | 标准方式，网络屏蔽时失效 |
| ② | USB 读取 | 读设备 `/proc/net/tcp` 中 LISTEN 端口 | 插着 USB 时，端口 100% 准确 |
| ③ | 端点记忆 | 记录成功过的 `IP:PORT` | 掉线重连主力 |
| ④ | tcpip 探测 | 检查设备是否在监听固定端口 | 插着 USB 时 |
| ⑤ | 网段扫描 | 并发探测本网段 /24 | 前四路全落空时，带 5 分钟节流 |

#### 3. 用 `adb tcpip` 绕过权限限制

这是整个方案的关键洞察。既然无法打开「无线调试」开关，就**换一条不需要该权限的路**：

```bash
# 需要 WRITE_SECURE_SETTINGS —— 做不到
adb shell settings put global adb_wifi_enabled 1

# 不需要任何特殊权限 —— 可行
adb tcpip 5555
```

`adb tcpip` 让 adbd 在指定端口额外监听 TCP，与 USB 通道**并行存在**。
关键在于：**只需执行一次**，之后无论 USB 是否插着，adbd 都常驻监听 5555。

```
插 USB → adb tcpip 5555 → 取手机 Wi-Fi IP → adb connect IP:5555
                                              ↓
                                    拔掉 USB，连接依然有效
```

#### 4. 修复"记忆被过早删除"的缺陷

早期版本掉线后经常找不回，根因是一行看似合理的清理逻辑：

```bash
# 有问题的实现：不通就立即删
if nc -z "$ip" "$port"; then echo "$ep"; else stale+=("$ep"); fi
```

手机临时掉线、息屏、换网段都会触发删除，把"回家的路"忘掉。现改为：

```bash
# 只累计失败次数，连续失败 360 次（约 1 小时）才清理
echo "$ep $((fails + 1))" >> known_fails.txt
```

配合网段扫描，即使 IP 变了也能重新找回并自动更新记忆。

#### 5. 性能优化的五处关键改动

| 优化项 | 优化前 | 优化后 | 手段 |
|---|---|---|---|
| 网段扫描 | 254 个 `nc` 进程，7.3s | **1 个进程，0.9s** | 改用 perl 非阻塞并发 connect |
| `diag` | 最坏 16s | **0.2~0.4s** | 合并重复的 mDNS 查询为一次采集 |
| USB 探测 | 每轮 3~4 条 `adb shell` | 有连接时**直接跳过** | 入口短路 |
| 事件等待 | 每轮 fork `sleep`+`stat` | 只剩 `sleep` | 内建 `SECONDS` / `-nt` |
| 菜单栏轮询 | 固定 2s | 5s（可配） | 事件驱动兜底，无需高频 |

**其中 `diag` 的优化收益最大**：原实现调用了两次 `adb mdns services`
（`discover_mdns` 一次 + 统计计数一次），每次最长 8 秒。而菜单栏每次展开菜单都会调用 `diag`，
相当于每点一次菜单就浪费十几秒——现在合并为一次采集。

#### 6. 多 ROM 兼容的设置页跳转

各厂商 ROM 的设置页结构差异极大，采用"逐级尝试 + 结果校验"：

```
① SubSettings + WirelessDebuggingFragment   ← AOSP 通用，MIUI 实测命中
② Settings$WirelessDebuggingActivity        ← 部分 ROM
③ APPLICATION_DEVELOPMENT_SETTINGS          ← 兜底
```

关键在于**必须校验结果**：部分 ROM（如 MIUI）的 `WirelessDebuggingActivity` 是空壳，
启动后会被静默重定向到设置首页。只判断 `am start` 是否报错会误判成功，因此要
`uiautomator dump` 读取界面文本，确认真的停在无线调试页。

#### 7. 兼容 macOS 自带的 bash 3.2

macOS 自带的 `/bin/bash` 是 3.2 版本，存在两个陷阱：

- `$(...)` 内使用 `case` 会语法错误 → 全部改用 `if`
- `;&`（case fallthrough）需 bash 4+ → 全部规避
- `EPOCHSECONDS`、关联数组等特性不存在 → 改用 `SECONDS` 等 3.2 可用写法

这样保证**开箱即用，无需 `brew install bash`**。

### 技术栈

| 组件 | 技术选型 | 理由 |
|---|---|---|
| 守护进程 | 纯 bash | 无运行时依赖，任何 Mac 开箱可用 |
| 终端界面 | Python 3 + curses | 系统自带，跨终端兼容 |
| 菜单栏 App | Swift + AppKit | 原生，无需 Xcode 工程文件 |
| 进程管理 | launchd | 系统原生，登录自启 + 崩溃重启 |
| 图标生成 | Swift + SF Symbol | 与系统风格一致，随外观自动适配 |

代码规模约 **3300 行**（守护 1134 / TUI 1292 / 菜单栏 767 / 图标 115）。

---

## 终端界面（TUI）

```bash
./adbwifi
```

打开后即可看到完整状态与诊断结果，**全部操作可用鼠标点击或键盘完成**：

```
 ADB 无线调试管理器   ● 守护运行中 (开机自启)              Q 退出  R 刷新  ? 帮助
 连接状态
✓ 192.168.1.50:38075
USB: 未连接
mDNS: 被屏蔽 ✗   发现方式: 记忆端点
本机: 192.168.1.100
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
| `./bin/adb-wifi.sh recover` | 主动恢复无线连接（**无需 USB**） |
| `./bin/adb-wifi.sh rate [秒]` | 查看当前 adb 传输速率（默认采样 1 秒） |

日志位置：`~/Library/Application Support/adb-wifi-manager/logs/adb-wifi.log`

---

## 自动发现原理

Android 11+ 的「无线调试」端口是**每次随机分配**的，因此脚本用三种方式互补发现，任一可用即可：

| 方式 | 说明 | 可靠性 |
|---|---|---|
| **mDNS** | `adb mdns services` 读取 `_adb-tls-connect._tcp` 广播 | 标准方式，但**很多企业 Wi-Fi / AP 会屏蔽组播** |
| **USB 读取** | 手机插着 USB 时，读取其 adbd 实际监听端口，**端口 100% 准确** | 最可靠 |
| **端点记忆** | 记录连接成功过的 `IP:PORT`，掉线后重试 | 断线重连的主力 |

> ⚠️ **实测结论**：部分企业网络（如办公 Wi-Fi）会屏蔽 mDNS 组播，
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

- ✅ 无线连接断开 → 事件触发即刻重连（实测 **0.9~1.5 秒**，旧版轮询需 ~10 秒）
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
  本机：192.168.1.100
```

诊断结论由脚本层 `DIAG_LEVEL / DIAG_TITLE / DIAG_HINT / DIAG_ACTION` 统一给出，
避免菜单栏与 TUI 各自判断导致信息不一致。点击「▸ 处理」可直接执行对应修复动作。

### 关于与版本更新

菜单底部「关于 ADB WiFi」显示版本号（`build.sh` 从 git tag 读取，可用
`ADBWIFI_VERSION=x.y.z` 覆盖），并提供项目主页 / 问题反馈 / 版本发布链接。

更新检查分两个入口：

| 入口 | 样式 | 来源 | 说明 |
|---|---|---|---|
| 「检查正式版更新」 | 大号默认按钮（回车触发） | `releases/latest` | 主入口，只含正式版 |
| 「预发布通道：Alpha 预览版」 | 小号文字链 | `/releases` 中第一个 prerelease | 次要入口，可能不稳定 |

正式版检查调用 GitHub API（`releases/latest`，仓库尚无 Release 时回退到不带后缀的 tag），
按版本号逐段比较：主版本相同则正式版 > 预发布版，预发布后缀按数值比较
（`alpha.10 > alpha.9`）。

- **打开关于即自动检查正式版**（60 秒内不重复请求），检查结果直接显示在按钮上，
  不弹窗：「已是最新版本，点击重查」/「检查失败，点击重试」/「下载并安装 vX.Y.Z」
- **一键自动更新**：点击「下载并安装」后自动下载 `AdbWifiBar-<version>-universal.zip`，
  用 `spctl` 校验签名与公证，等待当前进程退出后替换
  `~/Applications/AdbWifiBar.app` 并启动新版本
- **Alpha 入口为蓝色下划线超链接**：点击检查，发现预发布版本时链接变为
  「下载 Alpha vX.Y.Z」，再次点击打开下载页；结果显示在版本状态行

### 发布

版本号规则（详见 [AGENTS.md](AGENTS.md)）：从 `v0.0.1` 开始，
**PATCH 单数 = 稳定版，PATCH 偶数 = Alpha 基座**。

| 用途 | tag 示例 |
|---|---|
| 稳定版 | `v0.0.1`、`v0.0.3` |
| Alpha | `v0.0.2-alpha.1`、`v0.0.4-alpha.1` |

推送 tag 即自动打包并创建 Release（`.github/workflows/release.yml`）：

```bash
./menubar/build.sh          # 本地先验证编译
git tag v0.0.1
git push origin v0.0.1      # 触发 GitHub Actions
```

工作流会先校验 tag 是否符合奇偶规则（稳定版不得用偶数 PATCH，Alpha 不得用单数基座），
不符合直接失败；带 `alpha.N` 后缀的 Release 自动标记为 **prerelease**，
正式版检查不会拿到它，只会出现在关于窗口的「Alpha 预览版」通道里。

Actions 在 macOS runner 上编译 **arm64 + x86_64 通用二进制**，产出：

| 资产 | 内容 |
|---|---|
| `AdbWifiBar-<version>-universal.zip` | 仅菜单栏 App，拖入「应用程序」即可 |
| `adb-wifi-manager-<version>.zip` | 完整包（源码 + 预编译 App），解压后 `./install.sh` 一键安装 |
| `SHA256SUMS.txt` | 校验和 |

版本号取自标签（`v0.0.1` → `0.0.1`），与「关于」里的检查更新一致。
本地需要通用二进制时：`ADBWIFI_UNIVERSAL=1 ./menubar/build.sh`。

> 未配置 Developer ID 时 App 为 ad-hoc 签名、未经公证。首次运行若遇到
> Gatekeeper 提示，在访达中右键 App →「打开」即可。若 Release 创建失败，检查仓库
> Settings → Actions → General → Workflow permissions 是否为「Read and write」。

#### 正式签名与公证（可选）

默认 ad-hoc 签名，适合自己使用；公开分发建议配置 Developer ID 签名 + 公证，
CI 会自动完成，**未配置时自动回退 ad-hoc**。

前置：Apple Developer Program 账号（$99/年）。

1. 钥匙串 → 登录 → 我的证书，找到 `Developer ID Application: 你的名字 (TEAMID)`，
   右键导出 `.p12` 并设置密码
2. App Store Connect → Users and Access → Keys → App Store Connect API → 生成 Key，
   角色选 Developer，下载 `AuthKey_XXXX.p8`（只能下载一次），记录 Key ID 与 Issuer ID
3. 仓库 Settings → Secrets and variables → Actions 添加：

| Secret | 内容 |
|---|---|
| `MACOS_CERT_P12` | `base64 -i cert.p12 \| tr -d '\n'` |
| `MACOS_CERT_PASSWORD` | 导出 `.p12` 时设置的密码 |
| `APPLE_TEAM_ID` | 10 位 Team ID |
| `APPLE_API_KEY_ID` | API Key 的 Key ID |
| `APPLE_API_ISSUER_ID` | API Key 的 Issuer ID |
| `APPLE_API_KEY_P8` | `base64 -i AuthKey_XXXX.p8 \| tr -d '\n'` |

配置后推送 tag，工作流会：导入证书 → hardened runtime 签名 →
`notarytool submit --wait` 公证 → `stapler staple` 装订 → 打包上传。完成后校验：

```bash
spctl -a -t exec -vv /Applications/AdbWifiBar.app
# accepted，source=Notarized Developer ID
```

本地正式签名构建：

```bash
CODESIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)" ./menubar/build.sh
```

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

# 无 USB 自动恢复
AUTO_SCAN=1              # 1=允许扫描本网段找回设备，0=关闭
SCAN_INTERVAL=300        # 两次扫描的最小间隔（秒）
MAX_KNOWN_FAILS=360      # 记忆端点连续失败多少次才丢弃
SCAN_TIMEOUT=0.8         # 网段扫描单台超时（秒）
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
[INFO] USB 设备 ABC123DEF 未开无线调试，自动切换 TCP 模式(端口 5555) ...
[INFO]   ✓ 已通过 USB 自动建立无线连接: 192.168.1.50:5555
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

## 无 USB 自动恢复无线连接

**核心认知**：`adb tcpip 5555` 只需执行一次（需 USB），之后 adbd 会**常驻监听** 5555，
无论 USB 是否插着都能直接 `adb connect`。所以：

| 操作 | 需要 USB？ | 作用 |
|---|---|---|
| `adb tcpip 5555` | ✅ 必须 | 让手机**开始**监听（一次性） |
| `adb connect IP:5555` | ❌ 不需要 | 掉线后重新连上 |

### 恢复顺序

菜单栏「立即恢复无线连接（无需 USB）」（⌘R）或 `./bin/adb-wifi.sh recover`：

```
已有连接 → 记忆端点 → 扫描本网段找回换了 IP 的手机
```

实测：同一 IP 掉线 → **1 秒内**恢复；IP 变了 → 扫描找回约 **5 秒**。

### 修复的关键缺陷

早先的实现里，`discover_known` 只要探测不通就**立即从记忆里删掉**该端点。
手机临时掉线、息屏、换网段时都会触发删除，结果"回家的路"被忘掉，
之后只能重新插 USB —— 这才是"无法自动恢复"的真正原因。

现在改为：
- 不通时**保留记忆**，只累计失败次数
- 连续失败超过 `MAX_KNOWN_FAILS`（默认 360 次 ≈ 1 小时）才清理
- 记忆为空或全部失效时，自动扫描本网段（默认每 5 分钟最多一次）

### 恢复相关的开销控制

网段扫描虽然强大，但不能滥用，因此加了两层节流：

- **`SCAN_INTERVAL`**（默认 300 秒）：两次扫描的最小间隔
- **前置条件**：只有「五路发现全部落空」时才触发，连接正常时永不扫描

完整性能数据与优化细节见上文 [性能目标与实现技术方案](#性能目标与实现技术方案)。

### 什么时候仍需要 USB

- **手机重启后**：tcpip 模式失效，adbd 回到 USB 模式，必须插一次 USB
- 手动执行过 `adb usb`
- 手机换了 Wi-Fi 且新网络禁止设备互访（AP 隔离）

除以上情况外，掉线、换 IP、Mac 睡眠唤醒都能自动找回。

---

## 传输速率监控

实时显示 adb 连接的双向传输速率，无需额外工具。

| 入口 | 显示 |
|---|---|
| 菜单栏 | `↓ 1.2 MB/s   ↑ 0 KB/s` + 累计收发量 |
| TUI | 状态区显示「传输: ↓ … ↑ …」+ 累计 |
| 命令行 | `./bin/adb-wifi.sh rate 2` |

### 数据来源与取舍

adb **没有官方的速率查询命令**，因此需要自己采样计算。候选方案对比：

| 方案 | 精度 | 代价 | 结论 |
|---|---|---|---|
| 读 `netstat -anv` 连接字节数 | 高，Mac 侧直接可得 | 单次 <10ms，零侵入 | ✅ **采用** |
| 读设备端 `/proc/net/dev` | 高，但含手机所有 App 流量 | 需 `adb shell`，**与 pull/push 互相阻塞** | ❌ 放弃 |
| `nettop` 系统工具 | 中，按进程聚合 | 需解析，粒度粗 | ❌ 放弃 |

关键原因：设备端方案要执行 `adb shell`，实测在 `adb pull` 大文件期间会互相阻塞导致卡死，
而 netstat 在 Mac 本地读取，完全不影响传输。

### 字段映射（实测得出，非文档推断）

macOS `netstat -anv -p tcp` 的字节列含义容易搞错，用真实传输验证：

| 操作 | 字段 7 | 字段 8 | 结论 |
|---|---|---|---|
| `adb pull`（手机→Mac） | **+4.38 MB** | +72 字节 | 字段 7 = **下行** |
| `adb push`（Mac→手机） | +626 字节 | **+2.79 MB** | 字段 8 = **上行** |

因此 `↓` 取字段 7、`↑` 取字段 8。另外注意 macOS awk 的 `$N` 取列不可靠，
需用整行正则锚定 `ESTABLISHED` 后 `split` 取值。

### 采样策略

- **非阻塞**：`diag` 被菜单栏频繁调用，绝不能在里面 `sleep`；每次只采一个点做差值
- **间隔保护**：两次采样不足 200ms 时返回 0，避免除零和数值抖动
- **回退检测**：连接重建会让累计值归零，此时丢弃本次差值，不显示负数或天文数字
- **毫秒精度**：用 `perl` 取时间戳，避免 `date +%s` 的秒级截断误差

> 无线链路实测延迟抖动较大（9~420ms），传输速率会随之波动，
> 多采样几次取稳定值比看单次读数更有参考意义。

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
├── .github/workflows/release.yml   # 推送 v* 标签自动打包并发布 Release
├── AGENTS.md                       # 项目规范：版本号规则与发布流程
├── get.sh                          # 一键在线安装 / 更新（下载 Release 并部署）
├── bin/adb-wifi.sh                 # 守护脚本（核心逻辑，纯 bash，无依赖）
├── install.sh                      # 一键安装（launchd + 菜单栏 App）
├── launchd/*.plist                 # launchd 模板
├── menubar/main.swift              # 菜单栏 App 源码
├── menubar/build.sh                # 编译脚本（支持 ADBWIFI_UNIVERSAL=1）
├── menubar/gen-icon.swift          # App 图标生成器（SF Symbol → png + icns）
├── Resources/                      # 生成的 App 图标资源
├── prebuilt/AdbWifiBar.app         # 发布包内的预编译 App（仅打包时生成）
└── build/AdbWifiBar.app            # 本地编译产物
```

> 脚本刻意使用 bash 3.2 兼容写法：macOS 自带的 `/bin/bash` 是 3.2 版本，
> 在 `$(...)` 内使用 `case`、以及 `;&` 语法都会报语法错误，已全部规避。

---

## 许可证

[Apache License 2.0](LICENSE)
