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

## 安装入口

- 一键在线安装 / 更新：`get.sh`。下载最新**稳定** Release 的完整包，校验 SHA256，
  部署到 `~/mycode/adb-wifi-manager`（可用 `ADBWIFI_DIR` 覆盖），再调用包内 `install.sh`
- 手动：从 Releases 下载完整包解压后 `./install.sh`；或克隆仓库本地 `./install.sh`
- `get.sh` 默认只取正式版；`ADBWIFI_VERSION=0.0.2-alpha.1` 可安装 Alpha 版本
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
3. 用户确认后才打 tag 发正式版（见下方发布流程）。
4. 未确认前不要推送 tag，也不要用 `install.sh` / `get.sh` 覆盖用户已安装的正式版；
   预览只运行 `build/AdbWifiBar.app`，不要安装到 `~/Applications`。
5. `build/` 已在 `.gitignore` 中，预览产物不要提交。

## 发布流程

1. 前置：本地预览已由用户确认（见上方默认工作流）
2. 打 tag 并推送：

   ```bash
   git tag v0.0.3            # 稳定版
   git tag v0.0.4-alpha.1    # Alpha（基座为偶数）
   git push origin <tag>
   ```

3. `.github/workflows/release.yml` 会先校验 tag 是否符合奇偶规则，不符合直接失败
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

- 稳定版检查：`releases/latest`，只包含正式版本
- Alpha 检查：`/releases` 中第一个 prerelease，无则回退到带后缀的 tag
- 版本比较：核心版本逐段比较；核心相同时正式版 > 预发布版；预发布后缀按数值比较
  （`alpha.10 > alpha.9`）

## 修改版本相关逻辑时的检查清单

- [ ] `menubar/build.sh` 的默认版本与规则一致（当前 `0.0.1`）
- [ ] workflow 的 tag 校验仍拒绝「稳定版偶数 PATCH」与「alpha 版单数基座」
- [ ] `main.swift` 的 `isNewer` 对同核心的正式/预发布判定正确
- [ ] 中英文 README 中的示例版本同步更新
