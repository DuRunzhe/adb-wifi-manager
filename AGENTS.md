# 项目规范

本文件记录 adb-wifi-manager 的版本号约定与发布流程，修改版本相关逻辑时必须遵守。

## 版本号规则

版本号采用三段式 `MAJOR.MINOR.PATCH`，git tag 统一加 `v` 前缀。

- **起始版本**：`v0.0.1`
- **PATCH 为单数** → 稳定版本，tag 形如 `v0.0.1`
- **PATCH 为偶数** → Alpha 版本基座，tag 必须带 `-alpha.N` 后缀，形如 `v0.0.2-alpha.1`

| 用途 | 合法 tag 示例 | 说明 |
|---|---|---|
| 稳定版 | `v0.0.1`、`v0.0.3`、`v0.0.5` | 只发布正式 Release |
| Alpha | `v0.0.2-alpha.1`、`v0.0.2-alpha.2`、`v0.0.4-alpha.1` | 发布为 prerelease，基座版本为偶数 |

约束：

- 稳定版不得使用偶数 PATCH（`v0.0.2` 非法）
- Alpha 版不得使用单数 PATCH 基座（`v0.0.1-alpha.1` 非法）
- Alpha 后缀固定为 `alpha.N`，N 从 1 递增
- 版本只增不减；同一基座上新一轮 alpha 递增 N，不重复使用已发布过的 tag
- 升级 MAJOR / MINOR 时同样适用：稳定版必须落在单数 PATCH（如 `v1.0.1`），
  `v1.0.0` 因 PATCH 为偶数不能作为稳定版发布

## 版本号在代码中的来源

- `menubar/build.sh` 从最近的 git tag 推导版本（去掉 `v` 前缀），无 tag 时回退 `0.0.1`；
  也可用 `ADBWIFI_VERSION=x.y.z` 覆盖
- `Info.plist` 中：`ADBWifiFullVersion` 存完整版本（含 `-alpha.N`），
  `CFBundleShortVersionString` 只存数字三段（`0.0.2`，Apple 对 bundle 版本的要求），
  `CFBundleVersion` 取 `git rev-list --count HEAD`
- 菜单栏「关于 ADB WiFi」优先读 `ADBWifiFullVersion`，并用它做更新检查

## 脚本输出协议（App ↔ 脚本）

`bin/adb-wifi.sh` 与 `menubar/main.swift` 之间**只通过 ASCII 枚举通信，禁止解析中文文案**。

- 默认（`text`）模式输出中文文案，供终端与 TUI 直接展示
- `ADBWIFI_FORMAT=kv` 时只输出协议字段：
  - `recover`：`RESULT=already|recovered|failed`、`ENDPOINT`、`VIA=existing|known|scan|usb`、`ERROR=no_usb|tcpip_failed`
  - `open`：`RESULT=opened|partial|need_usb|no_device|failed`、`PAGE`、`TITLE`、`WIFI_TOGGLE=on|off|unknown`
- `diag` 始终输出 `DIAG_CODE` 枚举（不受开关影响）；`DIAG_TITLE` / `DIAG_HINT` 保留给终端与 TUI
- `netinfo` 输出多设备链路指标 `NET_DEV_COUNT` + 每台一组 `NET_DEV_<n>_*`
  （SERIAL / TRANSPORT / MODEL / SSID / BSSID / FREQ / CHANNEL / LINK / RSSI /
  RTT_MIN / RTT_AVG / RTT_MAX / BATTERY / CHARGING）
  与全局 `NET_MAC_RATE` / `NET_MAC_CHANNEL` / `NET_MAC_RSSI` / `NET_MAC_BATTERY` / `NET_MAC_POWER`、
  `NET_RATE_AVG_MBPS` / `NET_RATE_MAX_MBPS`、`NET_AT`（采集时间戳）；
  采集慢（1–3s），两级缓存：设备侧 60 秒（`state/netinfo.cache`）、Mac 侧 300 秒
  （`state/netinfo_mac.cache`）；`diag` 只读缓存，并由 mkdir 原子锁保证单采集实例
- 界面文案统一在 `menubar/i18n.swift` 维护，`zhHans` / `zhHant` / `en` 三表必须同时补齐
- 速率类数值协议层用 Mbps（原始值），显示层统一换算为 MB/s（字节基准）

## 进程与单实例约束

同一条链路上会同时存在多个进程（菜单栏 App、守护、一次性命令、TUI），
代码必须假设它们并发运行，不能有任何「全局唯一临时文件」或「只杀一个进程」的假设。

- **菜单栏 App**：三层保护 —— `LSMultipleInstancesProhibited`（Info.plist）、
  `menubar.lock` 的 `flock` 独占锁、`StaleInstance` 清理旧副本（`menubar/main.swift` 末尾）
- **守护 `_daemon`**：`main_loop` 入口用 `state/daemon.lock.d`（mkdir 原子锁，内含持有者 PID）
  做单实例；抢不到锁直接 `exit 0`，持有者已死/目录过旧则接管。
  `INT`/`TERM`/`EXIT` 都必须释放锁（异常退出也要），否则会退化到「陈旧接管」
- **禁止 `rm -f menubar.lock`**：flock 随进程退出由内核释放，删文件会让新旧实例
  各自持有一把锁（旧 inode / 新 inode），等于双实例
- **临时文件必须带 `$$`**：`known_fails.txt.tmp.$$`、`known_endpoints.txt.keep.$$`、
  `netinfo.cache.tmp.$$` 等。固定名字在守护与一次性命令并发时会导致
  `mv: No such file or directory` 与状态丢失
- **`diag` 必须只读**：不写 `known_*` 状态文件，`discover_known` 用 `--readonly`。
  补记端点由守护循环负责（`main_loop` 步骤 1.5）
- **子进程按组清理**：`stop_device_tracker` 先 `pkill -P` 再 kill 本体；
  Swift 侧 `runScript` 超时用 `processDescendants` 先杀后代再杀 bash。
  只杀父进程会让 `adb` / `perl` / `ping` 被 init 收养永久残留
- **`daemon_pids` 返回全部实例**（祖先链过滤掉 bash 的 fork 子 shell），
  `cmd_stop` 全杀；不要退回 `head -1`

### 修改进程相关逻辑时的检查清单

- [ ] `_daemon` 仍抢不到锁即退出，且 `INT`/`TERM`/`EXIT` 都释放锁
- [ ] 新增后台 subshell 时，退出路径能连带清理其子进程
- [ ] 新增临时文件用 `$$` 后缀，失败分支会删除自己创建的临时文件
- [ ] `diag` / 高频查询路径不写状态文件
- [ ] `bash -n bin/adb-wifi.sh` 与 `swiftc -typecheck menubar/main.swift menubar/i18n.swift` 通过
- [ ] 用 `start` → 再 `start` → `restart` → `stop` 验证：始终只有 1 个 `_daemon`、
      1 个 `adb track-devices`，stop 后两者都为 0

### 修改协议时的检查清单

- [ ] 新增诊断分支同时设置 `code` 与中文 `title` / `hint`
- [ ] 新增 `DIAG_CODE` 在 `i18n.swift` 三表补 `diag.<CODE>.title` / `diag.<CODE>.hint`
- [ ] 新增 `NET_DEV_<n>_*` 字段时，同步 `main.swift` 的 `DevLink`、TUI 的 `dev_links` 与中英文 README 协议表
- [ ] 新增/改名 kv 字段或值域时，同步 `main.swift` 消费逻辑与中英文 README 的协议表
- [ ] `bash -n bin/adb-wifi.sh` 与 `swiftc -typecheck menubar/main.swift menubar/i18n.swift` 通过
- [ ] App 侧对所有新 code 保留回退：`L.has(key)` 为 false 时用脚本下发的中文

## 安装入口

- 一键在线安装 / 更新：`get.sh`。下载最新**稳定** Release 的完整包，校验 SHA256，
  部署到 `~/mycode/adb-wifi-manager`（可用 `ADBWIFI_DIR` 覆盖），再调用包内 `install.sh`
- 手动：从 Releases 下载完整包解压后 `./install.sh`；或克隆仓库本地 `./install.sh`
- `get.sh` 默认只取正式版；`ADBWIFI_VERSION=0.0.2-alpha.1` 可安装 Alpha 版本
- `get.sh` 解析最新版本时会被 GitHub 匿名 API 限流（403，60 次/小时）：脚本按
  「API → 网页 302 → `releases.atom`」兜底，或用 `GITHUB_TOKEN` 提高额度
- `ADBWIFI_SKIP_INSTALL=1` 只下载部署，不注册 launchd / 不安装 App

## 修改后的默认工作流

1. 改完代码先在本地构建预览（ad-hoc 签名，仅供本机测试）：

   ```bash
   ADBWIFI_VERSION=<下一个版本> ./menubar/build.sh
   open build/AdbWifiBar.app
   ```

   涉及自动更新逻辑时，可用较低版本模拟旧版，例如
   `ADBWIFI_VERSION=0.0.7 ./menubar/build.sh`，点击「下载并安装」验证升级流程。

2. 把预览效果与待验证点告诉用户，**等待用户确认**。
3. 用户确认后才打 tag 发正式版（见下方发布流程），并且必须先跑完
   「发布前强制检查：多语言 + 无障碍」
4. 未确认前不要推送 tag，也不要用 `install.sh` / `get.sh` 覆盖用户已安装的正式版；
   预览只运行 `build/AdbWifiBar.app`，不要安装到 `~/Applications`。
5. `build/` 已在 `.gitignore` 中，预览产物不要提交。

## 发布前强制检查：多语言 + 无障碍

**提交推送 GitHub、打 tag、出 App 包之前必须做完下面两组检查并修复发现的问题。**
任一项不通过就不得 `git push` tag、不得创建 Release。不允许「先发再修」。

### 多语言（zhHans / zhHant / en）

- [ ] `python3 scripts/check-i18n.py` 通过（键集合、占位符数量、引用 key 三项自动校验）
- [ ] UI 文案无硬编码：按钮标题、tooltip、窗口标题、可访问性标签全部走 `L.t`
- [ ] 逻辑删除后变成孤儿的 key 已清掉（三表同步删），避免以后漏翻
- [ ] 长文案不截断：固定宽度的按钮/标签要么允许按内容撑开（如主按钮只给
      `>= 264` 下限），要么有 truncation 兜底；英文
      「Download & Install Alpha vX.Y.Z」这类最长的串要专门看过
- [ ] 逐个语言渲染「可更新 / 下载中 / 失败」关键状态截图确认排版（见下方渲染方法）

### 无障碍（VoiceOver / 键盘 / 显示偏好）

- [ ] 每个可点控件有可读名字：`NSButton` 用 `title`；**用 `attributedTitle` 渲染的
      必须额外 `setAccessibilityLabel`**（AX 不会同步 attributedTitle，VoiceOver 只会
      念一个空按钮）
- [ ] 自绘的进度/状态提供 `accessibilityValue`，变化时发 `.valueChanged`；
      高频更新要节流（本项目按每 10% 播报一次）
- [ ] 纯装饰视图（应用图标、分隔线）`setAccessibilityElement(false)`，不占 AX 顺序
- [ ] 菜单栏 `statusItem.button` 有 `accessibilityLabel` / `accessibilityHelp`，
      **且切换语言后要重新设置**（只设一次会残留旧语言）
- [ ] 状态/错误不只靠颜色表达，必须同时有文字
- [ ] 文字链接可发现：用链接色，有悬停下划线 + `pointingHand` 光标；
      **不要用灰色假装「次要链接」**（用户已明确反馈看不出能点）
- [ ] 颜色只用语义色（深色模式自适应）；小号灰字不要用 `tertiaryLabelColor`
      （对比度不足），用 `secondaryLabelColor`
- [ ] 跟随系统「减少动态效果」（动画降级为静态）与「增强对比度」
      （轨道/边框不透明度提高）
- [ ] 键盘：主操作为默认按钮（Return）、关闭为 `Esc`、窗口设了
      `initialFirstResponder`、Tab 顺序与视觉顺序一致
- [ ] 至少 dump 一次 AX 属性（label / value / help / 窗口标题）并逐语言截图确认
      「进度条不与文字重叠、无截断」

### 验证方法

```bash
# 1) 编译与脚本语法
bash -n bin/adb-wifi.sh
swiftc -typecheck menubar/main.swift menubar/i18n.swift

# 2) 多语言自动校验（必须输出 i18n OK）
python3 scripts/check-i18n.py
```

视觉/无障碍确认需要临时预览钩子：在 `applicationDidFinishLaunching` 末尾加一段
由环境变量（如 `ADBWIFI_PREVIEW_ABOUT=1` + `ADBWIFI_PREVIEW_STATE=`）触发的代码，
打开关于窗口、伪造状态、再用 `cacheDisplay` 把 `contentView` 写 PNG，配合
`-ADBWifiLanguage en|zhHant|zhHans`（NSArgumentDomain 覆盖，不污染 UserDefaults）
逐语言渲染。**截图核对完必须把钩子删干净**（`grep TEMP-PREVIEW-HOOK` 应为空），
不要让调试代码进发布包。

## 发布流程

1. 前置：本地预览已由用户确认（见上方默认工作流），且**已完成「发布前强制检查」
   的多语言与无障碍两组检查**（`scripts/check-i18n.py` 通过与各项人工确认）
2. 打 tag 并推送：

   ```bash
   git tag v0.0.3            # 稳定版
   git tag v0.0.4-alpha.1    # Alpha（基座为偶数）
   git push origin <tag>
   ```

3. `.github/workflows/release.yml` 会先校验 tag 是否符合奇偶规则，不符合直接失败；
   随后跑 `scripts/check-i18n.py`，三张文案表不一致同样直接失败
4. 校验通过后构建 arm64 + x86_64 通用 App，生成 `AdbWifiBar-<version>-universal.zip`、
   `adb-wifi-manager-<version>.zip`、`SHA256SUMS.txt` 并创建 Release；
   带 `alpha` 后缀的自动标记为 prerelease

## 正式签名与公证（可选）

默认 ad-hoc 签名（仅本机/自用）。在仓库 Secrets 中配置以下变量后，工作流自动
使用 Developer ID 签名并公证，未配置时自动回退 ad-hoc：

| Secret | 内容 |
|---|---|
| `MACOS_CERT_P12` | Developer ID Application 证书 `.p12` 的 base64（单行） |
| `MACOS_CERT_PASSWORD` | 导出 `.p12` 时的密码 |
| `APPLE_TEAM_ID` | 10 位 Team ID |
| `APPLE_API_KEY_ID` | App Store Connect API Key ID |
| `APPLE_API_ISSUER_ID` | API Key 的 Issuer ID |
| `APPLE_API_KEY_P8` | API Key `.p8` 的 base64（单行） |

签名使用 hardened runtime（`--options runtime`）与
`menubar/entitlements.plist`（最小权限集）；公证由 `notarytool --wait` 完成，
随后 `stapler staple` 装订票据。本地正式签名构建：
`CODESIGN_IDENTITY="Developer ID Application: ..." ./menubar/build.sh`

## 更新检查的分流

- 稳定版检查：`releases/latest`，只包含正式版本；API 失败（403 限流等）时按
  「网页 302 `releases/latest` → `releases.atom` → tags API」兜底，不阻断检查
- Alpha 检查：`/releases` 中第一个 prerelease，无则回退到 atom / 带后缀的 tag
- 版本比较：核心版本逐段比较；核心相同时正式版 > 预发布版；预发布后缀按数值比较
  （`alpha.10 > alpha.9`）

## 修改版本相关逻辑时的检查清单

- [ ] `menubar/build.sh` 的默认版本与规则一致（当前 `0.0.1`）
- [ ] workflow 的 tag 校验仍拒绝「稳定版偶数 PATCH」与「alpha 版单数基座」
- [ ] `main.swift` 的 `isNewer` 对同核心的正式/预发布判定正确
- [ ] 中英文 README 中的示例版本同步更新
