#!/bin/bash
# 一键安装：注册开机自启 + 编译并安装菜单栏 App
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.durunzhe.adb-wifi-manager"

# 把 $HOME 前缀缩写为 ~，避免安装日志暴露本机用户名
shorten_path() {
    case "$1" in
        "$HOME") printf '~' ;;
        "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
        *) printf '%s' "$1" ;;
    esac
}
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
echo "✓ adb: $(shorten_path "$(command -v adb || echo "$ADB_DIR/adb")")"

# 2) 权限
chmod +x "$ROOT/bin/adb-wifi.sh"

# 记录脚本路径：菜单栏 App 启动时优先读这里，
# 保证解压到任意目录（而非约定的 ~/mycode/...）也能找到脚本。
STATE_DIR="$HOME/Library/Application Support/adb-wifi-manager"
mkdir -p "$STATE_DIR"
printf '%s\n' "$ROOT/bin/adb-wifi.sh" > "$STATE_DIR/script_path.txt"

# 3) 注册 launchd 开机自启
mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"
sed -e "s|__APP_DIR__|$ROOT|g" \
    -e "s|__LOG_DIR__|$LOG_DIR|g" \
    -e "s|__ADB_DIR__|$ADB_DIR|g" \
    "$ROOT/launchd/$LABEL.plist" > "$PLIST_DST"

launchctl unload "$PLIST_DST" >/dev/null 2>&1
launchctl load "$PLIST_DST"
echo "✓ 已注册开机自启: $(shorten_path "$PLIST_DST")"

# 4) 安装菜单栏 App：优先使用发布包自带的预编译版（无需 Xcode），
#    源码仓库则本地编译。
APP_SRC=""
if [ -d "$ROOT/prebuilt/AdbWifiBar.app" ]; then
    APP_SRC="$ROOT/prebuilt/AdbWifiBar.app"
    echo "✓ 使用发布包内预编译 App（通用二进制），跳过编译"
elif [ -x /usr/bin/swiftc ] || command -v swiftc >/dev/null 2>&1; then
    echo "编译菜单栏 App ..."
    if "$ROOT/menubar/build.sh"; then
        APP_SRC="$ROOT/build/AdbWifiBar.app"
    else
        echo "⚠ 菜单栏 App 编译失败，守护服务不受影响"
    fi
else
    echo "⚠ 未找到 swiftc（需安装 Xcode Command Line Tools），且无预编译 App，跳过菜单栏 App"
fi

# 替换 App 前先结束正在运行的旧实例：
# LaunchServices 对同一 bundle id 已有实例时会拒绝启动新副本，
# 若不先结束旧进程，安装后用户点开的仍是旧版本（菜单栏图标也不会变）。
stop_menubar_app() {
    local app="$HOME/Applications/AdbWifiBar.app"
    local exe="$app/Contents/MacOS/AdbWifiBar"
    [ -x "$exe" ] || return 0
    pgrep -f "^${exe}$" >/dev/null 2>&1 || return 0
    echo "结束正在运行的菜单栏 App ..."
    pkill -f "^${exe}$" 2>/dev/null || true
    # 给它 2 秒正常退出（会释放单实例锁），再强杀
    local i
    for i in 1 2 3 4; do
        pgrep -f "^${exe}$" >/dev/null 2>&1 || return 0
        sleep 0.5
    done
    pkill -9 -f "^${exe}$" 2>/dev/null || true
    sleep 0.5
    return 0
}

if [ -n "$APP_SRC" ] && [ -d "$APP_SRC" ]; then
    stop_menubar_app
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/AdbWifiBar.app"
    cp -R "$APP_SRC" "$HOME/Applications/"
    # 清掉可能残留的单实例锁（进程已退出时锁会自动释放，这里只防御异常情况）
    rm -f "$HOME/Library/Application Support/adb-wifi-manager/menubar.lock"
    echo "✓ 菜单栏 App 已安装到 ~/Applications/AdbWifiBar.app"
    echo "  可直接在访达中双击打开，或加入「登录项」"
fi

echo
echo "=============================="
echo " 完成！"
echo "=============================="
sleep 15
"$ROOT/bin/adb-wifi.sh" status
echo
echo "常用命令:"
echo "  $(shorten_path "$ROOT/bin/adb-wifi.sh") status    # 查看状态"
echo "  $(shorten_path "$ROOT/bin/adb-wifi.sh") stop      # 停止并取消开机自启"
echo "  $(shorten_path "$ROOT/bin/adb-wifi.sh") log       # 实时日志"
echo "  open ~/Applications/AdbWifiBar.app   # 打开菜单栏 App"
