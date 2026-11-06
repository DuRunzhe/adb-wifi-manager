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

# 生成图标资源（App 图标 .icns，与菜单栏使用同一个 SF Symbol）
echo "生成图标资源 ..."
swiftc -O -o "$BUILD/.gen-icon" "$ROOT/menubar/gen-icon.swift"
"$BUILD/.gen-icon" "$RES_SRC"
rm -f "$BUILD/.gen-icon"

echo "编译 main.swift ..."
swiftc -O \
    -o "$APP/Contents/MacOS/AdbWifiBar" \
    "$ROOT/menubar/main.swift"

# 打包 App 图标（菜单栏图标由系统 SF Symbol 直接渲染，无需图片文件）
cp "$RES_SRC/AdbWifiBar.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AdbWifiBar</string>
    <key>CFBundleDisplayName</key><string>ADB WiFi</string>
    <key>CFBundleIdentifier</key><string>com.durunzhe.adb-wifibar</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>AdbWifiBar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# 本地签名，避免每次运行的 Gatekeeper 提示
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "✓ 已生成: $APP"
echo "  运行: open '$APP'"
