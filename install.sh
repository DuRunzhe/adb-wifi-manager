#!/bin/bash
# 一键安装：注册开机自启 + 编译并安装菜单栏 App
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.durunzhe.adb-wifi-manager"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Application Support/adb-wifi-manager/logs"
ADB_DIR="$HOME/Library/Android/sdk/platform-tools"

echo "=============================="
echo " adb-wifi-manager 安装"
echo "=============================="

# 1) 检查 adb
if ! command -v adb >/dev/null 2>&1 && [ ! -x "$ADB_DIR/adb" ]; then
    echo "✗ 未找到 adb，请先安装 Android Platform Tools:"
    echo "    brew install --cask android-platform-tools"
    exit 1
fi
echo "✓ adb: $(command -v adb || echo "$ADB_DIR/adb")"

# 2) 权限
chmod +x "$ROOT/bin/adb-wifi.sh"

# 3) 注册 launchd 开机自启
mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"
sed -e "s|__APP_DIR__|$ROOT|g" \
    -e "s|__LOG_DIR__|$LOG_DIR|g" \
    -e "s|__ADB_DIR__|$ADB_DIR|g" \
    "$ROOT/launchd/$LABEL.plist" > "$PLIST_DST"

launchctl unload "$PLIST_DST" >/dev/null 2>&1
launchctl load "$PLIST_DST"
echo "✓ 已注册开机自启: $PLIST_DST"

# 4) 编译并安装菜单栏 App
echo "编译菜单栏 App ..."
if [ -x /usr/bin/swiftc ] || command -v swiftc >/dev/null 2>&1; then
    "$ROOT/menubar/build.sh" || echo "⚠ 菜单栏 App 编译失败，守护服务不受影响"
    if [ -d "$ROOT/build/AdbWifiBar.app" ]; then
        mkdir -p "$HOME/Applications"
        rm -rf "$HOME/Applications/AdbWifiBar.app"
        cp -R "$ROOT/build/AdbWifiBar.app" "$HOME/Applications/"
        echo "✓ 菜单栏 App 已安装到 ~/Applications/AdbWifiBar.app"
        echo "  可直接在访达中双击打开，或加入「登录项」"
    fi
else
    echo "⚠ 未找到 swiftc（需安装 Xcode Command Line Tools），跳过菜单栏 App"
fi

echo
echo "=============================="
echo " 完成！"
echo "=============================="
sleep 15
"$ROOT/bin/adb-wifi.sh" status
echo
echo "常用命令:"
echo "  $ROOT/bin/adb-wifi.sh status    # 查看状态"
echo "  $ROOT/bin/adb-wifi.sh stop      # 停止并取消开机自启"
echo "  $ROOT/bin/adb-wifi.sh log       # 实时日志"
echo "  open ~/Applications/AdbWifiBar.app   # 打开菜单栏 App"
