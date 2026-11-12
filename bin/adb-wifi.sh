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
#
# -----------------------------------------------------------------------------
# 输出协议（机器可读契约）
#
# 默认 text 模式输出人类可读的中文文案，给终端用户与 TUI 直接展示。
# 菜单栏 App 需要做多语言时不能解析这些文案，因此提供 kv 模式：
#
#   ADBWIFI_FORMAT=kv adb-wifi.sh <子命令>
#
# kv 模式只输出 ASCII 的 KEY=VALUE 字段，值一律为枚举 token，不含任何自然语言；
# 语义文案由调用方（menubar/main.swift）用各自的 i18n 表渲染。
#
#   recover : RESULT=already|recovered|failed  ENDPOINT=<ip:port>  VIA=existing|known|scan|usb
#             ERROR=no_usb|tcpip_failed（仅 failed 时）
#   open    : RESULT=opened|partial|need_usb|no_device|failed  PAGE=wireless|dev
#             TITLE=wireless|dev  WIFI_TOGGLE=on|off|unknown
#   diag    : 始终输出 KEY=VALUE（不受本开关影响，本身即协议）
#             其中 DIAG_CODE 是诊断结论枚举，菜单栏按它查本地 i18n；
#             DIAG_TITLE / DIAG_HINT 是同义的中文文案，仅供终端与 TUI。
#             枚举取值见 cmd_diag 内各分支的 code=（共 11 种）
#
# 约定：这些字段是**稳定契约**，改名/改值需同步 menubar/main.swift；
#       新增诊断分支必须同时设置 code 并在 menubar/i18n.swift 三语表补齐。
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

# 输出格式：text=人类可读（默认）；kv=机器可读协议字段（菜单栏 App 使用）。
# 详见文件头「输出协议」一节。
OUT_FORMAT="${ADBWIFI_FORMAT:-text}"
is_kv() { [ "$OUT_FORMAT" = "kv" ]; }

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

# 带超时执行（macOS 无 timeout 命令，用 perl 实现）
#
# 为什么不用最简单的 `perl -e 'alarm shift; exec @ARGV'`：
#   那种写法超时杀死的是 exec *之后* 的进程本身，若该进程又派生了子进程
#   （如 adb 的 shell 命令、包装脚本里的 sleep），子进程仍持有 stdout 管道，
#   `$(tmo ... | tr)` 会一直等管道关闭 —— 超时形同失效（实测卡死 90 秒以上）。
#
# 现在改为：perl 先 fork，子进程自建进程组后 exec；超时时按**进程组**终止，
#   连带所有后代一起杀掉，调用方的命令替换/管道能立即拿到 EOF 正常返回。
tmo() {
    local secs="$1"; shift
    perl -e '
        my $secs = shift @ARGV;
        my $pid = fork();
        if (!defined $pid) { exit 125; }
        if (!$pid) {
            setpgrp(0, 0);            # 自成进程组，超时才能整组清理
            exec @ARGV or exit 127;
        }
        my $timedout = 0;
        $SIG{ALRM} = sub {
            $timedout = 1;
            kill "TERM", -$pid;
            select undef, undef, undef, 0.3;
            kill "KILL", -$pid;
        };
        alarm $secs;
        waitpid($pid, 0);
        alarm 0;
        exit(124) if $timedout;
        exit($? >> 8);
    ' "$secs" "$@"
}

# 当前是否已有无线设备连接在 "device" 状态
# adb devices 本身也可能卡住（server 异常时），统一加超时保护。
# 注意不能写成 `tmo N "$ADB_BIN" devices | awk`：tmo 杀死 adb 后 awk 仍在等管道关闭，
# 命令会一直挂着，超时形同失效。必须先取到变量再过滤。
wifi_devices() {
    local raw
    raw=$(tmo 10 "$ADB_BIN" devices 2>/dev/null)
    printf '%s\n' "$raw" | awk 'NR>1 && $2=="device" && $1 ~ /:[0-9]+$/ && $1 !~ /^\[/' \
        | awk '{print $1}'
}

# 所有设备的序列号(含 USB 与无线)
all_serial() {
    local raw
    raw=$(tmo 10 "$ADB_BIN" devices 2>/dev/null)
    printf '%s\n' "$raw" | awk 'NR>1 && $2!="" {print $1}'
}

# 记录成功连接的端点
remember_endpoint() {
    local ep="$1"
    touch "$KNOWN_FILE"
    grep -qxF "$ep" "$KNOWN_FILE" 2>/dev/null || echo "$ep" >> "$KNOWN_FILE"
}

# 把 adb 中**当前所有在线端点**补记进记忆文件。
#
# 为什么需要这一步：remember_endpoint 只记录"工具自己连上的"地址，
# 以下来源的端点会被漏掉，导致换网段后找不回来：
#   · 用户手动执行 adb connect
#   · legacy `adb tcpip` 模式（service.adb.tcp.port），不广播 _adb._tcp mDNS
#   · 其他工具（Android Studio、scrcpy）建立的连接
# 这些都是"曾经连通过、之后还能连"的有效地址，理应参与自动恢复。
sync_known_from_devices() {
    local ep changed=0
    touch "$KNOWN_FILE" 2>/dev/null || return 0
    for ep in $(wifi_devices); do
        case "$ep" in *:*) ;; *) continue ;; esac
        if ! grep -qxF "$ep" "$KNOWN_FILE" 2>/dev/null; then
            echo "$ep" >> "$KNOWN_FILE"
            changed=1
            info "记住新端点 $ep（来源：当前已连接设备）"
        fi
    done
    return 0
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
    # 可选参数：指定 USB 序列号时只处理这一台（多设备场景下避免抢用别的手机）
    ensure_tcpip_for "${1:-}"
}

# 同 ensure_tcpip，但强制作用于指定 USB 设备。
# 节流戳按设备分开，避免多台手机互相覆盖彼此的退避状态。
ensure_tcpip_for() {
    [ "$AUTO_TCPIP" = "1" ] || return 1

    local serial ip ep now last next_expire="" stamp
    serial="$1"
    [ -z "$serial" ] && serial="$(first_usb_serial)"
    [ -z "$serial" ] && return 1
    case "$serial" in *:*) return 1 ;; esac   # 只有 USB 设备能切 tcpip
    stamp="$TCPIP_STAMP.$serial"

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
    if [ -f "$stamp" ]; then
        read -r last next_expire < "$stamp" 2>/dev/null || last=0
        case "$last" in ''|*[!0-9]*) last=0 ;; esac
        if [ $((now - last)) -lt "$TCPIP_RETRY_INTERVAL" ]; then
            info "tcpip 上次尝试在 $((now - last))s 前，$TCPIP_RETRY_INTERVAL 秒内不重复切换" >&2
            return 1
        fi
    fi
    echo "$now" > "$stamp"

    info "USB 设备 $serial 未开无线调试，自动切换 TCP 模式(端口 $TCPIP_PORT) ..." >&2
    local out
    local tcpip_raw
    tcpip_raw=$(tmo 15 "$ADB_BIN" -s "$serial" tcpip "$TCPIP_PORT" 2>&1)
    out=$(printf '%s' "$tcpip_raw" | tr -d '\r')
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
            echo "OK known $ep"
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
                echo "OK scan $ep"
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

# ------------------------------------------------- mDNS 状态判定与自愈
#
# 区分三种状态，避免把「adb 卡死」误报成「网络屏蔽」：
#   mdns_ok       当前能发现 adb 服务 —— 正常
#   mdns_stalled  adb server 的 mDNS 子系统卡死（重启 server 后能恢复）
#   mdns_blocked  网络确实屏蔽组播重启也无用
#
# 判据：连续 N 轮 mDNS 为空后，主动重启一次 adb server 并复测：
#   恢复 → stalled（并且已自愈）；仍为空 → blocked。
# 状态写入 state/mdns_state，供 diag 展示与主循环节流。

MDNS_EMPTY_FILE="$STATE_DIR/mdns_empty_count"   # 连续为空的轮数
MDNS_STATE_FILE="$STATE_DIR/mdns_state"         # ok / stalled / blocked
MDNS_RETRY_INTERVAL="${MDNS_RETRY_INTERVAL:-180}"  # 两次自愈尝试的最小间隔（秒）
MDNS_RESTART_STAMP="$STATE_DIR/mdns_restart_at"   # 上次自愈尝试的时间戳

# 记录一轮 mDNS 采样结果；count 为 0 时累加连续空轮数
mdns_note_sample() {
    local count="${1:-0}" n=0
    [ -f "$MDNS_EMPTY_FILE" ] && read -r n < "$MDNS_EMPTY_FILE" 2>/dev/null
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "${count:-0}" -gt 0 ]; then
        echo 0 > "$MDNS_EMPTY_FILE"
    else
        echo $((n + 1)) > "$MDNS_EMPTY_FILE"
    fi
}

# 连续为空的轮数
mdns_empty_turns() {
    local n=0
    [ -f "$MDNS_EMPTY_FILE" ] && read -r n < "$MDNS_EMPTY_FILE" 2>/dev/null
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    echo "$n"
}

# 读取已判定的状态（无记录时按当前是否为空推断）
mdns_state() {
    if [ -f "$MDNS_STATE_FILE" ]; then
        cat "$MDNS_STATE_FILE" 2>/dev/null
        return 0
    fi
    echo "unknown"
}

# 尝试自愈：mDNS 连续为空达到阈值时重启 adb server 并复测。
# 返回 0 表示已恢复（并写入 stalled），1 表示仍未恢复（写入 blocked）。
mdns_try_recover() {
    local now last=0
    now=$(date +%s)
    [ -f "$MDNS_RESTART_STAMP" ] && read -r last < "$MDNS_RESTART_STAMP" 2>/dev/null
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    # 节流：避免频繁重启 adb server 打断正在进行的传输
    [ $((now - last)) -lt "$MDNS_RETRY_INTERVAL" ] && return 2
    echo "$now" > "$MDNS_RESTART_STAMP"

    warn "mDNS 连续 $(mdns_empty_turns) 轮为空，重启 adb server 尝试恢复 ..."
    restart_adb
    # mDNS 重新注册需要时间：实测重启后 0–20 秒内陆续出现服务，
    # 立即检查会误判成"网络屏蔽"。这里最多等 20 秒，每 2 秒探一次。
    local after=0 i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        after=$(tmo 10 "$ADB_BIN" mdns services 2>/dev/null | grep -c "_adb")
        case "$after" in ''|*[!0-9]*) after=0 ;; esac
        [ "$after" -gt 0 ] && break
        sleep 2
    done
    if [ "$after" -gt 0 ]; then
        echo "stalled" > "$MDNS_STATE_FILE"
        echo 0 > "$MDNS_EMPTY_FILE"
        info "✓ adb server 的 mDNS 已恢复（此前是 server 卡死，非网络屏蔽）"
        return 0
    fi
    echo "blocked" > "$MDNS_STATE_FILE"
    warn "重启 adb server 后 mDNS 仍为空，判定为网络屏蔽组播"
    return 1
}

# 每轮主循环调用：根据本轮 mDNS 结果更新状态并在需要时自愈
mdns_update() {
    local count="${1:-0}"
    mdns_note_sample "$count"
    if [ "${count:-0}" -gt 0 ]; then
        echo "ok" > "$MDNS_STATE_FILE"
        return 0
    fi
    # 阈值：连续 3 轮为空（默认 10s/轮 ≈ 30 秒）才尝试自愈，避免网络瞬时抖动误触发
    if [ "$(mdns_empty_turns)" -ge "${MDNS_RECOVER_TURNS:-3}" ]; then
        mdns_try_recover >/dev/null 2>&1 || true
    fi
    return 0
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
        # 0) 链路质量缓存（RTT/链路速率/信号/电量），过期则由后台异步刷新
        netinfo_maybe_refresh

        # 1) Wi-Fi 网段变化 → 重启 adb server，但**保留记忆端点**
        #
        # 为什么不删记忆端点：换网段 ≠ 旧设备不可达。
        # 典型场景是手机还连在原来的 Wi-Fi 上，只是 Mac 换了网络（或切到有线路由），
        # 两者经路由互通时旧端点依然有效。曾因这里直接 rm -f 而丢失记录，
        # 导致"手机明明连得上、工具却再也找不回来"。
        # 真正失效的端点由 discover_known() 的失败计数机制处理（连续失败才清理），
        # 这里只需重启 adb server 让旧连接状态归零，然后照常多路发现。
        prefix=$(lan_prefix)
        if [ -n "$prefix" ] && [ -n "$last_prefix" ] && [ "$prefix" != "$last_prefix" ]; then
            warn "检测到网络变化 ($last_prefix.x -> $prefix.x)，重启 adb server（保留记忆端点）"
            restart_adb
        fi
        [ -n "$prefix" ] && last_prefix="$prefix"

        connected_eps=$(wifi_devices)

        # 1.5) 把当前在线的端点补记进记忆文件（含手动 adb connect、legacy tcpip 模式等），
        #      这样换网段/mDNS 不可用时仍能靠记忆端点恢复。
        sync_known_from_devices

        # 2) 多路发现
        mdns_eps=$(discover_mdns)
        # mDNS 状态判定与自愈：持续为空时重启 adb server，区分"卡死"与"被屏蔽"
        _mdns_cnt=$(printf '%s\n' "$mdns_eps" | grep -c . || true)
        case "$_mdns_cnt" in ''|*[!0-9]*) _mdns_cnt=0 ;; esac
        mdns_update "$_mdns_cnt" >/dev/null 2>&1 || true
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
            echo "OK dev"
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
            echo "OK wireless"
            return 0
        fi
    fi

    # ② 独立 Activity（部分 ROM）
    out=$(tmo 15 "$ADB_BIN" -s "$serial" shell am start \
        -n 'com.android.settings/.Settings$WirelessDebuggingActivity' 2>&1 | tr -d '\r')
    if echo "$out" | grep -q "Starting:"; then
        sleep 1.5
        if ui_page_is_wireless_debug "$serial"; then
            echo "OK wireless"
            return 0
        fi
    fi

    # ③ 兜底：开发者选项页
    out=$(tmo 15 "$ADB_BIN" -s "$serial" shell am start \
        -a android.settings.APPLICATION_DEVELOPMENT_SETTINGS 2>&1 | tr -d '\r')
    if echo "$out" | grep -q "Starting:"; then
        echo "PARTIAL dev"
        is_kv || echo "该 ROM 未能直接定位无线调试页，已打开开发者选项，请手动点击「无线调试」" >&2
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

# 输出「供 App 建立设备列表」的 kv 字段（多设备入口的基础数据）。
# 只做一次 adb devices -l，不逐台查询，避免菜单打开时卡顿。
emit_device_list() {
    local n=0 id
    "$ADB_BIN" devices -l 2>/dev/null | while read -r id state rest; do
        case "$id" in ''|List|*"*"*) continue ;; esac
        case "$state" in
            device|offline|unauthorized) ;;
            *) continue ;;
        esac
        n=$((n + 1))
        local model transport
        model=$(printf '%s' "$rest" | sed -n 's/.*model:\([^ ]*\).*/\1/p' | tr '_' ' ')
        case "$id" in
            *:*) transport=wifi ;;
            *)   transport=usb ;;
        esac
        echo "DEV_${n}_SERIAL=$id"
        echo "DEV_${n}_STATE=$state"
        echo "DEV_${n}_TRANSPORT=$transport"
        [ -n "$model" ] && echo "DEV_${n}_MODEL=$model"
        echo "DEV_COUNT=$n"
    done
}

# 某台设备能否作为「在手机上打开设置页」的对象：排除离线/未授权
device_usable() {
    local s="$1" st
    st=$("$ADB_BIN" -s "$s" get-state 2>/dev/null | tr -d '\r')
    [ "$st" = "device" ]
}

# 把 open_settings_page 的内部 token 转成对外 RESULT（值域见文件头「输出协议」）
open_result_token() {
    case "$1" in
        OK\ *)      echo "opened" ;;
        PARTIAL\ *) echo "partial" ;;
        NEED_USB)   echo "need_usb" ;;
        *)          echo "failed" ;;
    esac
}

# 把 open_settings_page 的内部 token 转成对外的 TITLE 枚举（dev / wireless）
open_title_token() {
    local out="$1" title=""
    case "$out" in
        OK\ *)      title="${out#OK }" ;;
        PARTIAL\ *) title="${out#PARTIAL }" ;;
    esac
    echo "$title"
}

# 单轮参数解析：只认 `--serial <SERIAL>` 与 `--all`，其余位置参数不动。
# 结果放进 OPEN_SERIAL / OPEN_ALL 两个全局变量（bash 3.2 无 nameref 可用）。
parse_target_flags() {
    OPEN_SERIAL=""
    OPEN_ALL=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --serial|-s) OPEN_SERIAL="${2:-}"; shift 2 ;;
            --all)       OPEN_ALL=1; shift ;;
            *)           break ;;
        esac
    done
}

cmd_open() {
    OPEN_SERIAL=""
    OPEN_ALL=0
    local page="wireless"
    # 单个循环同时吃 page 与目标 flag：跳过 --serial 的取值，避免把序列号当成 page
    while [ $# -gt 0 ]; do
        case "$1" in
            --serial|-s) OPEN_SERIAL="${2:-}"; shift 2 ;;
            --all)       OPEN_ALL=1; shift ;;
            *)           page="$1"; shift ;;
        esac
    done

    # ---- 批量模式：对当前所有可用设备逐台打开 ----
    if [ "$OPEN_ALL" = "1" ]; then
        local targets s i=0 ok=0 fail=0 total
        targets=$(all_serial)
        total=$(printf '%s\n' "$targets" | grep -c . )
        if [ -z "$targets" ]; then
            if is_kv; then echo "DONE_COUNT=0"; echo "OK_COUNT=0"; echo "FAIL_COUNT=0"
            else echo "✗ 未检测到已连接的设备（USB 或无线均可）"; fi
            return 1
        fi
        is_kv || echo "对 $total 台设备打开「$page」页面 ..."
        for s in $targets; do
            i=$((i + 1))
            local out result
            out=$(open_settings_page "$s" "$page" 2>/dev/null)
            result=$(open_result_token "$out")
            case "$result" in opened|partial) ok=$((ok + 1)) ;; *) fail=$((fail + 1)) ;; esac
            if is_kv; then
                echo "DEV_${i}_SERIAL=$s"
                echo "DEV_${i}_RESULT=$result"
                local t; t=$(open_title_token "$out")
                [ -n "$t" ] && echo "DEV_${i}_TITLE=$t"
            else
                case "$result" in
                    opened)  echo "  ✓ $s" ;;
                    partial) echo "  △ $s（已到开发者选项，请手动点「无线调试」）" ;;
                    *)       echo "  ✗ $s 打开失败" ;;
                esac
            fi
        done
        if is_kv; then
            echo "DONE_COUNT=$i"
            echo "OK_COUNT=$ok"
            echo "FAIL_COUNT=$fail"
            echo "OK=$([ "$fail" -eq 0 ] && echo 1 || echo 0)"
        else
            echo "完成: $ok 台成功 / $fail 台失败"
        fi
        [ "$fail" -eq 0 ]
        return $?
    fi

    # ---- 单台模式：显式指定优先，否则沿用原来的自动挑选策略 ----
    local serial="${OPEN_SERIAL:-}" out
    if [ -z "$serial" ]; then
        serial="$(settings_serial)"
    else
        if ! device_usable "$serial"; then
            if is_kv; then
                echo "RESULT=no_device"
                echo "PAGE=$page"
                echo "SERIAL=$serial"
            else
                echo "✗ 设备 $serial 当前不可用（不在线或未授权）"
            fi
            return 1
        fi
    fi
    if [ -z "$serial" ]; then
        if is_kv; then
            echo "RESULT=no_device"
            echo "PAGE=$page"
        else
            echo "✗ 未检测到已连接的设备（USB 或无线均可）"
            echo "  请先连上手机再执行本命令"
        fi
        return 1
    fi
    is_kv || echo "使用设备: $serial"

    out=$(open_settings_page "$serial" "$page" 2>/dev/null)

    # 当前「无线调试」开关状态（kv 下作为字段，text 下作为提示行）
    local en toggle
    en=$(adbw -s "$serial" shell settings get global adb_wifi_enabled 2>/dev/null | tr -d '\r')
    case "$en" in
        1) toggle=on ;;
        0) toggle=off ;;
        *) toggle=unknown ;;
    esac

    # 把内部协议转成对外的 RESULT / TITLE token（值域见文件头「输出协议」）
    local result title
    result=$(open_result_token "$out")
    title=$(open_title_token "$out")

    if is_kv; then
        echo "RESULT=$result"
        echo "PAGE=$page"
        echo "SERIAL=$serial"
        [ -n "$title" ] && echo "TITLE=$title"
        echo "WIFI_TOGGLE=$toggle"
        if [ "$result" = "failed" ] || [ "$result" = "need_usb" ]; then
            return 1
        fi
        return 0
    fi

    # text 模式：把 token 渲染成中文（终端用户 / TUI 直接看）
    local label
    case "$title" in
        dev)      label="开发者选项" ;;
        wireless) label="无线调试" ;;
        *)        label="$title" ;;
    esac
    case "$result" in
        opened)   echo "✓ 已在手机上打开「$label」页面" ;;
        partial)  echo "△ $label"
                  echo "  未能直接定位到无线调试页，请在列表中手动点击「无线调试」" ;;
        need_usb) echo "✗ 需要先连接手机"; return 1 ;;
        *)        echo "✗ 打开失败: ${out#FAIL }"; return 1 ;;
    esac

    case "$toggle" in
        on)      echo "  当前「无线调试」开关: 已开启" ;;
        off)     echo "  当前「无线调试」开关: 未开启（请在手机上点开）" ;;
        *)       echo "  当前「无线调试」开关: 无法读取（该 ROM 可能不暴露此设置）" ;;
    esac
    return 0
}

# ------------------------------------------------- 主动恢复无线连接
# 不需要 USB：只要手机此前通过 USB 执行过 adb tcpip，adbd 就会常驻监听 TCP 端口，
# 之后无论 USB 是否插着，都能直接 connect 恢复。
# 恢复顺序：已有连接 → 记忆端点 → 扫描本网段
# 恢复「一台指定设备」：只尝试这台设备记得的端点 / 该设备的 USB 通道，
# 不会像批量逐设备扫描那样把整个 /24 网段扫一遍造成网络风暴。
# 输出协议：RESULT / ENDPOINT / VIA / ERROR（与 cmd_recover 的 kv 字段一致）
recover_one() {
    local serial="$1" known eps ep via="" usb_only=1 out
    # ① 该设备已在无线连接且响应正常
    if [ "${serial#*:}" != "$serial" ] && tmo 5 "$ADB_BIN" -s "$serial" get-state >/dev/null 2>&1; then
        echo "RESULT=already"
        echo "ENDPOINT=$serial"
        echo "VIA=existing"
        return 0
    fi
    # ② 仅该设备记住的端点（记忆文件按端点记录，逐条校验后只认本设备的）
    if [ -f "$KNOWN_FILE" ]; then
        known=$(grep -F "$serial" "$KNOWN_FILE" 2>/dev/null)
        for ep in $known; do
            [ "$ep" = "$serial" ] || continue
            if try_connect "$ep" >/dev/null 2>&1; then
                echo "RESULT=recovered"; echo "ENDPOINT=$ep"; echo "VIA=known"
                return 0
            fi
        done
    fi
    # ③ 通过该设备自身的 USB 通道切 TCP 模式（只针对这台，不抢用其他 USB 设备）
    case "$serial" in
        *:*) usb_only=0 ;;
    esac
    if [ "$usb_only" = "1" ] && [ "$AUTO_TCPIP" = "1" ]; then
        ep=$(ensure_tcpip_for "$serial" 2>/dev/null)
        if [ -n "$ep" ]; then
            echo "RESULT=recovered"; echo "ENDPOINT=$ep"; echo "VIA=usb"
            return 0
        fi
        echo "RESULT=failed"; echo "ERROR=tcpip_failed"
        return 1
    fi
    echo "RESULT=failed"; echo "ERROR=no_usb"
    return 1
}

cmd_recover() {
    local only=""
    parse_target_flags "$@"
    only="$OPEN_SERIAL"

    # ---- 批量模式：对所有**已知**设备做一次「保活校验 / 重连」----
    # 范围 = 当前在线的 + 记忆文件里记录过的（含已掉线的）。
    # 只遍历在线设备是错的：掉线的那台正是需要恢复的对象，
    # 若不把记忆端点算进来，"恢复全部"就永远救不回掉线的设备（曾实测复现）。
    # 仍然不做网段扫描（多设备同时扫会拖慢网络）。
    if [ "$OPEN_ALL" = "1" ]; then
        local s i=0 ok=0 fail=0
        is_kv || echo "正在校验并恢复所有设备的无线连接 ..."
        local targets
        targets=$( { all_serial; [ -f "$KNOWN_FILE" ] && cat "$KNOWN_FILE"; } | awk 'NF' | sort -u )
        for s in $targets; do
            i=$((i + 1))
            local r; r=$(recover_one "$s")
            local res; res=$(printf '%s\n' "$r" | sed -n 's/^RESULT=//p')
            local ep;  ep=$(printf '%s\n' "$r"  | sed -n 's/^ENDPOINT=//p')
            local via; via=$(printf '%s\n' "$r" | sed -n 's/^VIA=//p')
            case "$res" in already|recovered) ok=$((ok + 1)) ;; *) fail=$((fail + 1)) ;; esac
            if is_kv; then
                echo "DEV_${i}_SERIAL=$s"
                echo "DEV_${i}_RESULT=${res:-failed}"
                [ -n "$ep" ]  && echo "DEV_${i}_ENDPOINT=$ep"
                [ -n "$via" ] && echo "DEV_${i}_VIA=$via"
            else
                case "$res" in
                    already)   echo "  ✓ $s 已在线" ;;
                    recovered) echo "  ✓ $s 已恢复 $ep" ;;
                    *)         echo "  ✗ $s 恢复失败" ;;
                esac
            fi
        done
        if is_kv; then
            echo "DONE_COUNT=$i"; echo "OK_COUNT=$ok"; echo "FAIL_COUNT=$fail"
            echo "OK=$([ "$fail" -eq 0 ] && echo 1 || echo 0)"
        fi
        [ "$fail" -eq 0 ]
        return $?
    fi

    # ---- 单台模式 ----
    if [ -n "$only" ]; then
        is_kv || echo "正在恢复设备 $only 的无线连接 ..."
        local r; r=$(recover_one "$only")
        if is_kv; then
            printf '%s\n' "$r"
        else
            # text 模式必须给出结论，否则调用方（TUI / 终端）只能看到一两行提示，
            # 无法判断成功与否——早先这里漏了结果输出。
            local _res _ep _via _err
            _res=$(printf '%s\n' "$r" | sed -n 's/^RESULT=//p')
            _ep=$(printf '%s\n' "$r"  | sed -n 's/^ENDPOINT=//p')
            _via=$(printf '%s\n' "$r" | sed -n 's/^VIA=//p')
            _err=$(printf '%s\n' "$r" | sed -n 's/^ERROR=//p')
            case "$_res" in
                already)   echo "✓ 当前已有可用连接: ${_ep:-$only}" ;;
                recovered) echo "✓ 已恢复无线连接: ${_ep:-$only}" ;;
                *)
                    echo "✗ 未能恢复 $only 的无线连接"
                    case "$_err" in
                        tcpip_failed) echo "  已尝试通过 USB 切换 TCP 模式，但未能连上" ;;
                        no_usb)       echo "  手机重启过会导致 tcpip 失效，插一次 USB 即可自动恢复" ;;
                    esac
                    ;;
            esac
        fi
        printf '%s\n' "$r" | grep -q '^RESULT=\(already\|recovered\)$'
        return $?
    fi

    local r ep="" via="" result="" err=""
    is_kv || echo "正在恢复无线连接 ..."
    r=$(recover_connection 2>/dev/null)

    case "$r" in
        ALREADY\ *)   result=already;   ep="${r#ALREADY }"; via=existing ;;
        OK\ known\ *) result=recovered; ep="${r#OK known }"; via=known ;;
        OK\ scan\ *)  result=recovered; ep="${r#OK scan }"; via=scan ;;
    esac

    # 第一轮失败：插着 USB 时尝试切 TCP 模式再恢复
    if [ -z "$result" ]; then
        local usb
        usb="$(first_usb_serial)"
        if [ -n "$usb" ]; then
            is_kv || echo "✗ 未能恢复无线连接"
            is_kv || echo "  检测到 USB 已连接，将自动切换 TCP 模式重试 ..."
            ep=$(ensure_tcpip 2>/dev/null)
            if [ -n "$ep" ]; then
                result=recovered
                via=usb
            else
                err=tcpip_failed
            fi
        else
            err=no_usb
        fi
    fi

    if is_kv; then
        # 输出协议：RESULT / ENDPOINT / VIA / ERROR，不含任何自然语言
        echo "RESULT=${result:-failed}"
        [ -n "$ep" ] && echo "ENDPOINT=$ep"
        [ -n "$via" ] && echo "VIA=$via"
        [ -n "$err" ] && echo "ERROR=$err"
        [ -n "$result" ] && return 0
        return 1
    fi

    case "$result" in
        already)   echo "✓ 当前已有可用连接: $ep"; return 0 ;;
        recovered)
            if [ "$via" = "usb" ]; then
                echo "✓ 已通过 USB 恢复: $ep"
            else
                echo "✓ 已恢复无线连接: $ep"
            fi
            return 0 ;;
    esac

    # 失败：区分"手机根本没在监听"与"网络不通"，给出可操作提示
    [ "$err" = "no_usb" ] && echo "✗ 未能恢复无线连接"
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
RATE_HIST_FILE="$STATE_DIR/rate_history"  # 格式: 时间戳 下行KB/s 上行KB/s（滑动窗口）
RATE_HIST_KEEP="${RATE_HIST_KEEP:-600}"   # 历史保留时长（秒），用于算平均/峰值

# 把本次瞬时速率记入历史，供“传输时的平均/峰值”统计使用。
# 只保留最近 RATE_HIST_KEEP 秒，文件行数恒定，不会无限增长。
rate_hist_append() {
    local down="$1" up="$2" now
    now=$(date +%s)
    printf '%s %s %s\n' "$now" "${down:-0}" "${up:-0}" >> "$RATE_HIST_FILE" 2>/dev/null || return 0
    awk -v cut=$((now - RATE_HIST_KEEP)) '$1 >= cut' "$RATE_HIST_FILE" \
        > "$RATE_HIST_FILE.tmp" 2>/dev/null \
        && mv -f "$RATE_HIST_FILE.tmp" "$RATE_HIST_FILE" 2>/dev/null
    return 0
}

# 计算“有传输时”的平均与峰值速率（Mbps）。
# 跳过 0 采样，避免空闲时段把均值拉低；单位换成 Mbps 方便与链路速率对比。
net_rate_stats() {
    [ -f "$RATE_HIST_FILE" ] || { echo "0 0"; return 0; }
    local now from
    now=$(date +%s)
    from=$((now - RATE_HIST_KEEP))
    awk -v from="$from" '
        $1 >= from {
            v = ($2 + 0) + ($3 + 0)
            if (v <= 0) next
            n++; sum += v
            if (v > max) max = v
        }
        END {
            if (n > 0) printf "%.1f %.1f\n", sum / n * 8 / 1024, max * 8 / 1024
            else       print "0 0"
        }' "$RATE_HIST_FILE"
}

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
    local out
    out=$(awk -v dd="$d_down" -v du="$d_up" -v ms="$dt_ms" -v d="$down" -v u="$up" 'BEGIN {
        sec = ms / 1000.0
        printf "%.1f %.1f %.2f %.2f\n", dd/sec/1024, du/sec/1024, d/1048576, u/1048576
    }')
    # 记录瞬时速率，供 netinfo 算“传输中的平均/峰值”
    rate_hist_append "$(printf '%s' "$out" | awk '{print $1}')" \
                     "$(printf '%s' "$out" | awk '{print $2}')"
    printf '%s\n' "$out"
}

# 把 KB/s 格式化成易读形式
fmt_rate() {
    awk -v v="$1" 'BEGIN {
        if (v < 1)          printf "0 KB/s"
        else if (v < 1024)  printf "%.0f KB/s", v
        else                printf "%.2f MB/s", v/1024
    }'
}

# ------------------------------------------------- 链路质量指标
# 解释“为什么无线会慢”的几项关键数据：RTT、链路速率、AP、频率、信号强度、电量。
#
# 哪些项慢（实测）：dumpsys wifi ~0.3s、system_profiler ~1s、ping ~1.5s。
# 而 diag 每 2 秒被菜单栏调一次，绝不能在 diag 里实时采。
# 因此统一走缓存：后台刷新（守护循环 / App 主动触发），diag 只读文件。
NETINFO_CACHE="$STATE_DIR/netinfo.cache"
NETINFO_TTL="${NETINFO_TTL:-60}"

# 频率 → 信道号（仅覆盖常见 2.4G / 5G）
net_freq_to_channel() {
    local f="${1:-0}"
    case "$f" in
        ''|*[!0-9]*) echo "" ;;
        *) if [ "$f" -ge 2400 ] && [ "$f" -le 2500 ]; then
               echo $(( (f - 2407) / 5 ))
           elif [ "$f" -ge 4900 ]; then
               echo $(( (f - 5000) / 5 ))
           else
               echo ""
           fi ;;
    esac
}

# Mac 电量（仅笔记本有电池；台式机 / 无电池时直接跳过）
net_mac_battery() {
    local raw pct mode
    raw=$(pmset -g batt 2>/dev/null)
    case "$raw" in
        *InternalBattery*) ;;
        *) return 0 ;;
    esac
    pct=$(printf '%s' "$raw" | grep -o '[0-9][0-9]*%' | head -1 | tr -d '%')
    # 注意：discharging 包含 charging 子串，必须先判断
    case "$raw" in
        *discharging*) mode=discharging ;;
        *charging*)    mode=charging ;;
        *charged*)     mode=charged ;;
        *)             mode=ac ;;
    esac
    echo "NET_MAC_BATTERY=$pct"
    echo "NET_MAC_POWER=$mode"
}

# 采集单台设备的链路与电量指标（一次 shell 调用拿齐，避免高 RTT 下多次往返）
net_dev_collect() {
    local serial="$1" idx="$2" raw wifi_line model batt
    local ssid bssid freq link rssi ch dev_ip rtt_line rtt_min rtt_avg rtt_max
    local transport=usb level status charging=0

    case "$serial" in *:*) transport=wifi ;; esac

    # 关键：必须带超时。dumpsys wifi 在设备繁忙（正在传输/锁屏/高负载）时
    # 可能长时间不返回，没有超时会让整个 netinfo 采集卡死，进而拖住菜单栏。
    # 15 秒足够正常设备完成三项取数，超时则本轮该设备各项留空。
    # 同理不能把 tmo 直接接管道：perl 到期被 SIGALRM 杀掉后，
    # tr 仍在等待写入端关闭，整条命令会一直挂着（实测卡死 90 秒以上）。
    local shell_raw
    shell_raw=$(tmo 15 "$ADB_BIN" -s "$serial" shell "
        dumpsys wifi | grep -m1 'SSID:'
        echo '@@MODEL@@'
        getprop ro.product.model
        echo '@@BATT@@'
        dumpsys battery | grep -E 'level:|status:'
    " 2>/dev/null)
    raw=$(printf '%s' "$shell_raw" | tr -d '\r')

    wifi_line=$(printf '%s\n' "$raw" | awk '/@@MODEL@@/{exit} {print}' | head -1)
    model=$(printf '%s\n' "$raw" | awk '/@@MODEL@@/{f=1;next} /@@BATT@@/{exit} f' | head -1)
    batt=$(printf '%s\n' "$raw" | awk '/@@BATT@@/{f=1;next} f')

    ssid=$(printf '%s' "$wifi_line" | sed -n 's/.*SSID: "\([^"]*\)".*/\1/p')
    bssid=$(printf '%s' "$wifi_line" | sed -n 's/.*BSSID: \([0-9a-f:]*\).*/\1/p')
    freq=$(printf '%s' "$wifi_line" | sed -n 's/.*Frequency: \([0-9]*\)MHz.*/\1/p')
    link=$(printf '%s' "$wifi_line" | sed -n 's/.*Link speed: \([0-9]*\)Mbps.*/\1/p')
    rssi=$(printf '%s' "$wifi_line" | sed -n 's/.*RSSI: \(-\{0,1\}[0-9]*\).*/\1/p')
    ch=$(net_freq_to_channel "$freq")

    level=$(printf '%s' "$batt" | sed -n 's/.*level: \([0-9]*\).*/\1/p' | head -1)
    status=$(printf '%s' "$batt" | sed -n 's/.*status: \([0-9]*\).*/\1/p' | head -1)
    case "$status" in 2|5) charging=1 ;; esac

    # RTT 只对无线设备有意义（USB 走本地总线，不存在网络往返）。
    # 采样 12 包：3 包时抖动大的网络（如本例实测 8~102ms）均值偏差极大，
    # 同一台设备两次采样可能相差 3 倍。12 包 + 0.2s 间隔约 2.6 秒，仍在缓存 TTL 内。
    # 外层再套 8 秒硬超时，防止丢包时 ping 拖满整个采集窗口。
    if [ "$transport" = "wifi" ]; then
        dev_ip="${serial%%:*}"
        local ping_raw
        ping_raw=$(tmo 8 ping -c 12 -i 0.2 -q "$dev_ip" 2>/dev/null)
        rtt_line=$(printf '%s' "$ping_raw" | tail -1)
        rtt_min=$(printf '%s' "$rtt_line" | sed -n 's/.*= \([0-9.]*\)\/.*/\1/p')
        rtt_avg=$(printf '%s' "$rtt_line" | sed -n 's/.*= [0-9.]*\/\([0-9.]*\)\/.*/\1/p')
        rtt_max=$(printf '%s' "$rtt_line" | sed -n 's/.*\/\([0-9.]*\)\/[0-9.]* ms/\1/p')
    fi

    echo "NET_DEV_${idx}_SERIAL=$serial"
    echo "NET_DEV_${idx}_TRANSPORT=$transport"
    echo "NET_DEV_${idx}_MODEL=$model"
    echo "NET_DEV_${idx}_SSID=$ssid"
    echo "NET_DEV_${idx}_BSSID=$bssid"
    echo "NET_DEV_${idx}_FREQ=$freq"
    echo "NET_DEV_${idx}_CHANNEL=$ch"
    echo "NET_DEV_${idx}_LINK=$link"
    echo "NET_DEV_${idx}_RSSI=$rssi"
    echo "NET_DEV_${idx}_RTT_MIN=$rtt_min"
    echo "NET_DEV_${idx}_RTT_AVG=$rtt_avg"
    echo "NET_DEV_${idx}_RTT_MAX=$rtt_max"
    echo "NET_DEV_${idx}_BATTERY=$level"
    echo "NET_DEV_${idx}_CHARGING=$charging"
}

# Mac 侧 Wi-Fi 链路单独缓存。
# system_profiler 一次约 1s CPU（比 dumpsys / ping 都贵），但 Mac 的信道、协商速率
# 极少变化，没必要跟着设备侧 60 秒刷。改 300 秒一次，平时直接读缓存。
NETINFO_MAC_CACHE="$STATE_DIR/netinfo_mac.cache"
NETINFO_MAC_TTL="${NETINFO_MAC_TTL:-300}"

net_mac_link_collect() {
    local age=999999 mtime sp mac_ch mac_rate mac_rssi mac_ssid
    if [ -f "$NETINFO_MAC_CACHE" ]; then
        mtime=$(stat -f %m "$NETINFO_MAC_CACHE" 2>/dev/null || echo 0)
        age=$(( $(date +%s) - mtime ))
    fi
    # 缓存只有"过期"一个刷新条件还不够：新增字段后，旧缓存缺该字段会让
    # 新功能看起来失效（例如 NET_MAC_SSID 是后加的，旧缓存里没有，
    # 导致"同 AP"判定一直返回 unknown）。缺关键字段时视为失效，强制重采。
    if [ -f "$NETINFO_MAC_CACHE" ] && [ "$age" -lt "$NETINFO_MAC_TTL" ]; then
        case "$(grep -c '^NET_MAC_SSID=' "$NETINFO_MAC_CACHE" 2>/dev/null)" in
            1) ;;
            *) age=$NETINFO_MAC_TTL ;;
        esac
    fi
    if [ "$age" -ge "$NETINFO_MAC_TTL" ]; then
        sp=$(system_profiler SPAirPortDataType 2>/dev/null \
            | sed -n '/Current Network Information/,/Other Local Wi-Fi Networks/p')
        # Mac 侧 SSID：用于判断手机是否接在同一个 Wi-Fi / 同一个 AP 下。
        # 取 "Current Network Information:" 之后那行的 SSID（形如 "            PiLink:"）。
        # 注意 macOS 不提供 Mac 侧 BSSID（隐私限制），只能靠 SSID + 信道间接判断。
        mac_ssid=$(printf '%s' "$sp" | sed -n 's/^ *\([^ ]*\):$/\1/p' | head -1)
        mac_ch=$(printf '%s' "$sp" | sed -n 's/.*Channel: \([0-9]*\).*/\1/p' | head -1)
        mac_rate=$(printf '%s' "$sp" | sed -n 's/.*Transmit Rate: \([0-9]*\).*/\1/p' | head -1)
        mac_rssi=$(printf '%s' "$sp" | sed -n 's/.*Signal \/ Noise: \(-\{0,1\}[0-9]*\).*/\1/p' | head -1)
        if [ -n "$mac_rate" ] || [ -n "$mac_ch" ]; then
            {
                [ -n "$mac_ssid" ] && echo "NET_MAC_SSID=$mac_ssid"
                echo "NET_MAC_CHANNEL=$mac_ch"
                echo "NET_MAC_RATE=$mac_rate"
                echo "NET_MAC_RSSI=$mac_rssi"
            } > "$NETINFO_MAC_CACHE.tmp.$$" 2>/dev/null \
                && mv -f "$NETINFO_MAC_CACHE.tmp.$$" "$NETINFO_MAC_CACHE" 2>/dev/null
        fi
    fi
    [ -f "$NETINFO_MAC_CACHE" ] && cat "$NETINFO_MAC_CACHE"
    return 0
}

# 采集一次完整链路指标（慢，只在缓存过期时调用）
# 多设备：每台一份 NET_DEV_<n>_*；Mac 侧（信道/速率/信号/电量）全局一份。
net_info_collect() {
    local idx=0 serial started now elapsed
    local budget="${NETINFO_BUDGET:-30}"   # 设备侧采集总预算（秒）

    started=$(date +%s)
    for serial in $(all_serial); do
        # 总预算保护：单台已有 15 秒超时，多台串行时仍可能叠加。
        # 超过预算就停止采集剩余设备，宁可少几台也不让菜单栏/调用方长时间等待。
        now=$(date +%s); elapsed=$((now - started))
        if [ "$idx" -gt 0 ] && [ "$elapsed" -ge "$budget" ]; then
            echo "NET_TRUNCATED=1" >&2
            break
        fi
        idx=$((idx + 1))
        net_dev_collect "$serial" "$idx"
    done
    echo "NET_DEV_COUNT=$idx"

    # ---- Mac 侧 Wi-Fi 链路（独立 300 秒缓存，平时不跑 system_profiler）----
    net_mac_link_collect

    net_mac_battery

    # 速率对比：传输时的平均值 / 峰值（全设备共用 adb 通道）
    local stats
    stats=$(net_rate_stats)
    echo "NET_RATE_AVG_MBPS=$(printf '%s' "$stats" | awk '{print $1}')"
    echo "NET_RATE_MAX_MBPS=$(printf '%s' "$stats" | awk '{print $2}')"
    echo "NET_AT=$(date +%s)"
}

# 缓存过期就再起一个后台采集，不阻塞调用方（diag / 菜单 / 守护循环）。
#
# 必须加锁：采集要 2~4 秒，期间缓存仍是旧的（或不存在），
# 而 diag 每 2 秒就被调一次 —— 不加锁会派生 N 个并发采集
# （实测 6 次调用起了 6 个 system_profiler + dumpsys + ping）。
# 用 mkdir 做原子锁，不能用「先判断再创建」的文件锁。
NETINFO_LOCK="$STATE_DIR/netinfo.lock"

netinfo_maybe_refresh() {
    local age=999999 mtime
    if [ -f "$NETINFO_CACHE" ]; then
        mtime=$(stat -f %m "$NETINFO_CACHE" 2>/dev/null || echo 0)
        age=$(( $(date +%s) - mtime ))
    fi
    [ "$age" -lt "$NETINFO_TTL" ] && return 0

    # 抢锁：mkdir 是原子的，成功者才去采集
    if ! mkdir "$NETINFO_LOCK" 2>/dev/null; then
        # 陈旧锁（进程被 kill -9 / 异常退出残留）：超过 2×TTL 强制接管
        local lmt lage
        lmt=$(stat -f %m "$NETINFO_LOCK" 2>/dev/null || echo 0)
        lage=$(( $(date +%s) - lmt ))
        [ "$lage" -lt $(( NETINFO_TTL * 2 )) ] && return 0
        rm -rf "$NETINFO_LOCK" 2>/dev/null
        mkdir "$NETINFO_LOCK" 2>/dev/null || return 0
    fi

    (
        trap 'rm -rf "$NETINFO_LOCK" 2>/dev/null' EXIT INT TERM
        net_info_collect > "$NETINFO_CACHE.tmp.$$" 2>/dev/null \
            && mv "$NETINFO_CACHE.tmp.$$" "$NETINFO_CACHE" \
            || rm -f "$NETINFO_CACHE.tmp.$$"
    ) >/dev/null 2>&1 &
    return 0
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

    # 先补记当前在线端点，保证菜单栏/命令行走 diag 时也能收录
    # 手动 adb connect 或 legacy tcpip 模式建立的连接。
    sync_known_from_devices >/dev/null 2>&1
    known_eps=$(discover_known 2>/dev/null)
    echo "KNOWN_FOUND=$(echo $known_eps | tr '\n' ',')"
    echo "KNOWN_LIST=$( [ -f "$KNOWN_FILE" ] && tr '\n' ',' < "$KNOWN_FILE" )"

    # ---- 结构化诊断结论（TUI 与菜单栏 App 共用，避免两边判断不一致）----
    # code 是机器可读枚举，供菜单栏 App 按自己的语言渲染；
    # title/hint 是中文文案，给终端用户与 TUI 用。新增分支必须同时设 code。
    local level title hint action code=""
    if [ -z "$dpid" ] && [ -z "$(wifi_devices)" ]; then
        code="DAEMON_DOWN_NO_DEVICE"
        level="warn"; title="守护未运行且无设备连接"; hint="点击「启动守护」开始自动连接"; action="start_daemon"
    elif [ -n "$(wifi_devices)" ] && [ "${raw_mdns:-0}" -gt 0 ]; then
        code="CONNECTED_MDNS"
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
                code="CONNECTED_VIA_TCPIP_USB"
                level="ok"; title="设备已连接（USB 自动转 TCP）"
                hint="TCP 端口 $TCPIP_PORT 已开启，可安全拔掉 USB"
            else
                code="CONNECTED_VIA_TCPIP_WIRELESS"
                level="ok"; title="设备已连接（无线 $TCPIP_PORT 端口）"
                hint="USB 已拔出，无线连接独立保持正常"
            fi
            action=""
        else
            code="CONNECTED_VIA_KNOWN"
            level="ok"; title="设备已连接（mDNS 被屏蔽）"; hint="靠记忆端点维持，端口变化后需重连"; action="manual_connect"
        fi
    elif [ -n "$usb_serial" ] && [ "${_dev_opts:-}" = "0" ]; then
        code="DEV_OPTIONS_OFF"
        level="error"; title="手机「开发者选项」未开启"; hint="插着 USB，可在手机上自动打开设置页"; action="phone_dev_settings"
    elif [ -n "$usb_serial" ] && [ "$AUTO_TCPIP" = "1" ]; then
        # 插着 USB 且开启自动 tcpip：守护会自动切换，无需用户去设置里手动开
        code="USB_AUTO_TCPIP_PENDING"
        level="warn"; title="USB 已连接，正在自动建立无线连接"
        hint="守护将自动切换 TCP 模式(端口 $TCPIP_PORT)，无需手动开无线调试"
        action="reconnect_now"
    elif [ -n "$usb_serial" ] && [ "${_adb_wifi:-}" = "0" ]; then
        code="ADB_WIFI_OFF"
        level="error"; title="手机「无线调试」开关未打开"; hint="插着 USB，可在手机上自动打开设置页"; action="phone_wireless"
    elif [ -n "$usb_serial" ]; then
        code="USB_CONNECTED_NO_WIRELESS"
        level="warn"; title="USB 已连接，尚未建立无线连接"; hint="正在读取端口，稍候自动连接"; action="reconnect_now"
    elif [ "${raw_mdns:-0}" -gt 0 ]; then
        code="NO_DEVICE_MDNS_OK"
        level="warn"; title="未发现设备（mDNS 正常）"; hint="请确认手机已开启无线调试且同一 Wi-Fi"; action="phone_dev_settings"
    else
        code="NO_DEVICE_MDNS_BLOCKED"
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

    # ---- 链路质量指标（读缓存，不实时采样；缓存过期则后台刷新）----
    netinfo_maybe_refresh
    [ -f "$NETINFO_CACHE" ] && cat "$NETINFO_CACHE"

    echo "DIAG_LEVEL=$level"
    echo "DIAG_CODE=$code"
    echo "DIAG_TITLE=$title"
    echo "DIAG_HINT=$hint"
    echo "DIAG_ACTION=$action"
    echo "MDNS_OK=$([ "${raw_mdns:-0}" -gt 0 ] && echo 1 || echo 0)"
    # mDNS 细分状态：ok / stalled（adb server 卡死，重启可恢复）/ blocked（网络屏蔽）
    # 为空时若没判定过，先按 blocked 展示但要给出连续空轮数，便于用户判断
    _mstate=$(mdns_state)
    if [ "${raw_mdns:-0}" -gt 0 ]; then
        _mstate="ok"
    elif [ "$_mstate" = "unknown" ]; then
        _mstate="blocked"
    fi
    echo "MDNS_STATE=$_mstate"
    echo "MDNS_EMPTY_TURNS=$(mdns_empty_turns)"
}

# ------------------------------------------------- 设备清单（多设备入口）
# 供 App / TUI 建立「每台设备各自的入口」。只做一次 adb devices -l，
# 并尽量补上 Wi-Fi IP，不逐台拉取重型信息（保持菜单打开速度）。
cmd_devices() {
    local raw line id state rest model transport ip n=0

    # 关键：用 heredoc（<<<）而不是 `adb ... | while`。
    # 管道会为 while 开子 shell，循环里的计数与 local 都在子 shell 内失效，
    # 早先的实现因此只输出第一台设备。
    raw=$("$ADB_BIN" devices -l 2>/dev/null | tr -d '\r')

    if is_kv; then
        while IFS= read -r -u 3 line; do
            [ -z "$line" ] && continue
            id=${line%%[[:space:]]*}
            case "$id" in ''|List|*"*"*) continue ;; esac   # 跳过表头与 "* daemon ..."
            rest="${line#"$id"}"
            rest="${rest#"${rest%%[![:space:]]*}"}"            # 去掉前导空白
            state=${rest%%[[:space:]]*}
            [ "$state" = "$rest" ] && rest=""
            rest="${rest#"$state"}"
            case "$state" in
                device|offline|unauthorized) ;;
                *) continue ;;
            esac
            n=$((n + 1))
            model=$(printf '%s' "$rest" | sed -n 's/.*model:\([^ ]*\).*/\1/p' | tr '_' ' ')
            case "$id" in
                *:*) transport=wifi ;;
                *)   transport=usb ;;
            esac
            echo "DEV_${n}_SERIAL=$id"
            echo "DEV_${n}_STATE=$state"
            echo "DEV_${n}_TRANSPORT=$transport"
            [ -n "$model" ] && echo "DEV_${n}_MODEL=$model"
        done 3<<< "$raw"
        echo "DEV_COUNT=$n"
        return 0
    fi

    printf '%-24s %-12s %-9s %s\n' "SERIAL" "STATE" "TRANSPORT" "MODEL / IP"
    # 注意这里必须用 -u 3 + 3<&0：循环体内会调用 adb（device_wifi_ip），
    # 子进程会继承并消耗 heredoc 的 stdin，导致第二台设备读不到。
    while IFS= read -r -u 3 line; do
        [ -z "$line" ] && continue
        id=${line%%[[:space:]]*}
        case "$id" in ''|List|*"*"*) continue ;; esac
        rest="${line#"$id"}"
        rest="${rest#"${rest%%[![:space:]]*}"}"
        state=${rest%%[[:space:]]*}
        [ "$state" = "$rest" ] && rest=""
        rest="${rest#"$state"}"
        model=$(printf '%s' "$rest" | sed -n 's/.*model:\([^ ]*\).*/\1/p' | tr '_' ' ')
        case "$id" in
            *:*) transport=wifi ;;
            *)   transport=usb ;;
        esac
        ip=$(device_wifi_ip "$id" 2>/dev/null | tr -d '\r')
        printf '%-24s %-12s %-9s %s\n' "$id" "$state" "$transport" "${model:-?}${ip:+ ($ip)}"
    done 3<<< "$raw"
    return 0
}

# ------------------------------------------------- 链路质量：刷新
# 链路质量是**每台设备各自的属性**（与这台手机的 RTT / 信号 / 吞吐），
# 所以入口按设备划分。两种刷新：
#   cmd_netinfo_refresh          刷新全部设备（忽略 TTL，同步等待完成）
#   cmd_netinfo_refresh_one S    只刷这一台，其余设备缓存原样保留
#
# 为什么要"合并"而不是整份重采：
#   多设备时整份重采要逐台 dumpsys + ping，耗时叠加到十几秒；
#   用户只是想看某一台的最新数据，没必要惊动其他设备。

# 把单台设备的采集结果合并进缓存文件（替换该设备对应的 NET_DEV_<n>_* 段）
# 用法：netinfo_merge_one <serial> < 采集输出
netinfo_merge_one() {
    local serial="$1" fresh match_idx="" tmp_new tmp_out
    fresh=$(cat)                                  # 本次采集的 NET_DEV_1_* 块
    [ -f "$NETINFO_CACHE" ] || { printf '%s\n' "$fresh" > "$NETINFO_CACHE"; return 0; }

    # 找出该设备在缓存中的序号
    match_idx=$(awk -F= -v s="$serial" '
        $1 ~ /^NET_DEV_[0-9]+_SERIAL$/ && $2 == s { split($1,a,"_"); print a[3]; exit }
    ' "$NETINFO_CACHE")

    if [ -z "$match_idx" ]; then
        # 缓存里没有这台设备 → 收录为新的一项（追加在末尾，序号顺延）
        local cnt
        cnt=$(grep -c '^NET_DEV_[0-9]*_SERIAL=' "$NETINFO_CACHE" 2>/dev/null || echo 0)
        cnt=${cnt:-0}
        tmp_new="$NETINFO_CACHE.tmp.$$"
        cp "$NETINFO_CACHE" "$tmp_new"
        # 重新编号后追加
        local newidx=$((cnt + 1))
        printf '%s\n' "$fresh" \
            | sed "s/^NET_DEV_1_/NET_DEV_${newidx}_/" >> "$tmp_new"
        awk -v n="$newidx" '
            /^NET_DEV_COUNT=/ { print "NET_DEV_COUNT=" n; next } { print }
        ' "$tmp_new" > "$tmp_new.2" && mv -f "$tmp_new.2" "$tmp_new"
        grep -q '^NET_DEV_COUNT=' "$tmp_new" || echo "NET_DEV_COUNT=$newidx" >> "$tmp_new"
        mv -f "$tmp_new" "$NETINFO_CACHE"
        return 0
    fi

    # 有则替换：保留其他设备与 Mac 侧字段，只替换目标设备的整段
    tmp_out="$NETINFO_CACHE.tmp.$$"
    awk -F= -v s="$serial" -v idx="$match_idx" '
        # 进入目标设备的块 → 跳过（后面用新数据补）
        $1 ~ /^NET_DEV_/ {
            split($1, a, "_")
            if (a[3] == idx) next
        }
        { print }
    ' "$NETINFO_CACHE" > "$tmp_out"
    # 新数据按缓存里的原序号写回
    printf '%s\n' "$fresh" | sed "s/^NET_DEV_1_/NET_DEV_${match_idx}_/" >> "$tmp_out"
    mv -f "$tmp_out" "$NETINFO_CACHE"
    return 0
}

# 等待守护的异步采集释放锁（避免两路 dumpsys 同时打手机）
netinfo_wait_lock() {
    local waited=0
    [ -d "$NETINFO_LOCK" ] || return 0
    while [ -d "$NETINFO_LOCK" ] && [ "$waited" -lt 40 ]; do
        sleep 0.5
        waited=$((waited + 1))
    done
    return 0
}

cmd_netinfo_refresh() {
    netinfo_wait_lock
    rm -rf "$NETINFO_LOCK" 2>/dev/null
    if ! mkdir "$NETINFO_LOCK" 2>/dev/null; then
        is_kv && echo "REFRESHED=0"
        return 1
    fi
    local rc=0
    trap 'rm -rf "$NETINFO_LOCK" 2>/dev/null' EXIT INT TERM
    net_info_collect > "$NETINFO_CACHE.tmp.$$" 2>/dev/null \
        && mv "$NETINFO_CACHE.tmp.$$" "$NETINFO_CACHE" \
        || { rm -f "$NETINFO_CACHE.tmp.$$"; rc=1; }
    rm -rf "$NETINFO_LOCK" 2>/dev/null
    trap - EXIT INT TERM
    if is_kv; then
        echo "REFRESHED=$([ "$rc" -eq 0 ] && echo 1 || echo 0)"
        [ "$rc" -eq 0 ] && cat "$NETINFO_CACHE"
    else
        if [ "$rc" -eq 0 ]; then
            echo "✓ 链路质量已刷新"
            cat "$NETINFO_CACHE"
        else
            echo "✗ 刷新失败（设备可能无响应）"
        fi
    fi
    return $rc
}

# 只刷新指定设备：采集单台 → 合并进缓存，其他设备保持不变。
cmd_netinfo_refresh_one() {
    local serial="${1:-}"
    if [ -z "$serial" ]; then
        cmd_netinfo_refresh
        return $?
    fi

    netinfo_wait_lock
    rm -rf "$NETINFO_LOCK" 2>/dev/null
    if ! mkdir "$NETINFO_LOCK" 2>/dev/null; then
        is_kv && echo "REFRESHED=0"
        return 1
    fi
    trap 'rm -rf "$NETINFO_LOCK" 2>/dev/null' EXIT INT TERM

    local fresh rc=0
    fresh=$(net_dev_collect "$serial" 1 2>/dev/null)
    if [ -z "$fresh" ] || ! printf '%s' "$fresh" | grep -q '^NET_DEV_1_SERIAL='; then
        rc=1
    else
        printf '%s\n' "$fresh" | netinfo_merge_one "$serial" || rc=1
    fi

    rm -rf "$NETINFO_LOCK" 2>/dev/null
    trap - EXIT INT TERM

    if is_kv; then
        echo "REFRESHED=$([ "$rc" -eq 0 ] && echo 1 || echo 0)"
        echo "SERIAL=$serial"
    else
        if [ "$rc" -eq 0 ]; then
            echo "✓ 已刷新 $serial 的链路质量"
        else
            echo "✗ 刷新失败：$serial 可能无响应"
        fi
    fi
    return $rc
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
    netinfo) net_info_collect ;;
    netinfo-refresh) shift; cmd_netinfo_refresh_one "${1:-}" ;;
    open)    shift; cmd_open "$@" ;;
    recover) shift; cmd_recover "$@" ;;
    devices) cmd_devices ;;
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
  adb-wifi.sh open [wireless|dev] [--serial <S>] [--all]
                              在手机上直接打开「无线调试」页面（默认）
                              或「开发者选项」页面，省去手动点菜单
                              --serial 指定某台设备；--all 对所有设备逐台打开
  adb-wifi.sh recover [--serial <S>] [--all]
                              主动恢复无线连接（无需 USB）
                              依次尝试：已有连接 → 记忆端点 → 扫描本网段
                              --serial 只恢复某台（不扫描网段）；--all 逐台校验
  adb-wifi.sh devices         列出当前设备（序列号 / 状态 / 通道 / 型号）
  adb-wifi.sh netinfo-refresh [SERIAL]
                              立即刷新链路质量（忽略 60 秒缓存）
                              带 SERIAL 时只刷该设备，其余设备缓存不变
  adb-wifi.sh rate [间隔秒]   查看当前 adb 传输速率（默认采样 1 秒）
USAGE
        ;;
esac
