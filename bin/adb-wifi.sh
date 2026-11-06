#!/bin/bash
# =============================================================================
# adb-wifi.sh —— Android 无线调试(wireless debugging)自动连接守护脚本
#
# 自动发现已打开「无线调试」的 Android 设备，自动连接 / 掉线重连 / 随 Wi-Fi 变化重启 adb。
#
# 发现方式（自动降级，任一可用即可）:
#   1. mDNS   : adb mdns services  —— 标准 Android 11+ 广播（部分企业网/AP 隔离会失效）
#   2. USB    : 通过 USB 连接的设备，读取其 adbd 实际监听端口（100% 准确）
#   3. TCP    : 对已知 IP + 候选端口逐个探测（兜底）
#
# 用法:
#   adb-wifi.sh start     后台常驻启动（重复执行不会重复启动）
#   adb-wifi.sh stop      停止
#   adb-wifi.sh status    查看状态
#   adb-wifi.sh restart   重启
#   adb-wifi.sh log       实时查看日志(Ctrl-C 退出查看)
#   adb-wifi.sh once      前台跑一轮诊断（排查用）
# =============================================================================

set -uo pipefail

# ----------------------------- 可配置项 --------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
[ -f "$APP_DIR/config.sh" ] && . "$APP_DIR/config.sh"

ADB_BIN="${ADB_BIN:-$(command -v adb 2>/dev/null || echo "$HOME/Library/Android/sdk/platform-tools/adb")}"
[ -x "$ADB_BIN" ] || ADB_BIN="/opt/homebrew/bin/adb"

CHECK_INTERVAL="${CHECK_INTERVAL:-10}"   # 轮询间隔(秒)
TCP_TIMEOUT="${TCP_TIMEOUT:-3}"          # TCP 探测超时(秒)
MAX_TRIES="${MAX_TRIES:-3}"              # 单设备连续失败上限
CANDIDATE_PORTS="${CANDIDATE_PORTS:-5555 39795 39796 40795 41795 37075 38075 43075 44075 45075 46075 47075 35075 36075 39075}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-12}" # 单次 adb connect 超时(秒)

APP_SUPPORT="$HOME/Library/Application Support/adb-wifi-manager"
STATE_DIR="$APP_SUPPORT/state"
LOG_DIR="$APP_SUPPORT/logs"
LOG_FILE="$LOG_DIR/adb-wifi.log"
PID_FILE="$APP_SUPPORT/adb-wifi.pid"
KNOWN_FILE="$STATE_DIR/known_endpoints.txt"   # 历史连接成功过的 IP:PORT（跨重启保留）
MAX_LOG_BYTES=1048576

mkdir -p "$STATE_DIR" "$LOG_DIR"

# ----------------------------- 工具函数 --------------------------------------
log() {
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [$1] ${*:2}"
    # 日志只写文件；后台常驻时终端标准输出已重定向到日志文件，
    # 若再 echo 会重复一行。前台运行(oncelog)时由调用方显式输出。
    if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$MAX_LOG_BYTES" ]; then
        mv -f "$LOG_FILE" "$LOG_FILE.1"
    fi
    echo "$line" >> "$LOG_FILE"
    # 前台诊断模式才同时打到终端
    [ "${FOREGROUND:-0}" = "1" ] && echo "$line" >&2
    return 0
}
info()  { log INFO  "$@"; }
warn()  { log WARN  "$@"; }
error() { log ERROR "$@"; }

adbw() { "$ADB_BIN" "$@" 2>&1; }

# 带超时执行（macOS 无 timeout 命令，用 perl alarm 实现）
tmo() {
    local secs="$1"; shift
    perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
}

# 当前是否已有无线设备连接在 "device" 状态
wifi_devices() {
    "$ADB_BIN" devices 2>/dev/null | awk 'NR>1 && $2=="device" && $1 ~ /:[0-9]+$/ && $1 !~ /^\[/' | awk '{print $1}'
}

# 所有设备的序列号(含 USB 与无线)
all_serial() {
    "$ADB_BIN" devices 2>/dev/null | awk 'NR>1 && $2!="" {print $1}'
}

# 记录成功连接的端点
remember_endpoint() {
    local ep="$1"
    touch "$KNOWN_FILE"
    grep -qxF "$ep" "$KNOWN_FILE" 2>/dev/null || echo "$ep" >> "$KNOWN_FILE"
}

# 当前 Mac 主网卡 IP 与 /24 网段的网段前缀
lan_prefix() {
    local ip
    ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
    [ -n "$ip" ] && echo "${ip%.*}" || true
}

# ---------------------------------------------------------------- 发现: mDNS
# 输出格式: ip:port
discover_mdns() {
    local out
    out=$(tmo 8 "$ADB_BIN" mdns services 2>/dev/null) || return 0
    echo "$out" | awk '
        /_adb-tls-connect\._tcp|_adb\._tcp/ {
            port="";
            for (i=1;i<=NF;i++) if ($i ~ /^tcp\./) port=$i;
            if (port=="" ) { for (i=1;i<=NF;i++) if ($i ~ /\.tcp\./) {split($i,a,"."); port=a[length(a)]} }
            if (port!="") print $2 ":" port;
        }'
}

# ---------------------------------------------------------------- 发现: USB
# 通过 USB 连接的设备，读取其 adbd 在无线网络上监听的端口（由无线调试启动的那个进程）
discover_usb() {
    local serial="" wifi_ip="" port_line ports p
    for serial in $(all_serial); do
        case "$serial" in *:*|*.*.*.*:*) continue ;; esac   # 跳过网络设备
        [ "$(adbw -s "$serial" get-state)" = "device" ] || continue

        wifi_ip=$(adbw -s "$serial" shell 'ip -4 addr show wlan0 2>/dev/null | grep -oE "inet [0-9.]+" | head -1 | cut -d" " -f2' | tr -d '\r')
        [ -z "$wifi_ip" ] && wifi_ip=$(adbw -s "$serial" shell 'ip -4 route get 1.1.1.1 2>/dev/null | grep -oE "src [0-9.]+" | cut -d" " -f2' | tr -d '\r')

        # 找出对外(非 127.0.0.1)监听的 adbd 端口
        port_line=$(adbw -s "$serial" shell "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null" | tr -d '\r')
        [ -z "$port_line" ] && continue

        # ① 从 /proc/net/tcp{,6} 中取 LISTEN(0A) 状态的监听端口。
        #    adbd 的无线调试端口由 Android 随机分配，因此取「非回环、10000-65535」的监听端口，
        #    再通过 TCP 探测逐一验证。
        #    注意：macOS 自带 bash 3.2 在 $(...) 内解析 case 会报语法错误，
        #    这里统一用 if 替代 case，保证在任何 macOS 上开箱可用。
        ports=$(echo "$port_line" | awk 'NR>1 && $4=="0A"{split($2,a,":"); print a[1], a[2]}' | while read -r laddr hport; do
            p=$((16#$hport))
            # 排除回环监听：IPv4 0100007F / IPv6 ::1 编码为 ...0100007F
            if [ "$laddr" = "0100007F" ] || [ "$laddr" = "0000000000000000000000000100007F" ]; then
                :
            elif [ "$p" -ge 10000 ] && [ "$p" -le 65535 ]; then
                echo "$p"
            fi
        done | sort -un)

        [ -z "$wifi_ip" ] && { warn "USB 设备 $serial 未获取到 Wi-Fi IP（可能未连 Wi-Fi）" >&2; continue; }
        [ -z "$ports" ] && { warn "USB 设备 $serial 未发现对外监听的 adbd 端口（无线调试可能未开启）" >&2; continue; }

        local hit=""
        for p in $ports; do
            info "USB 设备 $serial 候选端口 $p，验证中 ..." >&2
            # ② 验证：该端口确实是 adb 协议端点（本地 Mac 侧 TCP 握手）
            if nc -z -G 2 -w 2 "$wifi_ip" "$p" 2>/dev/null; then
                hit="$p"; break
            fi
        done

        if [ -n "$hit" ]; then
            info "USB 设备 $serial 发现无线调试端点 $wifi_ip:$hit" >&2
            echo "$wifi_ip:$hit"
        else
            warn "USB 设备 $serial 未能验证出无线调试端口" >&2
        fi
    done
}

# ---------------------------------------------------------------- 发现: TCP
# 对已知端点(历史成功记录)做 TCP 连通性探测；不通的直接从记忆里清除
discover_known() {
    [ -f "$KNOWN_FILE" ] || return 0
    local ep ip port
    local -a stale=()
    while read -r ep; do
        [ -z "$ep" ] && continue
        ip="${ep%%:*}"; port="${ep##*:}"
        if nc -z -G "$TCP_TIMEOUT" -w "$TCP_TIMEOUT" "$ip" "$port" 2>/dev/null; then
            echo "$ep"
        else
            stale+=("$ep")
        fi
    done < "$KNOWN_FILE"

    # 清理不通的历史端点（日志走 stderr，避免污染给调用方的 stdout）
    if [ ${#stale[@]} -gt 0 ]; then
        local keep="$KNOWN_FILE.keep"
        : > "$keep"
        local e
        while read -r e; do
            [ -z "$e" ] && continue
            case " ${stale[*]} " in
                *" $e "*) info "清理失效记忆端点 $e" >&2 ;;
                *) echo "$e" >> "$keep" ;;
            esac
        done < "$KNOWN_FILE"
        mv -f "$keep" "$KNOWN_FILE"
    fi
    return 0
}

# ------------------------------------------------------------- 连接 & 重连
try_connect() {
    local ep="$1" out state
    info "尝试连接 $ep ..."
    out=$(tmo "$CONNECT_TIMEOUT" "$ADB_BIN" connect "$ep" 2>&1)
    info "  -> $out"

    # 注意：不使用 case 的 ;& 语法（需 bash 4+），macOS 自带的是 bash 3.2
    if echo "$out" | grep -q "already connected"; then
        info "  $ep 已连接，无需重复操作"
        remember_endpoint "$ep"
        return 0
    fi

    if echo "$out" | grep -q "connected to"; then
        # connect 返回成功后再做一次就绪校验（TCP 通了不代表 debug 鉴权通过）
        sleep 1
        state=$(adbw -s "$ep" get-state 2>/dev/null | tr -d '\r')
        if [ "$state" = "device" ]; then
            info "  ✓ 连接成功并已就绪: $ep"
            remember_endpoint "$ep"
            notify "✅ 已连接 Android 设备" "$ep"
            return 0
        fi
        warn "  connect 返回成功但设备状态为 '${state:-unknown}'（可能未授权或端口被占用）"
        return 1
    fi

    info "  ✗ 连接失败"
    return 1
}

# 失效端点从已知列表移除（设备重启后端口会变化）
forget_endpoint() {
    local ep="$1"
    [ -f "$KNOWN_FILE" ] || return 0
    grep -vxF "$ep" "$KNOWN_FILE" > "$KNOWN_FILE.tmp" 2>/dev/null && mv -f "$KNOWN_FILE.tmp" "$KNOWN_FILE"
    info "移除失效端点 $ep"
}

# macOS 通知（失败不影响主流程）
notify() {
    [ "${ENABLE_NOTIFY:-0}" = "1" ] || return 0
    osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true
}

# 重启 adb server（Wi-Fi 切换/睡眠唤醒后推荐）
restart_adb() {
    warn "重启 adb server ..."
    tmo 10 "$ADB_BIN" kill-server >/dev/null 2>&1
    sleep 1
    tmo 10 "$ADB_BIN" start-server >/dev/null 2>&1
    sleep 2
    info "adb server 已重启"
}

# --------------------------------------------------------------- 主循环
# 写一个"状态版本号"文件，供 TUI / 菜单栏做变更检测（内容无关，只看 mtime）
bump_state() {
    date +%s > "$STATE_DIR/state.version" 2>/dev/null || true
}

# 等待指定秒数，但若期间有设备变更事件则立即返回（实现毫秒级响应）
# 做法：后台 sleep 一份，同时以 0.25s 粒度检查事件文件 mtime；
# 一旦变化立刻杀掉 sleep 并返回，避免空转太久。
wait_or_event() {
    local secs="$1"
    local evf="$STATE_DIR/events.log"
    local start_ts now_ts i n
    start_ts=$(stat -f%m "$evf" 2>/dev/null || echo 0)
    if [ ! -f "$evf" ]; then
        : ; # 无事件文件则退化为普通 sleep
    fi
    n=$(( secs * 4 ))
    for i in $(seq 1 "$n"); do
        sleep 0.25
        now_ts=$(stat -f%m "$evf" 2>/dev/null || echo 0)
        if [ "$now_ts" != "$start_ts" ]; then
            info "检测到设备变更事件，立即响应"
            return 0
        fi
    done
    return 0
}

# ------------------------------------------------------------- 事件源
# 用 `adb track-devices` 监听设备增删/状态变化（毫秒级推送，替代轮询感知）
# 事件流格式: 每行 "序列号<TAB>状态"，如 "192.168.1.5:37001\tdevice"
start_device_tracker() {
    # 清掉旧的后台任务
    [ -n "${TRACKER_PID:-}" ] && kill "$TRACKER_PID" 2>/dev/null
    mkfifo "$STATE_DIR/events.fifo" 2>/dev/null || true
    (
        # 若 adb server 重启，track-devices 会断开，这里循环重连
        while true; do
            "$ADB_BIN" track-devices 2>/dev/null | while IFS= read -r line; do
                [ -z "$line" ] && continue
                echo "DEVENT $line" >> "$STATE_DIR/events.log"
                bump_state
            done
            sleep 1
        done
    ) >> "$LOG_FILE" 2>&1 &
    TRACKER_PID=$!
    info "设备事件监听已启动 (track-devices, PID $TRACKER_PID)"
}

main_loop() {
    echo $$ > "$PID_FILE"
    # 退出时只删除属于自己的 PID 文件，避免 restart 时误删新进程刚写入的 PID
    trap 'info "收到停止信号，退出"; [ -n "${TRACKER_PID:-}" ] && kill "$TRACKER_PID" 2>/dev/null; [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ] && rm -f "$PID_FILE"; exit 0' INT TERM

    local last_prefix="" last_usb_listing="" prefix="" fails=0
    local ep mdns_eps usb_eps known_eps candidates connected_eps

    info "========== adb-wifi-manager 启动 =========="
    info "adb: $ADB_BIN ($("$ADB_BIN" version 2>/dev/null | head -1))"
    info "轮询间隔: ${CHECK_INTERVAL}s (设备变更走事件推送，无需等待)"

    # 启动事件监听
    start_device_tracker

    while true; do
        # 1) Wi-Fi 网段变化 → 重启 adb，清空失效端点
        prefix=$(lan_prefix)
        if [ -n "$prefix" ] && [ -n "$last_prefix" ] && [ "$prefix" != "$last_prefix" ]; then
            warn "检测到网络变化 ($last_prefix.x -> $prefix.x)，重启 adb server"
            restart_adb
            [ -f "$KNOWN_FILE" ] && rm -f "$KNOWN_FILE"
        fi
        [ -n "$prefix" ] && last_prefix="$prefix"

        connected_eps=$(wifi_devices)

        # 2) 多路发现
        mdns_eps=$(discover_mdns)
        usb_eps=$(discover_usb)
        known_eps=$(discover_known)

        # 只接受合法的 IP:PORT，过滤非端点输出（防止提示文本混入被误当成设备）
        candidates=$(printf '%s\n%s\n%s\n' "$mdns_eps" "$usb_eps" "$known_eps" \
            | awk 'NF' \
            | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$' \
            | sort -u)

        if [ -z "$candidates" ] && [ -z "$connected_eps" ]; then
            info "未发现可用设备（请确认手机已开启「开发者选项 → 无线调试」且与本机同一 Wi-Fi）"
            fails=$((fails + 1))
            # 长时间无设备时，每小时重启一次 adb，避免 mDNS 守护卡死
            if [ $((fails % 360)) -eq 0 ]; then restart_adb; fi
            wait_or_event "$CHECK_INTERVAL"
            continue
        fi

        if [ -n "$candidates" ]; then info "候选端点: $(echo $candidates | tr '\n' ' ')"; fi

        # 3) 对每个候选：已就绪则跳过，否则连接
        local ok_any=0
        for ep in $candidates; do
            if echo "$connected_eps" | grep -qxF "$ep"; then
                ok_any=1; continue
            fi
            # 同 IP 已通过其他端口连上，跳过
            local ip="${ep%%:*}"
            if echo "$connected_eps" | grep -q "^${ip//./\\.}:"; then
                ok_any=1; continue
            fi
            if try_connect "$ep"; then
                ok_any=1
            else
                # 端点来自"记忆"且连不上 → 忘记它；来自实时发现则保留
                if echo "$known_eps" | grep -qxF "$ep" && ! echo "$mdns_eps $usb_eps" | grep -qF "$ep"; then
                    forget_endpoint "$ep"
                fi
            fi
        done

        # 4) 悬空断线清理：曾记录但现在不通的无线端点
        for ep in $connected_eps; do
            if ! tmo 5 "$ADB_BIN" -s "$ep" get-state >/dev/null 2>&1; then
                warn "设备 $ep 无响应，执行 disconnect 并等待重连"
                adbw disconnect "$ep" >/dev/null
            fi
        done

        connected_eps=$(wifi_devices)
        if [ -n "$connected_eps" ]; then
            info "当前在线(无线): $(echo $connected_eps | tr '\n' ' ')"
            fails=0
        else
            fails=$((fails + 1))
            warn "本轮未能建立连接（连续失败 $fails 次）"
            # 连续失败多次 → 重启 adb 后立即再试一次
            if [ "$fails" -ge "$MAX_TRIES" ] && [ $((fails % MAX_TRIES)) -eq 0 ]; then
                restart_adb
            fi
        fi

        wait_or_event "$CHECK_INTERVAL"
    done
}

# --------------------------------------------------------------- 子命令

# launchd 托管相关
LAUNCHD_LABEL="com.durunzhe.adb-wifi-manager"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"

launchd_loaded() { launchctl list "$LAUNCHD_LABEL" >/dev/null 2>&1; }

# 守护是否在跑（launchd 托管或手动 nohup 启动）
daemon_pid() {
    ps aux | grep -E "[a]db-wifi\.sh _daemon$" | awk '{print $2}' | head -1
}

cmd_start() {
    # 若已由 launchd 托管，交给 launchd 处理（避免双实例）
    if launchd_loaded; then
        launchctl kickstart "gui/$(id -u)/$LAUNCHD_LABEL" 2>/dev/null || \
            launchctl start "$LAUNCHD_LABEL" 2>/dev/null
        sleep 2
        echo "✓ 已由 launchd 启动 (PID $(daemon_pid))"
        return 0
    fi
    if [ -n "$(daemon_pid)" ]; then
        echo "已在运行 (PID $(daemon_pid))"
        return 0
    fi
    # 若安装过 launchd 配置，优先恢复托管，保证「开机自启」不丢失
    if [ -f "$LAUNCHD_PLIST" ]; then
        if launchctl load "$LAUNCHD_PLIST" 2>/dev/null; then
            sleep 3
            echo "✓ 已通过 launchd 启动 (PID $(daemon_pid), 开机自启)"
            return 0
        fi
    fi
    mkdir -p "$LOG_DIR"
    nohup "$0" _daemon >> "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 1
    if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "✓ 已启动 (PID $(cat "$PID_FILE"))"
        echo "  日志: $LOG_FILE"
    else
        echo "✗ 启动失败，请查看日志: $LOG_FILE"; tail -5 "$LOG_FILE"; exit 1
    fi
}

cmd_stop() {
    # launchd 托管时必须先 unload，否则进程会被 KeepAlive 立刻拉起
    if launchd_loaded; then
        launchctl unload "$LAUNCHD_PLIST" 2>/dev/null
        UNLOADED_LAUNCHD=1
        echo "✓ 已卸载 launchd 托管（重启后不会自动启动，可用 ./install.sh 恢复）"
    fi

    local pid i
    pid=$(daemon_pid)
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null
        # 等待进程真正退出（最多 5 秒），避免 restart 时新旧进程的 PID 文件互相覆盖
        for i in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
        done
        kill -9 "$pid" 2>/dev/null
        sleep 0.2
        rm -f "$PID_FILE"
        echo "✓ 已停止"
    else
        rm -f "$PID_FILE"
        # launchd 分支已经输出过卸载提示，避免重复说"未在运行"
        [ "${UNLOADED_LAUNCHD:-0}" = "1" ] || echo "未在运行"
    fi
}

cmd_status() {
    local dpid
    dpid=$(daemon_pid)
    if [ -n "$dpid" ]; then
        if launchd_loaded; then
            echo "状态: ● 运行中 (PID $dpid, launchd 托管, 开机自启)"
        else
            echo "状态: ● 运行中 (PID $dpid)"
        fi
    else
        echo "状态: ○ 已停止"
    fi
    echo "adb:  $ADB_BIN"
    echo "无线设备:"
    local d
    for d in $(wifi_devices); do echo "  ✓ $d"; done
    [ -z "$(wifi_devices)" ] && echo "  (无)"
    echo "记忆端点: ${KNOWN_FILE}"
    [ -f "$KNOWN_FILE" ] && sed 's/^/  - /' "$KNOWN_FILE"
    echo "日志(最近 15 行):"
    [ -f "$LOG_FILE" ] && tail -15 "$LOG_FILE" | sed 's/^/  /'
}

cmd_once() {
    echo "=== mDNS 发现 ==="; discover_mdns
    echo "=== USB 发现 ==="; discover_usb
    echo "=== 记忆端点连通性 ==="; discover_known
    echo "=== 当前 adb devices ==="; "$ADB_BIN" devices -l
}

# --------------------------------------------------------------- 诊断接口
# 输出 KEY=VALUE 形式的机器可读状态，供 TUI 使用
cmd_diag() {
    local dpid mdns_eps usb_eps known_eps usb_serial wifi_ip dev_state

    dpid=$(daemon_pid)
    echo "DAEMON_PID=${dpid:-}"
    if [ -n "$dpid" ]; then
        if launchd_loaded; then echo "DAEMON_MODE=launchd"; else echo "DAEMON_MODE=manual"; fi
    else
        echo "DAEMON_MODE=stopped"
    fi
    echo "ADB_BIN=$ADB_BIN"
    echo "CHECK_INTERVAL=$CHECK_INTERVAL"

    # 网络
    local mac_ip
    mac_ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
    echo "MAC_IP=${mac_ip:-}"

    # 已连接的无线设备
    local wired
    wired=$(wifi_devices | tr '\n' ',')
    echo "WIFI_DEVICES=${wired%,}"
    local all
    all=$("$ADB_BIN" devices 2>/dev/null | awk 'NR>1 && $2!="" {print $1"|"$2}' | tr '\n' ',')
    echo "ALL_DEVICES=${all%,}"

    # mDNS 是否可用：连续两次都没发现任何 adb 服务即判定可能被屏蔽
    mdns_eps=$(discover_mdns 2>/dev/null)
    echo "MDNS_FOUND=$(echo $mdns_eps | tr '\n' ',')"
    local raw_mdns
    raw_mdns=$(tmo 8 "$ADB_BIN" mdns services 2>/dev/null | grep -c "_adb" || true)
    echo "MDNS_ADB_COUNT=${raw_mdns:-0}"

    # USB 设备端信息
    usb_serial=""
    for s in $(all_serial); do
        case "$s" in *:*|*.*.*.*:*) continue ;; esac
        usb_serial="$s"; break
    done
    echo "USB_SERIAL=${usb_serial}"
    if [ -n "$usb_serial" ]; then
        echo "DEV_SDK=$(adbw -s "$usb_serial" shell getprop ro.build.version.sdk | tr -d '\r')"
        echo "DEV_MODEL=$(adbw -s "$usb_serial" shell getprop ro.product.model | tr -d '\r')"
        echo "DEV_ANDROID=$(adbw -s "$usb_serial" shell getprop ro.build.version.release | tr -d '\r')"
        _adb_wifi=$(adbw -s "$usb_serial" shell settings get global adb_wifi_enabled 2>/dev/null | tr -d '\r')
        _dev_opts=$(adbw -s "$usb_serial" shell settings get global development_settings_enabled 2>/dev/null | tr -d '\r')
        echo "DEV_ADB_WIFI_ENABLED=$_adb_wifi"
        echo "DEV_DEV_OPTS=$_dev_opts"
        wifi_ip=$(adbw -s "$usb_serial" shell 'ip -4 addr show wlan0 2>/dev/null | grep -oE "inet [0-9.]+" | head -1 | cut -d" " -f2' | tr -d '\r')
        echo "DEV_WIFI_IP=${wifi_ip}"
        echo "USB_FOUND=$(discover_usb 2>/dev/null | tr '\n' ',')"
    else
        echo "DEV_SDK="; echo "DEV_MODEL="; echo "DEV_ANDROID="
        echo "DEV_ADB_WIFI_ENABLED="; echo "DEV_DEV_OPTS="; echo "DEV_WIFI_IP="
        echo "USB_FOUND="
    fi

    known_eps=$(discover_known 2>/dev/null)
    echo "KNOWN_FOUND=$(echo $known_eps | tr '\n' ',')"
    echo "KNOWN_LIST=$( [ -f "$KNOWN_FILE" ] && tr '\n' ',' < "$KNOWN_FILE" )"

    # ---- 结构化诊断结论（TUI 与菜单栏 App 共用，避免两边判断不一致）----
    local level title hint action
    if [ -z "$dpid" ] && [ -z "$(wifi_devices)" ]; then
        level="warn"; title="守护未运行且无设备连接"; hint="点击「启动守护」开始自动连接"; action="start_daemon"
    elif [ -n "$(wifi_devices)" ] && [ "${raw_mdns:-0}" -gt 0 ]; then
        level="ok"; title="连接正常"; hint="mDNS 自动发现可用"; action=""
    elif [ -n "$(wifi_devices)" ]; then
        level="ok"; title="设备已连接（mDNS 被屏蔽）"; hint="靠记忆端点维持，端口变化后需重连"; action="manual_connect"
    elif [ -n "$usb_serial" ] && [ "${_dev_opts:-}" = "0" ]; then
        level="error"; title="手机「开发者选项」未开启"; hint="插着 USB，可在手机上自动打开设置页"; action="phone_dev_settings"
    elif [ -n "$usb_serial" ] && [ "${_adb_wifi:-}" = "0" ]; then
        level="error"; title="手机「无线调试」开关未打开"; hint="插着 USB，可在手机上自动打开设置页"; action="phone_wireless"
    elif [ -n "$usb_serial" ]; then
        level="warn"; title="USB 已连接，尚未建立无线连接"; hint="正在读取端口，稍候自动连接"; action="reconnect_now"
    elif [ "${raw_mdns:-0}" -gt 0 ]; then
        level="warn"; title="未发现设备（mDNS 正常）"; hint="请确认手机已开启无线调试且同一 Wi-Fi"; action="phone_dev_settings"
    else
        level="error"; title="未发现设备，且此网络屏蔽 mDNS"; hint="插 USB 自动读端口 / 手动输入 IP:端口"; action="usb_help"
    fi
    # 事件序号：设备事件每发生一次 +1，UI 可据此判断"是否有变化"
    echo "EVENT_SEQ=$(wc -l < "$STATE_DIR/events.log" 2>/dev/null | tr -d ' ' || echo 0)"
    echo "DIAG_LEVEL=$level"
    echo "DIAG_TITLE=$title"
    echo "DIAG_HINT=$hint"
    echo "DIAG_ACTION=$action"
    echo "MDNS_OK=$([ "${raw_mdns:-0}" -gt 0 ] && echo 1 || echo 0)"
}

case "${1:-}" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart)
        # 若原本由 launchd 托管，重启后要恢复托管，否则会退化成手动模式、丢失开机自启
        was_launchd=0; launchd_loaded && was_launchd=1
        cmd_stop
        if [ "$was_launchd" = "1" ]; then
            launchctl load "$LAUNCHD_PLIST" 2>/dev/null && echo "✓ 已恢复 launchd 托管"
            sleep 3
            echo "状态: ● 运行中 (PID $(daemon_pid))"
        else
            cmd_start
        fi
        ;;
    status)  cmd_status ;;
    log)     tail -f "$LOG_FILE" ;;
    once)    cmd_once ;;
    diag)    cmd_diag ;;
    _daemon) main_loop ;;
    *)
        cat <<'USAGE'
adb-wifi-manager —— Android 无线调试自动连接守护

  adb-wifi.sh start     后台常驻启动
  adb-wifi.sh stop      停止
  adb-wifi.sh restart   重启
  adb-wifi.sh status    查看状态与在线设备
  adb-wifi.sh log       实时查看日志
  adb-wifi.sh once      前台执行一轮发现（排查用）
USAGE
        ;;
esac
