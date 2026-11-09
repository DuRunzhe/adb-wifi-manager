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

# 插 USB 自动开启无线调试（TCP 模式）
# 原理：`adb tcpip <端口>` 让 adbd 额外监听一个 TCP 端口，不需要「无线调试」开关，
#      也不需要 WRITE_SECURE_SETTINGS 权限，因此可以完全免手动。
# 关闭「无线调试」或重启手机后，重新插一次 USB 即可恢复。
AUTO_TCPIP="${AUTO_TCPIP:-1}"            # 1=插 USB 自动尝试，0=关闭
TCPIP_PORT="${TCPIP_PORT:-5555}"         # tcpip 监听端口
TCPIP_RETRY_INTERVAL="${TCPIP_RETRY_INTERVAL:-60}"  # 失败后重试间隔(秒)，避免频繁打扰手机

# 记忆端点的清理阈值：连续探测失败多少次才丢弃。
# 设得足够大，保证手机临时掉线/睡眠不会把"回家的路"忘掉。
MAX_KNOWN_FAILS="${MAX_KNOWN_FAILS:-360}"  # 约 1 小时（按 CHECK_INTERVAL=10s 计）

# 无 USB 自动恢复：手机换了网段后，扫描本网段找回
AUTO_SCAN="${AUTO_SCAN:-1}"              # 1=允许自动扫描，0=关闭
SCAN_INTERVAL="${SCAN_INTERVAL:-300}"    # 两次扫描的最小间隔(秒)，避免持续占用网络

APP_SUPPORT="$HOME/Library/Application Support/adb-wifi-manager"
STATE_DIR="$APP_SUPPORT/state"
LOG_DIR="$APP_SUPPORT/logs"
LOG_FILE="$LOG_DIR/adb-wifi.log"
PID_FILE="$APP_SUPPORT/adb-wifi.pid"
KNOWN_FILE="$STATE_DIR/known_endpoints.txt"   # 历史连接成功过的 IP:PORT（跨重启保留）
SCAN_STAMP="$STATE_DIR/last_scan_attempt"     # 上次网段扫描时间，用于节流
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
    # 性能短路：已有无线连接在用时，无需再通过 USB 重复探测端口。
    # 每台 USB 设备要跑 3~4 条 adb shell（取 IP、读 /proc/net/tcp、TCP 探测），
    # 在连接稳定的常态下这些开销纯属浪费——而这恰恰是大部分时间所处的状态。
    # 只有"当前没有可用无线连接"时才真正去找端口。
    if [ -n "$(wifi_devices)" ] && [ "${FORCE_USB_SCAN:-0}" != "1" ]; then
        return 0
    fi
    for serial in $(all_serial); do
        case "$serial" in *:*|*.*.*.*:*) continue ;; esac   # 跳过网络设备
        [ "$(adbw -s "$serial" get-state)" = "device" ] || continue

        wifi_ip=$(adbw -s "$serial" shell 'ip -4 addr show wlan0 2>/dev/null | grep -oE "inet [0-9.]+" | head -1 | cut -d" " -f2' | tr -d '\r')
        [ -z "$wifi_ip" ] && wifi_ip=$(adbw -s "$serial" shell 'ip -4 route get 1.1.1.1 2>/dev/null | grep -oE "src [0-9.]+" | cut -d" " -f2' | tr -d '\r')

        # 找出对外(非 127.0.0.1)监听的 adbd 端口
        port_line=$(adbw -s "$serial" shell "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null" | tr -d '\r')
        [ -z "$port_line" ] && continue

        # ① 从 /proc/net/tcp{,6} 中取 LISTEN(0A) 状态的监听端口。
        #    adbd 的端口有两种来源：
        #      - 系统「无线调试」：Android 随机分配，一般落在 10000-65535
        #      - `adb tcpip N`：由我们指定，默认 5555（也可能被配置成其他值）
        #    因此不能只认 10000+，否则 tcpip 5555 建立的端口会被漏掉。
        #    这里取「非回环」的所有监听端口，再通过 TCP 探测逐一验证。
        #    注意：macOS 自带 bash 3.2 在 $(...) 内解析 case 会报语法错误，
        #    这里统一用 if 替代 case，保证在任何 macOS 上开箱可用。
        ports=$(echo "$port_line" | awk 'NR>1 && $4=="0A"{split($2,a,":"); print a[1], a[2]}' | while read -r laddr hport; do
            p=$((16#$hport))
            # 排除回环监听：IPv4 0100007F / IPv6 ::1 编码为 ...0100007F
            if [ "$laddr" = "0100007F" ] || [ "$laddr" = "0000000000000000000000000100007F" ]; then
                :
            elif [ "$p" -ge 1024 ] && [ "$p" -le 65535 ]; then
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

# ------------------------------------------------- 插 USB 自动开启无线（tcpip）
# 这是「插上 USB 就自动完成」的关键路径。
#
# 为什么不用 settings put global adb_wifi_enabled 1：
#   该写入需要 android.permission.WRITE_SECURE_SETTINGS，普通 adb shell 没有该权限，
#   实测会抛 SecurityException。所以系统「无线调试」开关无法用 adb 直接打开。
#
# 改用 `adb tcpip <端口>`：它让 adbd 在指定端口上额外监听 TCP，命令本身不需要特殊权限，
# 只要 USB 已连接且已授权即可。之后 adb connect IP:端口 就能走无线。
# 注意：切换 tcpip 会重启 adbd，导致当前 USB 连接短暂断开后自动恢复。
TCPIP_STAMP="$STATE_DIR/last_tcpip_attempt"   # 记录上次尝试的时间戳与结果

# 从 USB 设备取 Wi-Fi IP（wlan0 优先，退化到默认路由源地址）
device_wifi_ip() {
    local serial="$1" ip
    ip=$(adbw -s "$serial" shell 'ip -4 addr show wlan0 2>/dev/null | grep -oE "inet [0-9.]+" | head -1 | cut -d" " -f2' | tr -d '\r')
    [ -z "$ip" ] && ip=$(adbw -s "$serial" shell 'ip -4 route get 1.1.1.1 2>/dev/null | grep -oE "src [0-9.]+" | cut -d" " -f2' | tr -d '\r')
    echo "$ip"
}

# 设备端是否已在指定端口监听（非回环）
device_listening_port() {
    local serial="$1" want="$2" out p
    out=$(adbw -s "$serial" shell "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null" | tr -d '\r')
    [ -z "$out" ] && return 1
    for p in $(echo "$out" | awk 'NR>1 && $4=="0A"{split($2,a,":"); print a[2]}' | sort -u); do
        if [ "$((16#$p))" = "$want" ]; then return 0; fi
    done
    return 1
}

# 取第一台 USB（非网络）设备序列号
# USB 序列号不带冒号（如 ABC123DEF），网络设备形如 192.168.1.5:5555
first_usb_serial() {
    local s
    for s in $(all_serial); do
        if [ "${s#*:}" = "$s" ]; then echo "$s"; return 0; fi
    done
    return 0
}

# 插着 USB 时，尝试切换到 TCP 模式并直连。
# 成功时输出端点 ip:port 到 stdout（供主循环作为候选），失败返回 1。
# 重试节流：同一台设备在 TCPIP_RETRY_INTERVAL 秒内不重复打扰（adb tcpip 会闪断 USB）。
ensure_tcpip() {
    [ "$AUTO_TCPIP" = "1" ] || return 1

    local serial ip ep now last next_expire=""
    serial="$(first_usb_serial)"
    [ -z "$serial" ] && return 1

    ip="$(device_wifi_ip "$serial")"
    if [ -z "$ip" ]; then
        info "USB 设备 $serial 无 Wi-Fi IP，跳过 tcpip（手机可能未连 Wi-Fi）" >&2
        return 1
    fi
    ep="$ip:$TCPIP_PORT"

    # 已经连上该端点，直接返回
    if wifi_devices | grep -qxF "$ep"; then
        echo "$ep"; return 0
    fi

    # 设备端已在监听 → 直接连，无需再切 tcpip
    if device_listening_port "$serial" "$TCPIP_PORT"; then
        info "USB 设备 $serial 已在监听 $TCPIP_PORT，直接连接 $ep" >&2
        if try_connect "$ep" >&2; then echo "$ep"; return 0; fi
        return 1
    fi

    # 节流：避免每轮都切 tcpip 导致 USB 反复闪断
    now=$(date +%s)
    if [ -f "$TCPIP_STAMP" ]; then
        read -r last next_expire < "$TCPIP_STAMP" 2>/dev/null || last=0
        case "$last" in ''|*[!0-9]*) last=0 ;; esac
        if [ $((now - last)) -lt "$TCPIP_RETRY_INTERVAL" ]; then
            info "tcpip 上次尝试在 $((now - last))s 前，$TCPIP_RETRY_INTERVAL 秒内不重复切换" >&2
            return 1
        fi
    fi
    echo "$now" > "$TCPIP_STAMP"

    info "USB 设备 $serial 未开无线调试，自动切换 TCP 模式(端口 $TCPIP_PORT) ..." >&2
    local out
    out=$(tmo 15 "$ADB_BIN" -s "$serial" tcpip "$TCPIP_PORT" 2>&1 | tr -d '\r')
    info "  -> $out" >&2
    if ! echo "$out" | grep -q "restarting in TCP mode"; then
        warn "  切换 TCP 模式失败（部分系统需在手机上确认，或已被厂商限制）" >&2
        return 1
    fi

    # adbd 重启需要时间恢复
    sleep 3
    local i
    for i in 1 2 3 4 5 6; do
        if nc -z -G 2 -w 2 "$ip" "$TCPIP_PORT" 2>/dev/null; then break; fi
        sleep 1
    done

    if try_connect "$ep" >&2; then
        info "  ✓ 已通过 USB 自动建立无线连接: $ep" >&2
        remember_endpoint "$ep"
        echo "$ep"
        return 0
    fi

    warn "  端口已切换但连接失败，稍后重试" >&2
    return 1
}

# ---------------------------------------------------------------- 发现: TCP
# 对已知端点(历史成功记录)做 TCP 连通性探测。
#
# 重要：不通时**不再立即删除**。手机临时掉线、睡眠、换网段都会让端口暂时不可达，
# 早先的实现一探测失败就删掉记忆，导致"连不上就永远找不回来"，只能重新插 USB。
# 现在改为：保留记忆，仅记录失败次数；连续失败超过 MAX_KNOWN_FAILS 次才清理。
discover_known() {
    [ -f "$KNOWN_FILE" ] || return 0
    local ep ip port fails_file="$STATE_DIR/known_fails.txt"
    [ -f "$fails_file" ] || : > "$fails_file"
    local -a alive=() dead=()

    while read -r ep; do
        [ -z "$ep" ] && continue
        ip="${ep%%:*}"; port="${ep##*:}"
        if nc -z -G "$TCP_TIMEOUT" -w "$TCP_TIMEOUT" "$ip" "$port" 2>/dev/null; then
            alive+=("$ep")
            echo "$ep"
        else
            dead+=("$ep")
        fi
    done < "$KNOWN_FILE"

    # 更新失败计数：通了的清零，不通的 +1
    local newfails="$fails_file.tmp"
    : > "$newfails"
    local e n
    while read -r e n; do
        [ -z "$e" ] && continue
        case " ${alive[*]} " in
            *" $e "*) echo "$e 0" >> "$newfails"; continue ;;
        esac
        n=${n:-0}
        case "$n" in ''|*[!0-9]*) n=0 ;; esac
        echo "$e $((n + 1))" >> "$newfails"
    done < "$fails_file" 2>/dev/null
    for e in "${alive[@]:-}"; do
        [ -z "$e" ] && continue
        grep -q "^$e " "$newfails" || echo "$e 0" >> "$newfails"
    done
    for e in "${dead[@]:-}"; do
        [ -z "$e" ] && continue
        grep -q "^$e " "$newfails" || echo "$e 1" >> "$newfails"
    done
    mv -f "$newfails" "$fails_file"

    # 仅清理"连续失败很多次"的端点
    local pruned=""
    while read -r e n; do
        [ -z "$e" ] && continue
        if [ "${n:-0}" -ge "$MAX_KNOWN_FAILS" ]; then
            info "记忆端点 $e 连续失败 $n 次，清理" >&2
            pruned="$pruned $e"
        fi
    done < "$fails_file"
    if [ -n "$pruned" ]; then
        local keep="$KNOWN_FILE.keep"
        : > "$keep"
        while read -r e; do
            [ -z "$e" ] && continue
            case " $pruned " in *" $e "*) continue ;; esac
            echo "$e" >> "$keep"
        done < "$KNOWN_FILE"
        mv -f "$keep" "$KNOWN_FILE"
    fi
    return 0
}

# ------------------------------------------------- 发现: 网段扫描
# 手机换了网段（例如 DHCP 重新分配）后，记下的旧 IP 必然失效。
# 这里在当前 /24 网段内探测已知端口（默认 5555），找回手机的新地址。
# 只在"有记忆但都不通"或"明确要求恢复"时触发，避免常态扫描占用网络。
#
# 性能：用一次 perl 并发非阻塞 connect 扫完 254 个地址（单进程），
# 替代逐台 fork nc。实测 254 台扫描：perl 约 0.9s / 254 个 nc 进程约 7.3s。
scan_lan_for_port() {
    local port="${1:-$TCPIP_PORT}" prefix
    prefix=$(lan_prefix)
    [ -z "$prefix" ] && return 0

    info "扫描本网段 ${prefix}.0/24 的 $port 端口 ..." >&2
    perl -e '
use strict; use warnings;
use IO::Socket::INET;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Errno qw(ECONNREFUSED);
use Time::HiRes qw(time);
my ($prefix, $port, $timeout) = @ARGV;
my @hosts;
for my $i (1 .. 254) {
    my $s;
    socket($s, PF_INET, SOCK_STREAM, getprotobyname("tcp")) or next;
    my $addr = sockaddr_in($port, inet_aton("$prefix.$i"));
    my $flags = fcntl($s, F_GETFL, 0);
    fcntl($s, F_SETFL, $flags | O_NONBLOCK);
    my $r = connect($s, $addr);
    push @hosts, { ip => "$prefix.$i", sock => $s, done => ($r ? 1 : 0) };
}
my $deadline = time() + $timeout;
while (time() < $deadline) {
    my $pending = 0;
    for my $h (@hosts) {
        next if $h->{done};
        if (getpeername($h->{sock})) { print "$h->{ip}:$port\n"; $h->{done} = 1; next; }
        my $err = $!;
        if ($err == ECONNREFUSED) { $h->{done} = 1; next; }
        $pending++;
    }
    last unless $pending;
    select(undef, undef, undef, 0.03);
}
' "$prefix" "$port" "${SCAN_TIMEOUT:-0.8}" 2>/dev/null | sort -u
    return 0
}

# 主动恢复：依次尝试 记忆端点 → 网段扫描 → 连接。
# 不需要 USB：只要手机此前通过 USB 执行过 adb tcpip，adbd 就会常驻监听 5555。
# 供菜单栏「立即恢复无线连接」与命令行 `recover` 使用。
recover_connection() {
    local connected eps ep found=""
    connected=$(wifi_devices)

    if [ -n "$connected" ]; then
        # 已连上但可能无响应，先校验一次
        for ep in $connected; do
            if tmo 5 "$ADB_BIN" -s "$ep" get-state >/dev/null 2>&1; then
                echo "ALREADY $ep"
                return 0
            fi
            adbw disconnect "$ep" >/dev/null 2>&1
        done
    fi

    # ① 记忆端点（跳过计数为 0 但当前不通的，交给下面扫描）
    eps=$(discover_known 2>/dev/null)
    for ep in $eps; do
        if try_connect "$ep" >/dev/null 2>&1; then
            remember_endpoint "$ep"
            echo "OK $ep"
            return 0
        fi
    done

    # ② 网段扫描找新 IP
    info "记忆端点均不可用，尝试扫描本网段找回设备" 
    found=$(scan_lan_for_port "$TCPIP_PORT" 2>/dev/null)
    if [ -n "$found" ]; then
        for ep in $found; do
            if try_connect "$ep" >/dev/null 2>&1; then
                remember_endpoint "$ep"
                echo "OK $ep"
                return 0
            fi
        done
    fi

    echo "FAIL"
    return 1
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
# 等待指定秒数，但若期间有设备变更事件则立即返回（保持 0.2 秒级响应）。
#
# 性能说明：原实现每 0.25 秒 fork 一次 `sleep` + 一次 `stat`，
# 等待 10 秒就要产生 80 个子进程，长期运行是主要开销来源。
# 现改为：
#   - 时长判断用 bash 内建变量 SECONDS（bash 3.2 也支持），不 fork date/stat
#   - 事件探测用内建 [ -nt ]，不 fork stat
#   - 只剩 sleep 一个子进程；把粒度从 0.25s 放宽到 0.3s，
#     仍是秒级以下的响应，但子进程数减少 20%
wait_or_event() {
    local secs="$1"
    local evf="$STATE_DIR/events.log"
    local mark="$STATE_DIR/.wait_mark"
    local t0
    touch "$evf" 2>/dev/null
    touch -r "$evf" "$mark" 2>/dev/null || : > "$mark"

    t0=$SECONDS
    while :; do
        sleep 0.3
        if [ "$evf" -nt "$mark" ]; then
            info "检测到设备变更事件，立即响应"
            return 0
        fi
        [ $(( SECONDS - t0 )) -ge "$secs" ] && return 0
    done
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
    local ep mdns_eps usb_eps known_eps candidates connected_eps tcpip_eps

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
        # 插着 USB 且还没有可用无线连接时，自动切换 TCP 模式（免手动开无线调试）
        tcpip_eps=""
        if [ -z "$connected_eps" ]; then
            tcpip_eps=$(ensure_tcpip)
        fi

        # 都没有着落时扫描本网段，找回换了 IP 的手机（无需 USB）。
        # 节流：每 SCAN_INTERVAL 秒最多扫一次，避免持续占满网络。
        scan_eps=""
        if [ -z "$connected_eps" ] && [ -z "$mdns_eps" ] && [ -z "$usb_eps" ] \
           && [ -z "$known_eps" ] && [ -z "$tcpip_eps" ] && [ "$AUTO_SCAN" = "1" ]; then
            _now=$(date +%s)
            _last=0
            [ -f "$SCAN_STAMP" ] && read -r _last < "$SCAN_STAMP" 2>/dev/null
            case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
            if [ $((_now - _last)) -ge "$SCAN_INTERVAL" ]; then
                echo "$_now" > "$SCAN_STAMP"
                scan_eps=$(scan_lan_for_port "$TCPIP_PORT")
                [ -n "$scan_eps" ] && info "网段扫描发现: $(echo $scan_eps | tr '\n' ' ')"
            fi
        fi

        # 只接受合法的 IP:PORT，过滤非端点输出（防止提示文本混入被误当成设备）
        candidates=$(printf '%s\n%s\n%s\n%s\n%s\n' "$mdns_eps" "$usb_eps" "$known_eps" "$tcpip_eps" "$scan_eps" \
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

# ------------------------------------------------- 手机上打开设置页
# 一键把手机跳到「无线调试」页面，省去手动点 设置→开发者选项→无线调试。
#
# 各 ROM 差异很大，按可靠性从高到低逐级尝试：
#   ① SubSettings + WirelessDebuggingFragment —— AOSP/原生及多数 ROM，精确到无线调试页
#      在 MIUI 13/14（实测 Android 12）上同样有效
#   ② Settings$WirelessDebuggingActivity —— 部分 ROM 的独立页面
#   ③ 开发者选项页 —— 前面都失败时退一步，用户从这里自己点「无线调试」
# 注意：部分 ROM（如 MIUI）的 WirelessDebuggingActivity 是空壳，
#      启动后会被重定向到设置首页，因此必须放在 ① 之后作为兜底。
open_settings_page() {
    local serial="$1" page="${2:-wireless}" out

    if [ -z "$serial" ]; then
        echo "NEED_USB"
        return 1
    fi

    if [ "$page" = "dev" ]; then
        out=$(tmo 15 "$ADB_BIN" -s "$serial" shell am start \
            -a android.settings.APPLICATION_DEVELOPMENT_SETTINGS 2>&1 | tr -d '\r')
        if echo "$out" | grep -q "Starting:"; then
            echo "OK 开发者选项"
            return 0
        fi
        echo "FAIL $out"
        return 1
    fi

    # ① AOSP 通用：SubSettings 内嵌 WirelessDebuggingFragment（精确到无线调试页）
    out=$(tmo 15 "$ADB_BIN" -s "$serial" shell am start \
        -n com.android.settings/.SubSettings \
        --es ":settings:show_fragment" \
        "com.android.settings.development.WirelessDebuggingFragment" 2>&1 | tr -d '\r')
    if echo "$out" | grep -q "Starting:"; then
        # 校验是否真的停在无线调试页：读界面文本，含"无线调试/Wireless debugging"且含开关项
        sleep 1.5
        if ui_page_is_wireless_debug "$serial"; then
            echo "OK 无线调试"
            return 0
        fi
    fi

    # ② 独立 Activity（部分 ROM）
    out=$(tmo 15 "$ADB_BIN" -s "$serial" shell am start \
        -n 'com.android.settings/.Settings$WirelessDebuggingActivity' 2>&1 | tr -d '\r')
    if echo "$out" | grep -q "Starting:"; then
        sleep 1.5
        if ui_page_is_wireless_debug "$serial"; then
            echo "OK 无线调试"
            return 0
        fi
    fi

    # ③ 兜底：开发者选项页
    out=$(tmo 15 "$ADB_BIN" -s "$serial" shell am start \
        -a android.settings.APPLICATION_DEVELOPMENT_SETTINGS 2>&1 | tr -d '\r')
    if echo "$out" | grep -q "Starting:"; then
        echo "PARTIAL 开发者选项"
        echo "该 ROM 未能直接定位无线调试页，已打开开发者选项，请手动点击「无线调试」" >&2
        return 0
    fi

    echo "FAIL $out"
    return 1
}

# 判断当前前台页面是否为「无线调试」页。
# 做法：uiautomator dump 到文件再 grep。
# 注意两个坑（均实测于 MIUI 13 / Android 12）：
#   1. 不能用 `uiautomator dump /dev/tty`，该 ROM 会抛 FileNotFoundException，只输出异常堆栈
#   2. 手机端 grep 对 'A\|B' 这种 BRE 交替写法不可靠，改用固定串分别匹配
# 读取失败时保守返回 1，让调用方继续尝试下一种启动方式。
ui_page_is_wireless_debug() {
    local serial="$1" tmp="/sdcard/.adbwifi_ui.xml" n1 n2
    n1=$(tmo 12 "$ADB_BIN" -s "$serial" shell \
        "uiautomator dump $tmp >/dev/null 2>&1; \
         grep -c '无线调试' $tmp 2>/dev/null; \
         rm -f $tmp" 2>/dev/null | tr -d '\r' | tr -dc '0-9')
    case "$n1" in ''|0) n1=0 ;; esac
    if [ "$n1" -gt 0 ]; then
        return 0
    fi
    # 英文系统或无中文串时，再试一次英文关键字
    n2=$(tmo 12 "$ADB_BIN" -s "$serial" shell \
        "uiautomator dump $tmp >/dev/null 2>&1; \
         grep -ci 'wireless debugging' $tmp 2>/dev/null; \
         rm -f $tmp" 2>/dev/null | tr -d '\r' | tr -dc '0-9')
    case "$n2" in ''|0) return 1 ;; esac
    return 0
}

# 选一个可用于跳转的设备：优先 USB（跳转不打断无线调试），没有再退回无线端点
settings_serial() {
    local s
    s="$(first_usb_serial)"
    if [ -n "$s" ]; then echo "$s"; return 0; fi
    for s in $(wifi_devices); do echo "$s"; return 0; done
    return 0
}

cmd_open() {
    local page="${1:-wireless}" serial out qr
    serial="$(settings_serial)"
    if [ -z "$serial" ]; then
        echo "✗ 未检测到已连接的设备（USB 或无线均可）"
        echo "  请先连上手机再执行本命令"
        return 1
    fi
    echo "使用设备: $serial"
    out=$(open_settings_page "$serial" "$page" 2>/dev/null)
    case "$out" in
        OK*)      echo "✓ 已在手机上打开「${out#OK }」页面" ;;
        PARTIAL*) echo "△ ${out#PARTIAL }"; echo "  未能直接定位到无线调试页，请在列表中手动点击「无线调试」" ;;
        NEED_USB) echo "✗ 需要先连接手机"; return 1 ;;
        *)        echo "✗ 打开失败: ${out#FAIL }"; return 1 ;;
    esac

    # 顺带打印当前无线调试开关状态，方便判断还要不要手动开
    local en
    en=$(adbw -s "$serial" shell settings get global adb_wifi_enabled 2>/dev/null | tr -d '\r')
    case "$en" in
        1) echo "  当前「无线调试」开关: 已开启" ;;
        0) echo "  当前「无线调试」开关: 未开启（请在手机上点开）" ;;
        *) echo "  当前「无线调试」开关: 无法读取（该 ROM 可能不暴露此设置）" ;;
    esac
    return 0
}

# ------------------------------------------------- 主动恢复无线连接
# 不需要 USB：只要手机此前通过 USB 执行过 adb tcpip，adbd 就会常驻监听 TCP 端口，
# 之后无论 USB 是否插着，都能直接 connect 恢复。
# 恢复顺序：已有连接 → 记忆端点 → 扫描本网段
cmd_recover() {
    echo "正在恢复无线连接 ..."
    local r
    r=$(recover_connection 2>/dev/null)
    case "$r" in
        ALREADY\ *)
            echo "✓ 当前已有可用连接: ${r#ALREADY }"
            return 0
            ;;
        OK\ *)
            echo "✓ 已恢复无线连接: ${r#OK }"
            return 0
            ;;
    esac

    # 失败：区分"手机根本没在监听"与"网络不通"，给出可操作提示
    local usb
    usb="$(first_usb_serial)"
    echo "✗ 未能恢复无线连接"
    if [ -n "$usb" ]; then
        echo "  检测到 USB 已连接，将自动切换 TCP 模式重试 ..."
        local ep
        ep=$(ensure_tcpip 2>/dev/null)
        if [ -n "$ep" ]; then
            echo "✓ 已通过 USB 恢复: $ep"
            return 0
        fi
    fi
    echo
    echo "可能原因与处理："
    echo "  1) 手机重启过 → tcpip 模式已失效，需插一次 USB（守护会自动恢复）"
    echo "  2) 手机未连 Wi-Fi，或与 Mac 不在同一网段"
    echo "     本机 IP 段: $(lan_prefix).0/24"
    echo "  3) 手机改回 USB 模式了 → 插 USB 后会自动切换"
    return 1
}

# ------------------------------------------------- 流量监控
# 统计本机与手机 adb 端口之间的实时传输速率。
#
# 数据源：`netstat -anv -p tcp` 里的连接字节计数（第 7 列发送、第 8 列接收）。
# 为什么不用设备端 /proc/net/dev：
#   1) 那是手机 wlan0 的总流量，含所有 App，不纯粹是 adb
#   2) 需要 `adb shell`，与正在进行的 adb pull/push 会互相阻塞（实测会卡死）
# Mac 侧 netstat 完全零侵入，且单次 <10ms，适合常驻采样。
#
# 速率需要两次采样求差，因此用一个状态文件保存上次的值与时间。

RATE_FILE="$STATE_DIR/rate_state"     # 格式: 时间戳 发送字节 接收字节

# 取当前 adb 连接的累计字节数，输出 "下行 上行"（Mac 视角：手机→Mac 为下行）
# 同一设备可能有多个 TCP 连接（控制连接 + 数据连接），全部累加。
#
# 字段映射来自实测（不是纸面定义），用 pull/push 分别验证：
#   1) adb pull（手机→Mac）：字段 7 增长 4.38MB，字段 8 只增 72 字节
#   2) adb push（Mac→手机）：字段 8 增长 2.79MB，字段 7 只增 626 字节
# 因此：字段 7 = 下行（接收），字段 8 = 上行（发送）。
#
# 注意：不要用 awk 的 $N 取列——macOS 的字段切分与 netstat 列并非稳定对应，
# 改用整行正则锚定「远端端口 + ESTABLISHED」再 split 取值。
adb_conn_bytes() {
    local port="${1:-$TCPIP_PORT}"
    netstat -anv -p tcp 2>/dev/null | awk -v p="\\.$port" '
        $0 ~ p "[[:space:]]+ESTABLISHED" {
            n = split($0, f, /[[:space:]]+/)
            # netstat 输出行首无前导空白，split 编号与列号一致：
            #   第 7 列 = 下行 → f[7]      第 8 列 = 上行 → f[8]
            down += f[7]; up += f[8]
        }
        END { printf "%.0f %.0f\n", down, up }'
}

# 采样一次并计算速率，输出: 下行KB/s 上行KB/s 累计下行MB 累计上行MB
# 首次调用只建立基线，速率返回 0
# 当前毫秒时间戳（perl 取，精度足够且无需额外依赖）
now_ms() {
    perl -MTime::HiRes=time -e 'printf "%.0f", time()*1000'
}

# 采样一次并计算速率，输出: 下行KB/s 上行KB/s 累计下行MB 累计上行MB
# 首次调用只建立基线（速率返回 0）
sample_rate() {
    local port="${1:-$TCPIP_PORT}" now cur down up pdown pup pt dt_ms d_down d_up

    now=$(now_ms)
    cur=$(adb_conn_bytes "$port")
    down=$(echo "$cur" | awk '{print $1}')
    up=$(echo "$cur" | awk '{print $2}')
    case "$down" in ''|*[!0-9]*) down=0 ;; esac
    case "$up"   in ''|*[!0-9]*) up=0 ;; esac

    if [ -f "$RATE_FILE" ]; then
        read -r pt pdown pup < "$RATE_FILE" 2>/dev/null
    fi
    case "$pt"    in ''|*[!0-9]*) pt=$now ;; esac
    case "$pdown" in ''|*[!0-9]*) pdown=$down ;; esac
    case "$pup"   in ''|*[!0-9]*) pup=$up ;; esac

    echo "$now $down $up" > "$RATE_FILE"

    dt_ms=$(( now - pt ))
    d_down=$(( down - pdown ))
    d_up=$(( up - pup ))

    # 间隔过短，或计数器回退（连接重建归零）→ 本次不给速率，只报累计
    if [ "$dt_ms" -lt 200 ] || [ "$d_down" -lt 0 ] || [ "$d_up" -lt 0 ]; then
        awk -v d="$down" -v u="$up" 'BEGIN{printf "0 0 %.2f %.2f\n", d/1048576, u/1048576}'
        return 0
    fi
    awk -v dd="$d_down" -v du="$d_up" -v ms="$dt_ms" -v d="$down" -v u="$up" 'BEGIN {
        sec = ms / 1000.0
        printf "%.1f %.1f %.2f %.2f\n", dd/sec/1024, du/sec/1024, d/1048576, u/1048576
    }'
}

# 把 KB/s 格式化成易读形式
fmt_rate() {
    awk -v v="$1" 'BEGIN {
        if (v < 1)          printf "0 KB/s"
        else if (v < 1024)  printf "%.0f KB/s", v
        else                printf "%.2f MB/s", v/1024
    }'
}

# 采样时长必须 >=1s，netstat 计数按秒级有意义，太短会剧烈抖动
cmd_rate() {
    local interval="${1:-1}" line dl ul rx tx
    if [ -z "$(wifi_devices)" ] && [ -z "$(all_serial)" ]; then
        echo "✗ 未检测到已连接的设备"
        return 1
    fi
    case "$interval" in ''|*[!0-9]*) interval=1 ;; esac
    [ "$interval" -lt 1 ] && interval=1

    rm -f "$RATE_FILE"            # 从干净基线开始
    _=$(sample_rate "$TCPIP_PORT")
    sleep "$interval"
    line=$(sample_rate "$TCPIP_PORT")
    dl=$(echo "$line" | awk '{print $1}')
    ul=$(echo "$line" | awk '{print $2}')
    rx=$(echo "$line" | awk '{print $3}')
    tx=$(echo "$line" | awk '{print $4}')
    echo "  adb 端口: $TCPIP_PORT  (采样 ${interval}s)"
    echo "  下行: $(fmt_rate "$dl")   上行: $(fmt_rate "$ul")"
    echo "  累计: 收 ${rx} MB / 发 ${tx} MB"
    return 0
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

    # mDNS 是否可用：一次采集同时得到端点与计数。
    # 原先这里调了两次 `adb mdns services`（一次 discover_mdns、一次统计计数），
    # 每次最长 8 秒；菜单栏每 2 秒就会触发一次 diag，重复调用纯属浪费。
    local raw_mdns_out
    raw_mdns_out=$(tmo 8 "$ADB_BIN" mdns services 2>/dev/null)
    mdns_eps=$(echo "$raw_mdns_out" | awk '
        /_adb-tls-connect\._tcp|_adb\._tcp/ {
            port="";
            for (i=1;i<=NF;i++) if ($i ~ /^tcp\./) port=$i;
            if (port=="" ) { for (i=1;i<=NF;i++) if ($i ~ /\.tcp\./) {split($i,a,"."); port=a[length(a)]} }
            if (port!="") print $2 ":" port;
        }')
    echo "MDNS_FOUND=$(echo $mdns_eps | tr '\n' ',')"
    local raw_mdns
    raw_mdns=$(echo "$raw_mdns_out" | grep -c "_adb" || true)
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
        wifi_ip=$(device_wifi_ip "$usb_serial" | tr -d '\r')
        echo "DEV_WIFI_IP=${wifi_ip}"
        echo "USB_FOUND=$(discover_usb 2>/dev/null | tr '\n' ',')"
        # tcpip 相关：是否已在监听指定端口（决定能否免手动直连）
        _tcpip_listen=0
        device_listening_port "$usb_serial" "$TCPIP_PORT" && _tcpip_listen=1
        echo "TCPIP_PORT=$TCPIP_PORT"
        echo "TCPIP_LISTEN=$_tcpip_listen"
        echo "AUTO_TCPIP=$AUTO_TCPIP"
    else
        echo "DEV_SDK="; echo "DEV_MODEL="; echo "DEV_ANDROID="
        echo "DEV_ADB_WIFI_ENABLED="; echo "DEV_DEV_OPTS="; echo "DEV_WIFI_IP="
        echo "USB_FOUND="
        echo "TCPIP_PORT=$TCPIP_PORT"; echo "TCPIP_LISTEN=0"; echo "AUTO_TCPIP=$AUTO_TCPIP"
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
        # 区分：是靠 tcpip 端口连上的，还是记忆端点维持的
        local _wdev _tcpip_conn=0
        for _wdev in $(wifi_devices); do
            if [ "${_wdev##*:}" = "$TCPIP_PORT" ]; then _tcpip_conn=1; fi
        done
        if [ "$_tcpip_conn" = "1" ]; then
            # tcpip 模式下 USB 只是"最初把它们连起来"的手段，之后无线独立工作，
            # 因此按当前有没有插 USB 给出不同文案，避免拔线后仍显示"USB 已连接"造成误解
            if [ -n "$usb_serial" ]; then
                level="ok"; title="设备已连接（USB 自动转 TCP）"
                hint="TCP 端口 $TCPIP_PORT 已开启，可安全拔掉 USB"
            else
                level="ok"; title="设备已连接（无线 $TCPIP_PORT 端口）"
                hint="USB 已拔出，无线连接独立保持正常"
            fi
            action=""
        else
            level="ok"; title="设备已连接（mDNS 被屏蔽）"; hint="靠记忆端点维持，端口变化后需重连"; action="manual_connect"
        fi
    elif [ -n "$usb_serial" ] && [ "${_dev_opts:-}" = "0" ]; then
        level="error"; title="手机「开发者选项」未开启"; hint="插着 USB，可在手机上自动打开设置页"; action="phone_dev_settings"
    elif [ -n "$usb_serial" ] && [ "$AUTO_TCPIP" = "1" ]; then
        # 插着 USB 且开启自动 tcpip：守护会自动切换，无需用户去设置里手动开
        level="warn"; title="USB 已连接，正在自动建立无线连接"
        hint="守护将自动切换 TCP 模式(端口 $TCPIP_PORT)，无需手动开无线调试"
        action="reconnect_now"
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
    # ---- 传输速率（非阻塞采样）----
    # diag 被菜单栏频繁调用，绝不能在这里 sleep 等待。
    # 做法：每次 diag 顺手采一个点，与上次采样的差值即为速率；
    # 间隔不足 200ms 时沿用上次结果，避免抖动成 0。
    local _r _dl _ul _crx _ctx
    _r=$(sample_rate "$TCPIP_PORT" 2>/dev/null)
    _dl=$(echo "$_r" | awk '{print $1}')
    _ul=$(echo "$_r" | awk '{print $2}')
    _crx=$(echo "$_r" | awk '{print $3}')
    _ctx=$(echo "$_r" | awk '{print $4}')
    echo "RATE_DOWN_KB=${_dl:-0}"
    echo "RATE_UP_KB=${_ul:-0}"
    echo "RATE_TOTAL_DOWN_MB=${_crx:-0}"
    echo "RATE_TOTAL_UP_MB=${_ctx:-0}"
    echo "RATE_DOWN_HUMAN=$(fmt_rate "${_dl:-0}")"
    echo "RATE_UP_HUMAN=$(fmt_rate "${_ul:-0}")"

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
    open)    cmd_open "${2:-wireless}" ;;
    recover) cmd_recover ;;
    rate)    cmd_rate "${2:-1}" ;;
    _daemon) main_loop ;;
    *)
        cat <<'USAGE'
adb-wifi-manager —— Android 无线调试自动连接守护

  adb-wifi.sh start           后台常驻启动
  adb-wifi.sh stop            停止
  adb-wifi.sh restart         重启
  adb-wifi.sh status          查看状态与在线设备
  adb-wifi.sh log             实时查看日志
  adb-wifi.sh once            前台执行一轮发现（排查用）
  adb-wifi.sh open [wireless|dev]
                              在手机上直接打开「无线调试」页面（默认）
                              或「开发者选项」页面，省去手动点菜单
  adb-wifi.sh recover         主动恢复无线连接（无需 USB）
                              依次尝试：已有连接 → 记忆端点 → 扫描本网段
  adb-wifi.sh rate [间隔秒]   查看当前 adb 传输速率（默认采样 1 秒）
USAGE
        ;;
esac
