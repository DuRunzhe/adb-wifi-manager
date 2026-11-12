#!/bin/bash
# 编译菜单栏 App: AdbWifiBar.app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/AdbWifiBar.app"
RES_SRC="$ROOT/Resources"

mkdir -p "$BUILD"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 版本号：优先环境变量，其次最近的 git tag（去掉 v 前缀），都没有时用默认值。
# 「关于」窗口和版本更新检查都读这里写入的值。
VERSION="${ADBWIFI_VERSION:-$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.1}"
# CFBundleShortVersionString 必须是数字三段，预发布后缀只放在自定义键里，
# 避免签名/公证对 bundle 版本格式报错。
VERSION_CORE="${VERSION%%-*}"
BUILD_NUM="${ADBWIFI_BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
echo "版本: $VERSION (build $BUILD_NUM)"

# 生成图标资源（App 图标 .icns，与菜单栏使用同一个 SF Symbol）
echo "生成图标资源 ..."
swiftc -O -o "$BUILD/.gen-icon" "$ROOT/menubar/gen-icon.swift"
"$BUILD/.gen-icon" "$RES_SRC"
rm -f "$BUILD/.gen-icon"

echo "编译 main.swift ..."
# 默认只编译当前架构；ADBWIFI_UNIVERSAL=1 时交叉编译两份再合并为通用二进制
# （Intel + Apple Silicon），供 GitHub Release 打包使用。
MACOS_MIN="11.0"
if [[ "${ADBWIFI_UNIVERSAL:-0}" == "1" ]]; then
    ARCHS=("arm64" "x86_64")
else
    ARCHS=("$(uname -m)")
fi
TMP_BIN="$BUILD/.bins"
rm -rf "$TMP_BIN"
mkdir -p "$TMP_BIN"
BINS=()
for arch in "${ARCHS[@]}"; do
    case "$arch" in
        arm64|x86_64) ;;
        *) echo "✗ 不支持的架构: $arch"; exit 1 ;;
    esac
    echo "  - $arch"
    swiftc -O -target "$arch-apple-macos$MACOS_MIN" \
        -o "$TMP_BIN/AdbWifiBar-$arch" \
        "$ROOT/menubar/main.swift" \
        "$ROOT/menubar/i18n.swift"
    BINS+=("$TMP_BIN/AdbWifiBar-$arch")
done
if [[ ${#BINS[@]} -gt 1 ]]; then
    lipo -create -output "$APP/Contents/MacOS/AdbWifiBar" "${BINS[@]}"
    echo "  → 通用二进制: $(lipo -archs "$APP/Contents/MacOS/AdbWifiBar")"
else
    cp "${BINS[0]}" "$APP/Contents/MacOS/AdbWifiBar"
fi
rm -rf "$TMP_BIN"

# 打包 App 图标（菜单栏图标由系统 SF Symbol 直接渲染，无需图片文件）
cp "$RES_SRC/AdbWifiBar.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AdbWifiBar</string>
    <key>CFBundleDisplayName</key><string>ADB WiFi</string>
    <key>CFBundleIdentifier</key><string>com.durunzhe.adb-wifibar</string>
    <key>CFBundleVersion</key><string>${BUILD_NUM}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION_CORE}</string>
    <key>ADBWifiFullVersion</key><string>${VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>AdbWifiBar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>LSUIElement</key><true/>
    <!-- 单实例：禁止 LaunchServices 启动第二个副本（open -n / 拖入第二个 App 均无效）。
         注意：该键只约束 LaunchServices，直接执行可执行文件仍可绕过，
         因此 main.swift 里还有运行时互斥作为第二道防线。 -->
    <key>LSMultipleInstancesProhibited</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# 签名：
# - 设置 CODESIGN_IDENTITY 时用 Developer ID 签名（正式分发 + 公证）
# - 否则 ad-hoc 签名，仅供本机使用
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    echo "签名: ${CODESIGN_IDENTITY}"
    codesign --force --options runtime --timestamp \
        --entitlements "$ROOT/menubar/entitlements.plist" \
        --sign "$CODESIGN_IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "✓ 已生成: $APP"
echo "  运行: open '$APP'"
