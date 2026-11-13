#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
adb-wifi TUI —— Android 无线调试，全菜单操作，无需记忆任何命令。

特点：
  * 状态一目了然：守护进程 / 已连接设备 / 发现方式（mDNS、USB、记忆端点）
  * 自动诊断：识别"网络屏蔽 mDNS"等场景，给出可点击的解决方案
  * 半自动化修复：在手机上自动打开开发者选项页、自动连接、自动配对准入
  * 纯 Python 标准库 curses，零第三方依赖

启动： ./adbwifi  或  python3 bin/adbwifi-tui.py
"""

import os
import re
import sys
import unicodedata
import time
import signal
import subprocess
import threading
import curses

APP_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(APP_DIR, "bin", "adb-wifi.sh")
SUPPORT = os.path.expanduser("~/Library/Application Support/adb-wifi-manager")
LOG_FILE = os.path.join(SUPPORT, "logs", "adb-wifi.log")

ADB = os.path.expanduser("~/Library/Android/sdk/platform-tools/adb")
if not os.path.exists(ADB):
    try:
        ADB = subprocess.run(["which", "adb"], capture_output=True, text=True).stdout.strip() or "adb"
    except Exception:
        ADB = "adb"

ENV = dict(os.environ)
ENV["PATH"] = ("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:"
               + os.path.dirname(ADB))


# ============================== 基础工具 ==============================

def run(cmd, timeout=30, shell=False):
    """执行命令，返回 (returncode, stdout+stderr)"""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout, env=ENV,
                           shell=shell, errors="replace")
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        return -1, "执行超时"
    except Exception as e:  # noqa
        return -1, str(e)


def script(*args, timeout=40):
    return run(["/bin/bash", SCRIPT] + list(args), timeout=timeout)


def adb(*args, timeout=20):
    return run([ADB] + list(args), timeout=timeout)


def parse_kv(text):
    d = {}
    for line in text.splitlines():
        if "=" in line and not line.startswith(" "):
            k, _, v = line.partition("=")
            d[k.strip()] = v.strip()
    return d


# ============================== 状态采集 ==============================

class State:
    """一次诊断快照"""
    def __init__(self):
        self.raw = {}
        self.ts = 0.0
        self.error = ""

    @property
    def daemon_running(self):
        return bool(self.raw.get("DAEMON_PID"))

    @property
    def daemon_mode(self):
        return self.raw.get("DAEMON_MODE", "stopped")

    @property
    def wifi_devices(self):
        v = self.raw.get("WIFI_DEVICES", "")
        return [x for x in v.split(",") if x]

    @property
    def all_devices(self):
        v = self.raw.get("ALL_DEVICES", "")
        out = []
        for item in v.split(","):
            if "|" in item:
                name, st = item.split("|", 1)
                out.append((name, st))
        return out

    @property
    def has_usb(self):
        return bool(self.raw.get("USB_SERIAL"))

    @property
    def rate_down(self):
        """当前下行速率（易读字符串，如 1.2 MB/s）"""
        return self.raw.get("RATE_DOWN_HUMAN", "") or ""

    @property
    def rate_up(self):
        """当前上行速率"""
        return self.raw.get("RATE_UP_HUMAN", "") or ""

    @property
    def rate_total(self):
        """累计收发 (下行 MB, 上行 MB)"""
        d = self.raw.get("RATE_TOTAL_DOWN_MB", "0") or "0"
        u = self.raw.get("RATE_TOTAL_UP_MB", "0") or "0"
        return (d, u)

    @property
    def dev_links(self):
        """每台设备的链路质量指标（netinfo 采集，缓存 60 秒）"""
        try:
            n = int(self.raw.get("NET_DEV_COUNT", "0") or 0)
        except ValueError:
            return []
        out = []
        for i in range(1, n + 1):
            p = "NET_DEV_%d_" % i
            d = {
                "serial": self.raw.get(p + "SERIAL", ""),
                "transport": self.raw.get(p + "TRANSPORT", ""),
                "model": self.raw.get(p + "MODEL", ""),
                "ssid": self.raw.get(p + "SSID", ""),
                "bssid": self.raw.get(p + "BSSID", ""),
                "freq": self.raw.get(p + "FREQ", ""),
                "channel": self.raw.get(p + "CHANNEL", ""),
                "link": self.raw.get(p + "LINK", ""),
                "rssi": self.raw.get(p + "RSSI", ""),
                "rtt": self.raw.get(p + "RTT_AVG", ""),
                "battery": self.raw.get(p + "BATTERY", ""),
                "charging": self.raw.get(p + "CHARGING", ""),
            }
            if d["serial"]:
                out.append(d)
        return out

    @property
    def rate_stats(self):
        """传输时的平均 / 峰值速率（Mbps）"""
        return (self.raw.get("NET_RATE_AVG_MBPS", ""),
                self.raw.get("NET_RATE_MAX_MBPS", ""))

    @property
    def wifi_quality(self):
        """纯 Wi-Fi 链路质量（Mac ↔ AP），与 adb 无关。

        与 dev_links 的 adb 链路质量刻意分开：这里反映的是这台 Mac
        连 Wi-Fi 本身好不好，所有无线设备都受它影响。
        """
        r = self.raw
        snr = r.get("NET_MAC_SNR", "")
        rtt = r.get("NET_WIFI_RTT_AVG", "")
        if not snr and not rtt:
            return None
        return {
            "phy": r.get("NET_MAC_PHY", ""),
            "bw": r.get("NET_MAC_BW", ""),
            "mcs": r.get("NET_MAC_MCS", ""),
            "rssi": r.get("NET_MAC_RSSI", ""),
            "noise": r.get("NET_MAC_NOISE", ""),
            "snr": snr,
            "rtt": rtt,
            "rtt_min": r.get("NET_WIFI_RTT_MIN", ""),
            "rtt_max": r.get("NET_WIFI_RTT_MAX", ""),
            "jitter": r.get("NET_WIFI_JITTER", ""),
            "loss": r.get("NET_WIFI_LOSS", ""),
            "rate": r.get("NET_MAC_RATE", ""),
            "theo": r.get("NET_MAC_THEO", ""),
            "rate_now": r.get("NET_WIFI_RATE_NOW", ""),
            "rate_usable": r.get("NET_WIFI_RATE_USABLE", ""),
            "rate_ratio": r.get("NET_WIFI_RATE_RATIO", ""),
        }

    @property
    def channel_crowd(self):
        """当前信道的拥塞情况，与菜单栏同口径。

        返回 (AP 数, 等级, 最强干扰, 建议信道)；无数据时返回 None。
        信号好但延迟抖动大时，通常是同信道 AP 争用所致。
        """
        raw = self.raw
        try:
            aps = int(raw.get("NET_CHANNEL_APS", "0") or 0)
        except ValueError:
            return None
        if aps <= 0:
            return None
        crowd = raw.get("NET_CHANNEL_CROWD", "")
        if not crowd:
            crowd = "low" if aps <= 1 else ("medium" if aps <= 4 else "high")
        return {
            "aps": aps,
            "crowd": crowd,
            "channel": raw.get("NET_MAC_CHANNEL", ""),
            "strongest": raw.get("NET_CHANNEL_STRONGEST", ""),
            "best": raw.get("NET_CHANNEL_BEST", ""),
        }

    @property
    def mac_link(self):
        """Mac 侧 Wi-Fi 链路与电量（全局一份）"""
        return {
            "ssid": self.raw.get("NET_MAC_SSID", ""),
            "rate": self.raw.get("NET_MAC_RATE", ""),
            "channel": self.raw.get("NET_MAC_CHANNEL", ""),
            "rssi": self.raw.get("NET_MAC_RSSI", ""),
            "battery": self.raw.get("NET_MAC_BATTERY", ""),
            "power": self.raw.get("NET_MAC_POWER", ""),
        }

    @property
    def mdns_works(self):
        """mDNS 是否真的能发现 adb 服务"""
        return int(self.raw.get("MDNS_ADB_COUNT", "0") or 0) > 0

    @property
    def mdns_state(self):
        """mDNS 细分状态，与菜单栏一致：ok / stalled / flaky / blocked。

        adb 后台服务的 mDNS 模块会偶发卡死，与"网络屏蔽组播"是两回事——
        前者重启 adb 可恢复且已自动处理，后者是环境限制，混淆会误导读数。
        """
        if self.mdns_works:
            return "ok"
        try:
            empty = int(self.raw.get("MDNS_EMPTY_TURNS", "0") or 0)
        except ValueError:
            empty = 0
        st = self.raw.get("MDNS_STATE", "")
        if st == "stalled":
            return "stalled"
        if empty < 3:
            return "flaky"
        return "blocked"

    @property
    def mdns_found(self):
        return [x for x in self.raw.get("MDNS_FOUND", "").split(",") if x]

    @property
    def usb_found(self):
        return [x for x in self.raw.get("USB_FOUND", "").split(",") if x]

    @property
    def known_found(self):
        return [x for x in self.raw.get("KNOWN_FOUND", "").split(",") if x]

    @property
    def known_list(self):
        return [x for x in self.raw.get("KNOWN_LIST", "").split(",") if x]


EVENTS_LOG = os.path.join(SUPPORT, "state", "events.log")


def event_seq():
    """轻量读取设备事件序号（只 stat 文件，不跑 adb），用于判断是否需要刷新"""
    try:
        st = os.stat(EVENTS_LOG)
        return (st.st_size, st.st_mtime_ns)
    except OSError:
        return (0, 0)


def collect_state():
    st = State()
    code, out = script("diag", timeout=45)
    if code != 0 and not out.strip():
        st.error = "无法执行诊断脚本"
    st.raw = parse_kv(out)
    st.ts = time.time()
    if not st.raw:
        st.error = out.strip()[:200] or "诊断无输出"
    return st


# ============================== 诊断引擎 ==============================

class Issue:
    """一条诊断结论 + 可执行的解决方案"""
    def __init__(self, level, title, detail, actions):
        self.level = level       # "error" / "warn" / "info" / "ok"
        self.title = title
        self.detail = detail
        self.actions = actions   # [(label, callable)]


def diagnose(st):
    """返回 Issue 列表"""
    issues = []

    if st.error:
        issues.append(Issue("error", "诊断失败", st.error,
                            [("重新诊断", "reconnect_now"),
                             ("查看守护日志", "show_log")]))
        return issues

    if not st.raw:
        issues.append(Issue("warn", "尚未获取到设备状态",
                            "正在采集状态，请稍候；若长时间无变化请按 R 重试。",
                            [("重新诊断", "reconnect_now")]))
        return issues

    connected = st.wifi_devices
    mdns_ok = st.mdns_works
    has_usb = st.has_usb
    dev_opts = st.raw.get("DEV_DEV_OPTS", "")
    adb_wifi = st.raw.get("DEV_ADB_WIFI_ENABLED", "")

    # ---- 情况 1：一切正常 ----
    if connected and mdns_ok:
        issues.append(Issue("ok", "连接正常",
                            "无线设备已连接，mDNS 自动发现工作正常。", []))
        return issues

    if connected and not mdns_ok:
        issues.append(Issue(
            "ok", "设备已连接（但 mDNS 不可用）",
            "当前连接依靠「记忆端点」维持。此网络的 mDNS 组播被屏蔽，"
            "手机重启或端口变化后需重新连接一次。",
            [("手动添加新端口", "manual_connect")]))
        issues.append(Issue(
            "info", "当前网络屏蔽了 mDNS 组播广播",
            "这是导致「自动发现失效」的根因，不是配置错误。\n"
            "企业 Wi-Fi 常用客户端隔离/组播过滤，而 Android 无线调试依赖 mDNS 广播端口。\n"
            "推荐方案：① 插上 USB 线让工具直接读取真实端口（最可靠）\n"
            "          ② 换到手机热点或家庭网络\n"
            "          ③ 保持当前记忆端点连接，端口变化时手动补一次",
            [("① 插 USB 自动读取端口（说明）", "usb_help"),
             ("③ 手动添加新端口", "manual_connect"),
             ("② 查看完整操作指引", "help")]))
        return issues

    # ---- 情况 2：未连接 ----
    if not connected:
        # 2a 有 USB 但开发者选项没开
        if has_usb and dev_opts == "0":
            issues.append(Issue(
                "error", "手机的「开发者选项」未开启",
                "工具已检测到 USB 连接，但开发者选项处于关闭状态。\n"
                "建议按下面任一步骤操作，完成后回到本界面按 R 刷新。",
                [("① 在手机上自动打开开发者选项页", "phone_dev_settings"),
                 ("② 查看开启步骤", "help_devopts")]))
        elif has_usb and adb_wifi == "0":
            issues.append(Issue(
                "error", "手机的「无线调试」开关未打开",
                "开发者选项已开启，但无线调试处于关闭状态。\n"
                "该开关必须打开，本工具才能通过 Wi-Fi 连接。",
                [("① 在手机上自动打开无线调试页", "phone_wireless"),
                 ("② 查看开启步骤", "help_wireless")]))
        elif has_usb:
            issues.append(Issue(
                "warn", "已检测到 USB 设备，但尚未建立无线连接",
                "正在尝试读取手机的真实无线调试端口。按 R 重新诊断。",
                [("立即重试连接", "reconnect_now")]))
        elif not mdns_ok:
            issues.append(Issue(
                "error", "未发现任何设备，且此网络屏蔽了 mDNS 广播",
                "这是最常见的情况：网络环境导致自动发现失效。\n"
                "请选择下面的解决方案。",
                [("① 用 USB 线插上手机（自动读取端口）", "usb_help"),
                 ("② 手动输入手机上显示的 IP:端口", "manual_connect"),
                 ("③ 查看完整操作指引", "help")]))
        else:
            issues.append(Issue(
                "warn", "mDNS 正常，但没有发现已打开无线调试的设备",
                "请确认手机「开发者选项 → 无线调试」已打开，且与本机在同一 Wi-Fi。",
                [("在手机上打开开发者选项页", "phone_dev_settings"),
                 ("手动输入 IP:端口", "manual_connect")]))

    # ---- 守护进程 ----
    if not st.daemon_running:
        issues.append(Issue(
            "warn", "后台守护进程未运行",
            "开启后无需手动操作，掉线会自动重连。",
            [("启动守护（含开机自启）", "start_daemon")]))

    return issues


# ============================== 修复动作 ==============================

def open_mac_settings():
    """打开 macOS 网络设置（排查 Wi-Fi / 网络隔离）"""
    for url in ["x-apple.systempreferences:com.apple.wifi-settings-extension",
                "x-apple.systempreferences:com.apple.preference.network"]:
        run(["/usr/bin/open", url])
        time.sleep(0.4)
    return "已打开 macOS 网络设置"


def usb_serial():
    """返回当前 USB 连接的设备序列号（无线设备不算）"""
    code, out = adb("devices")
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "device" and ":" not in parts[0]:
            return parts[0]
    return ""


def wifi_serial():
    """返回当前无线连接的端点（形如 192.168.1.5:5555），便于无 USB 时也能跳转设置页"""
    code, out = adb("devices")
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "device" and ":" in parts[0]:
            return parts[0]
    return ""


def _am_start(serial, args):
    """在指定（USB）设备上执行 am start"""
    cmd = ["shell"]
    if serial:
        cmd = ["-s", serial, "shell"]
    return adb(*(cmd + ["am", "start"] + args))


def open_settings_page_via_script(page="wireless", serial=None):
    """调用 adb-wifi.sh open，复用脚本里统一的多 ROM 跳转策略。

    脚本会按可靠性依次尝试：
      ① SubSettings + WirelessDebuggingFragment（AOSP 通用，MIUI 实测有效，精确到无线调试页）
      ② Settings$WirelessDebuggingActivity（部分 ROM 的独立页面）
      ③ 开发者选项页（兜底）

    serial 非空时只对该设备操作（与菜单栏"每台设备各自跳转"一致），
    不传则由脚本自动挑一台。
    返回 (是否成功, 输出文本)
    """
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "adb-wifi.sh")
    if not os.path.exists(script):
        return (False, "未找到 adb-wifi.sh")
    cmd = ["/bin/bash", script, "open", page]
    if serial:
        cmd += ["--serial", serial]
    try:
        r = subprocess.run(cmd,
                           capture_output=True, text=True, timeout=60)
        out = (r.stdout or "") + (r.stderr or "")
        return (r.returncode == 0, out.strip())
    except Exception as e:  # noqa: BLE001
        return (False, "调用失败: %s" % e)


def open_android_dev_settings(serial=None):
    """在手机上打开开发者选项页"""
    serial = serial or usb_serial() or wifi_serial()
    if not serial:
        return ("需要先连接手机（USB 或无线均可）。\n"
                "插好线后按 R 刷新，再点此按钮。")
    ok, out = open_settings_page_via_script("dev", serial)
    if not ok:
        return "打开失败：" + out[:200]
    return ("已在手机上打开「开发者选项」页面。\n\n"
            "接下来的路径：\n"
            "  开发者选项 → 无线调试 → 打开开关\n"
            "完成后回到本界面按 R 重新诊断。")


def open_android_wireless_debug(serial=None):
    """直接在手机上打开「无线调试」页面（多 ROM 自适应）"""
    serial = serial or usb_serial() or wifi_serial()
    if not serial:
        return ("需要先连接手机（USB 或无线均可）才能自动跳转页面。\n\n"
                "也可以手动操作：设置 → 开发者选项 → 无线调试")
    ok, out = open_settings_page_via_script("wireless", serial)
    if not ok:
        return ("无法自动打开，请手动进入：设置 → 开发者选项 → 无线调试\n\n"
                "错误信息：" + out[:200])
    if "▽" in out or "未能直接定位" in out:
        return ("已在手机上打开「开发者选项」。\n\n"
                "该 ROM 未能直接定位到「无线调试」页，请在列表中手动点击「无线调试」。")
    # 附带开关状态提示
    extra = ""
    if "未开启" in out:
        extra = "\n\n提示：「无线调试」开关当前是关闭的，请在手机上点开它。"
    elif "已开启" in out:
        extra = "\n\n「无线调试」开关当前已开启。"
    return "已在手机上打开「无线调试」页面。" + extra


def open_pairing_help():
    return ("配对步骤：\n"
            "1. 手机上：设置 → 开发者选项 → 无线调试\n"
            "2. 点击「使用配对码配对设备」，记下 6 位码和 IP:端口\n"
            "3. 在本工具按 P，输入配对码和端口\n"
            "4. 配对成功后，再按 C 输入 IP:无线调试端口")


def adb_connect(endpoint):
    code, out = adb("connect", endpoint, timeout=20)
    return out.strip()


def adb_pair(endpoint, code_):
    p = subprocess.Popen([ADB, "pair", endpoint], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, env=ENV)
    try:
        out, _ = p.communicate(input=code_ + "\n", timeout=25)
    except subprocess.TimeoutExpired:
        p.kill()
        return "配对超时"
    return out.strip()


def read_log_tail(n=500):
    try:
        with open(LOG_FILE, "r", errors="replace") as f:
            lines = f.readlines()
        return lines[-n:]
    except FileNotFoundError:
        return []


# ============================== TUI 组件 ==============================

C_HEADER = 1
C_BORDER = 2
C_OK = 3
C_WARN = 4
C_ERR = 5
C_INFO = 6
C_DIM = 7
C_SEL = 8
C_TITLE = 9


# ---------------- 鼠标事件兼容层 ----------------
# macOS 自带 Python 3.9 + 系统 ncurses 缺少 BUTTON5_* 常量，
# 而滚轮「向下」恰恰会以该位上报（值为 0x8000000）。
# 这里按掩码直接定义，不依赖属性是否存在，避免 AttributeError 崩溃。
def _btn(attr, mask):
    return int(getattr(curses, attr, mask))

MOUSE_LEFT = (_btn("BUTTON1_CLICKED", 0x4)
              | _btn("BUTTON1_PRESSED", 0x2)
              | _btn("BUTTON1_RELEASED", 0x1)
              | _btn("BUTTON1_DOUBLE_CLICKED", 0x8)
              | _btn("BUTTON1_TRIPLE_CLICKED", 0x10))
MOUSE_WHEEL_UP = _btn("BUTTON4_PRESSED", 0x80000)
MOUSE_WHEEL_DOWN = _btn("BUTTON5_PRESSED", 0x8000000)



# ---------------- 显示宽度工具（中文占 2 列，必须按列而非字符计算） ----------------

def meter(filled, total):
    """量表条：filled 个实心格 + 剩余空心格（与菜单栏符号一致）"""
    n = max(0, min(filled, total))
    return "█" * n + "░" * (total - n)


def rtt_level(v):
    """延迟分档（3 档）：返回 (档位, 等级词, 量表)"""
    if v < 20:
        return 3, "优秀", meter(3, 3)
    if v < 50:
        return 2, "一般", meter(2, 3)
    return 1, "较差", meter(1, 3)


def signal_level(v):
    """信号分档（5 档）：返回 (档位, 等级词, 量表)"""
    if v > -50:
        return 5, "极佳", meter(5, 5)
    if v > -60:
        return 4, "优秀", meter(4, 5)
    if v > -70:
        return 3, "良好", meter(3, 5)
    if v > -80:
        return 2, "偏弱", meter(2, 5)
    return 1, "很差", meter(1, 5)


def rtt_grade(v):
    """兼容旧调用：只返回等级词"""
    return rtt_level(v)[1]


def signal_grade(v):
    """兼容旧调用：只返回等级词"""
    return signal_level(v)[1]


def throughput_grade(peak_mbps, ceiling_mbps):
    """吞吐利用率评级（与菜单栏 net.tp.good/fair/poor 一致）。

    依据「峰值 ÷ 上限」而不是绝对速度：不同 Wi-Fi 制式上限不同，
    只有比例才能跨设备横向比较。
    """
    try:
        peak = float(peak_mbps or 0)
        ceil = float(ceiling_mbps or 0)
    except (TypeError, ValueError):
        return None, None
    if ceil <= 0 or peak <= 0:
        return None, None
    usage = peak / ceil * 100.0
    if usage >= 30:
        return usage, "良好" + meter(3, 3)
    if usage >= 10:
        return usage, "一般" + meter(2, 3)
    return usage, "偏低" + meter(1, 3)


def snr_grade(db):
    """信噪比分级（dB），与菜单栏 wifi.snr 同一套档位。"""
    if db >= 40:
        return 5, "极佳"
    if db >= 30:
        return 4, "良好"
    if db >= 20:
        return 3, "一般"
    if db >= 10:
        return 2, "偏弱"
    return 1, "很差"


def wifi_rtt_grade(ms):
    """Wi-Fi 延迟分级（ms）：只看 Mac↔AP 这一段。"""
    if ms < 10:
        return 3, "优秀"
    if ms < 30:
        return 2, "一般"
    return 1, "较差"


def jitter_grade(ms):
    if ms < 10:
        return "平稳"
    if ms < 50:
        return "可接受"
    return "抖动大"


def same_ap_tag(dev, mac):
    """手机与这台电脑是否同一 AP 的符号标识（与菜单栏同一套判据和符号）。

    限制：macOS 不提供 Mac 侧 BSSID，只能用 SSID + 信道间接推断。
      SSID 不同           → ⚠（不同 AP）
      SSID 同 + 信道同    → 🔗（同一 AP）
      SSID 同 + 信道不同  → ⚠（不同 AP）
      缺数据 / USB 设备    → ""（不显示）
    """
    if dev.get("transport") != "wifi":
        return ""
    d_ssid = dev.get("ssid", "")
    m_ssid = mac.get("ssid", "")
    if not d_ssid or not m_ssid:
        return ""
    if d_ssid != m_ssid:
        return "⚠"
    d_ch = dev.get("channel", "")
    m_ch = mac.get("channel", "")
    if not d_ch or not m_ch:
        return "🔗"
    return "🔗" if d_ch == m_ch else "⚠"


def link_rate_text(mbps):
    """链路速率 Mbps → 字节基准 MB/s（与 ↓↑ 传输速率口径一致）"""
    try:
        mbs = float(mbps) / 8.0
    except (TypeError, ValueError):
        return "-"
    if mbs >= 10:
        return "%.0f" % mbs
    if mbs >= 1:
        return "%.1f" % mbs
    return "%.2f" % mbs


def dwidth(text):
    """字符串在终端上的显示宽度"""
    w = 0
    for ch in text:
        w += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return w


def clip_to(text, maxw):
    """按显示宽度截断，末尾不加省略号（避免错位）"""
    if maxw <= 0:
        return ""
    out, w = [], 0
    for ch in text:
        cw = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
        if w + cw > maxw:
            break
        out.append(ch)
        w += cw
    return "".join(out)


def wrap_text(text, maxw):
    """按显示宽度折行（中文友好）"""
    if maxw <= 2:
        return [text]
    lines, cur, w = [], "", 0
    for ch in text:
        cw = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
        if w + cw > maxw:
            lines.append(cur)
            cur, w = "", 0
        cur += ch
        w += cw
    lines.append(cur)
    return lines or [""]


def pad_to(text, width):
    """右补空格到指定显示宽度"""
    d = width - dwidth(text)
    return text + (" " * d if d > 0 else "")



class InputDialog:
    """单行输入框"""
    def __init__(self, stdscr, title, prompt, default="", hint=""):
        self.scr = stdscr
        self.title = title
        self.prompt = prompt
        self.value = default
        self.hint = hint
        self.cursor = len(default)

    def edit(self):
        curses.curs_set(1)
        while True:
            h, w = self.scr.getmaxyx()
            bw = min(max(len(self.prompt) + 20, 56), w - 4)
            bh = 7 + (2 if self.hint else 0)
            y = max(0, (h - bh) // 2)
            x = max(0, (w - bw) // 2)
            win = curses.newwin(bh, bw, y, x)
            win.keypad(True)
            win.attron(curses.color_pair(C_BORDER))
            win.box()
            title = " " + self.title + " "
            win.addstr(0, 2, title[:bw - 4])
            win.addstr(2, 2, self.prompt[:bw - 4])
            if self.hint:
                for i, ln in enumerate(self.hint.split("\n")[:2]):
                    win.addstr(3 + i, 2, ln[:bw - 4], curses.color_pair(C_DIM))
                fy = 3 + min(2, len(self.hint.split("\n")))
            else:
                fy = 3
            win.addstr(fy, 2, "> ")
            field_w = bw - 6
            disp = self.value[-field_w:]
            win.addstr(fy, 4, disp.ljust(field_w))
            win.addstr(fy + 2, 2, "Enter 确认   Esc 取消".ljust(bw - 4),
                       curses.color_pair(C_DIM))
            win.attroff(curses.color_pair(C_BORDER))
            cy = fy
            cx = 4 + min(len(self.value), field_w - 1)
            win.move(cy, cx)
            win.refresh()

            ch = win.getch()
            if ch in (27,):
                curses.curs_set(0)
                return None
            elif ch in (10, 13, curses.KEY_ENTER):
                curses.curs_set(0)
                return self.value.strip()
            elif ch in (curses.KEY_BACKSPACE, 127, 8):
                self.value = self.value[:-1]
            elif ch == curses.KEY_DC:
                self.value = ""
            elif 32 <= ch < 127:
                self.value += chr(ch)


class Menu:
    """可点击/键盘操作的菜单项"""
    def __init__(self, key, label, desc, fn):
        self.key = key
        self.label = label
        self.desc = desc
        self.fn = fn


class App:
    def __init__(self, stdscr):
        self.scr = stdscr
        self.state = State()
        self.issues = []
        self.selected = 0
        self.status_msg = "正在诊断…"
        self.busy = False
        self.running = True
        self.detail_view = None      # 当前展示的详情文本
        self.detail_title = ""
        self.scroll = 0
        self.mouse_enabled = False
        self.click_regions = []      # (y, x1, x2, callback)
        self.dev_focus = 0           # 0 = 显示全部设备；N = 只展开第 N 台（1 起）
        self.last_event_seq = (0, 0)

    # -------------------------- 配色 --------------------------
    def init_colors(self):
        try:
            curses.start_color()
            curses.use_default_colors()
            curses.init_pair(C_HEADER, curses.COLOR_WHITE, curses.COLOR_BLUE)
            curses.init_pair(C_BORDER, curses.COLOR_CYAN, -1)
            curses.init_pair(C_OK, curses.COLOR_GREEN, -1)
            curses.init_pair(C_WARN, curses.COLOR_YELLOW, -1)
            curses.init_pair(C_ERR, curses.COLOR_RED, -1)
            curses.init_pair(C_INFO, curses.COLOR_CYAN, -1)
            curses.init_pair(C_DIM, curses.COLOR_WHITE, -1)
            curses.init_pair(C_SEL, curses.COLOR_BLACK, curses.COLOR_CYAN)
            curses.init_pair(C_TITLE, curses.COLOR_BLUE, -1)
        except Exception:
            pass

    # -------------------------- 刷新 --------------------------
    def refresh_state(self):
        self.busy = True
        self.status_msg = "正在诊断，请稍候…"
        self.draw()
        st = collect_state()
        self.state = st
        self.issues = diagnose(st)
        self.last_event_seq = event_seq()
        self.busy = False
        self.status_msg = "诊断完成  按 R 刷新"
        if self.selected >= len(self.issues):
            self.selected = 0

    def refresh_async(self):
        if self.busy:
            return
        t = threading.Thread(target=self.refresh_state, daemon=True)
        t.start()

    # -------------------------- 绘制 --------------------------
    def addstr(self, y, x, text, attr=0):
        """按显示列宽绘制（中文占 2 列），超宽自动裁剪"""
        h, w = self.scr.getmaxyx()
        if y < 0 or y >= h or x >= w:
            return
        avail = w - x - 1
        if avail <= 0:
            return
        text = clip_to(text, avail)
        if not text:
            return
        try:
            self.scr.addstr(y, x, text, attr)
        except curses.error:
            pass

    def hline(self, y, ch="─", attr=None):
        h, w = self.scr.getmaxyx()
        if attr is None:
            attr = curses.color_pair(C_BORDER)
        self.addstr(y, 0, ch * (w - 1), attr)

    def draw(self):
        self.scr.erase()
        h, w = self.scr.getmaxyx()
        self.click_regions = []

        # ---- 标题栏（整行反色背景，中英文混排按显示列宽定位）----
        st = self.state
        if st.daemon_running:
            mode = "开机自启" if st.daemon_mode == "launchd" else "手动"
            ds = "● 守护运行中 (%s)" % mode
            ds_attr = curses.color_pair(C_OK)
        else:
            ds = "○ 守护已停止"
            ds_attr = curses.color_pair(C_DIM)
        title = " ADB 无线调试管理器 "
        help_txt = "Q 退出  R 刷新  ? 帮助  "
        hw = dwidth(help_txt)
        try:
            self.scr.addstr(0, 0, " " * (w - 1), curses.color_pair(C_HEADER))
        except curses.error:
            pass
        self.addstr(0, 0, title, curses.color_pair(C_HEADER) | curses.A_BOLD)
        x = dwidth(title) + 2
        self.addstr(0, x, ds, ds_attr | curses.A_BOLD)
        if x + dwidth(ds) + hw + 3 < w:
            self.addstr(0, w - hw - 1, help_txt, curses.color_pair(C_HEADER))

        y = 1
        if h < 20 or w < 60:
            self.addstr(y, 1, "窗口太小，请放大终端 (至少 60x20)", curses.color_pair(C_ERR))
            self.scr.refresh()
            return

        # ---- 设备视图指示（聚焦时置顶显示，切换后立刻可见）----
        links_now = st.dev_links
        focus = self.dev_focus
        if focus and 1 <= focus <= len(links_now):
            fd = links_now[focus - 1]
            fname = (fd["model"] or fd["serial"]) + " · " + fd["serial"]
            bar = " 当前仅显示设备 [%d/%d] %s —— 按 0 恢复全部 " % (
                focus, len(links_now), fname)
            attr = curses.color_pair(C_WARN) | curses.A_BOLD
            self.addstr(y, 1, pad_to(bar, min(w - 2, dwidth(bar) + 1)), attr)
            self.click_regions.append((y, 1, w - 2,
                                       lambda: self.set_device_focus(0)))
            y += 1

        # ---- 连接状态区 ----
        self.addstr(y, 1, "连接状态", curses.color_pair(C_TITLE) | curses.A_BOLD)
        y += 1
        # 设备列表：聚焦某台时只高亮它，其余变暗；未聚焦时全部正常显示。
        # 原来固定只列前 3 台，多设备时第 4 台起完全不可见，现在按剩余高度显示并计数。
        devs = st.wifi_devices
        f_idx = self.dev_focus if 1 <= self.dev_focus <= len(links_now) else 0
        f_serial = links_now[f_idx - 1]["serial"] if f_idx else None
        if devs:
            room = max(1, h - y - 8)
            for i, d in enumerate(devs[:room]):
                if f_serial and d == f_serial:
                    self.addstr(y, 2, "▶ %s" % d,
                                curses.color_pair(C_WARN) | curses.A_BOLD)
                elif f_serial:
                    self.addstr(y, 2, "  %s" % d, curses.color_pair(C_DIM))
                else:
                    self.addstr(y, 2, "✓ %s" % d,
                                curses.color_pair(C_OK) | curses.A_BOLD)
                y += 1
            if len(devs) > room:
                self.addstr(y, 2, "…另有 %d 台（视窗过小）" % (len(devs) - room),
                            curses.color_pair(C_DIM))
                y += 1
        else:
            self.addstr(y, 2, "✗ 没有无线设备连接", curses.color_pair(C_ERR))
            y += 1

        usb = [d for d, s in st.all_devices if ":" not in d]
        if usb:
            shown_usb = ", ".join(usb[:3]) + ("…" if len(usb) > 3 else "")
            self.addstr(y, 2, "USB: %s" % shown_usb, curses.color_pair(C_INFO))
        else:
            self.addstr(y, 2, "USB: 未连接", curses.color_pair(C_DIM))
        y += 1

        # 发现方式
        # 四态显示，与菜单栏措辞一致（避免把"adb 卡死"误报成"网络屏蔽"）
        _ms = st.mdns_state
        if _ms == "ok":
            mdns, mdns_attr = "mDNS: 可用", curses.color_pair(C_OK)
        elif _ms == "stalled":
            mdns, mdns_attr = "mDNS: 曾卡死已恢复", curses.color_pair(C_WARN)
        elif _ms == "flaky":
            mdns, mdns_attr = "mDNS: 无响应重试中", curses.color_pair(C_WARN)
        else:
            mdns, mdns_attr = "mDNS: 被屏蔽 ✗", curses.color_pair(C_ERR)
        self.addstr(y, 2, mdns, mdns_attr)
        how = []
        if st.usb_found:
            how.append("USB 读取")
        if st.mdns_found:
            how.append("mDNS")
        if st.known_found:
            how.append("记忆端点")
        self.addstr(y, 2 + dwidth(mdns) + 3,
                    "发现方式: " + ("、".join(how) if how else "无"),
                    curses.color_pair(C_INFO))
        y += 1
        # 本机网络信息（便于确认与手机是否同一网段）
        mac_ip = st.raw.get("MAC_IP", "")
        dev_ip = st.raw.get("DEV_WIFI_IP", "")
        if mac_ip:
            net_txt = "本机: %s" % mac_ip
            note = ""
            if dev_ip and mac_ip.split(".")[:3] != dev_ip.split(".")[:3]:
                note = "  ⚠ 与手机网段不同"
            self.addstr(y, 2, net_txt + note,
                        curses.color_pair(C_WARN) if note else curses.color_pair(C_DIM))
            y += 1

            # 纯 Wi-Fi 质量（Mac ↔ AP）：与 adb 链路分开，所有无线设备都受它影响
            wq = st.wifi_quality
            if wq:
                # 带宽三口径：理论峰值 / 当前协商 / 实际可用
                try:
                    _theo = float(wq["theo"])
                    _now = float(wq["rate_now"])
                    _us = float(wq["rate_usable"])
                    _ra = int(float(wq["rate_ratio"]))
                    _rl = "接近满速" if _ra >= 80 else ("部分降级" if _ra >= 50 else "严重降级")
                    _rs = 3 if _ra >= 80 else (2 if _ra >= 50 else 1)
                    self.addstr(y, 2, "带宽 %s 理论 %.0f MB/s · 当前协商 %.1f · 实际可用 %.0f MB/s（达成率 %d%% %s）" % (
                        meter(_rs, 3), _theo / 8, _now / 8, _us / 8, _ra, _rl),
                        curses.color_pair(C_INFO))
                    y += 1
                except ValueError:
                    pass
            if wq and wq["snr"]:
                try:
                    _snr = float(wq["snr"])
                    _sstep, _slbl = snr_grade(_snr)
                    self.addstr(y, 2, "Wi-Fi %s %s · 信噪比 %.0f dB %s" % (
                        wq["phy"] or "", ("%s MHz" % wq["bw"]) if wq["bw"] else "",
                        _snr, meter(_sstep, 5)), curses.color_pair(C_INFO))
                    y += 1
                    if wq["rtt"]:
                        _r = float(wq["rtt"])
                        _rs, _rl = wifi_rtt_grade(_r)
                        _jd = ""
                        if wq["jitter"]:
                            try:
                                _jd = " · 抖动 %.1f ms %s" % (
                                    float(wq["jitter"]), jitter_grade(float(wq["jitter"])))
                            except ValueError:
                                pass
                        self.addstr(y, 2, "  Wi-Fi 延迟 %.1f ms %s%s" % (
                            _r, meter(_rs, 3), _jd), curses.color_pair(C_DIM))
                        y += 1
                except ValueError:
                    pass

            # 信道拥塞：信号好但速度慢时的头号嫌疑
            cc = st.channel_crowd
            if cc:
                _lbl = {"low": "空闲", "medium": "一般", "high": "拥挤"}.get(cc["crowd"], "?")
                _txt = "信道: %s  拥挤度: %d 个 AP（%s）" % (cc["channel"] or "-", cc["aps"], _lbl)
                _attr = (curses.color_pair(C_WARN) if cc["crowd"] == "high"
                         else curses.color_pair(C_DIM))
                self.addstr(y, 2, _txt, _attr)
                if cc["crowd"] == "high" and y < h - 8:
                    # 拥挤时补一行建议，直接告诉用户该换到哪个信道
                    _st = cc["strongest"].replace("|", " ")
                    _bs = cc["best"].replace("|", "（空闲 ", 1) + " 个 AP）"
                    self.addstr(y + 1, 2, "  最强干扰 %s dBm · 建议换到信道 %s" % (
                        _st, _bs) if _st else "  建议换到更空闲的信道", curses.color_pair(C_DIM))
                    y += 1
                y += 1

        # adb 传输速率（仅在有设备连接时显示）
        if st.all_devices and st.rate_down:
            rd, ru = st.rate_total
            rate_txt = "传输: ↓ %s  ↑ %s" % (st.rate_down, st.rate_up)
            # 有实际流量时用高亮色，空闲时用暗色，一眼看出是否在传输
            idle = ("0 KB/s", "")
            active = st.rate_down not in idle or st.rate_up not in idle
            self.addstr(y, 2, rate_txt,
                        curses.color_pair(C_OK) if active else curses.color_pair(C_DIM))
            self.addstr(y, 2 + dwidth(rate_txt) + 3,
                        "累计: 收 %s MB / 发 %s MB" % (rd, ru),
                        curses.color_pair(C_DIM))
            y += 1

        # ---- 链路质量 ----
        # 与菜单栏同一份 netinfo 数据、同一套评级文案，但按 TUI 特性做了三层适配：
        #   1) 宽度：菜单栏用 tooltip 承载说明，TUI 没有 tooltip，改为按列宽自适应
        #      短布局只留关键数字，宽终端才追加「评级 + 说明」
        #   2) 行数：菜单栏能无限纵向展开，TUI 固定屏。每台设备严格 3 行
        #      （名称 / 延迟+信号 / 吞吐），超出的设备数按剩余高度截断并提示
        #   3) 单位：表头统一声明，行内不重复 mm/dBm/MB/s，省出宽度给评级
        links = st.dev_links
        if links:
            self.addstr(y, 1, "网络速度", curses.color_pair(C_TITLE) | curses.A_BOLD)
            unit_txt = "延迟 ms · 信号 dBm · 速度 MB/s"
            if dwidth(unit_txt) + 12 < w:
                self.addstr(y, 11, unit_txt, curses.color_pair(C_DIM))
            # 设备聚焦提示：聚焦时显示「只看 2/3」，否则在设备多时提示可以按数字
            if self.dev_focus and 1 <= self.dev_focus <= len(links):
                tag = "只看 %d/%d  按 0 显示全部" % (self.dev_focus, len(links))
                self.addstr(y, w - dwidth(tag) - 2, tag, curses.color_pair(C_WARN))
            elif len(links) > 1 and w >= 90:
                tag = "按 1-%d 只看某台" % min(9, len(links))
                self.addstr(y, w - dwidth(tag) - 2, tag, curses.color_pair(C_DIM))
            y += 1
            avg, peak = st.rate_stats

            # 行数预算：留 6 行给下方诊断区，Mac 侧再占 1 行。
            # 每台设备占用行数并不固定（无线含 AP 行是 4 行，USB 是 3 行，窄终端无线是 3 行），
            # 必须逐台累加计算，不能用「每台 3 行」的固定值估算，否则会超预算挤压诊断区。
            def device_rows(d):
                n = 2                     # 设备名 + 延迟/信号
                if d["transport"] != "wifi":
                    return 2              # 名称 + USB 直连
                n += 1                    # 吞吐行
                if d["ssid"] and w >= 78:
                    n += 1                # AP 行（窄终端不显示）
                return n

            budget = h - y - 6 - 1        # 扣掉诊断区与 Mac 侧
            shown, used = [], 0
            for d in links:
                need = device_rows(d)
                if used + need > budget and shown:
                    break
                shown.append(d)
                used += need

            # 设备聚焦：按 1–9 只看某一台（设备多到一屏放不下时用）。
            # 聚焦后不再受高度预算限制，可以完整展示该设备的所有指标。
            focusing = bool(self.dev_focus and 1 <= self.dev_focus <= len(links))
            if focusing:
                shown = [links[self.dev_focus - 1]]
                hidden = 0
                budget = 10 ** 6          # 聚焦时忽略高度预算
            for d in shown:
                # 1) 设备名 + 电量（一行搞定，不额外占行）
                # 序号前缀：与数字键一一对应，用户才知道该按几
                idx = links.index(d) + 1
                # 设备名后紧跟「同 AP」标识，与菜单栏口径一致：
                #   🔗 同一 AP   ⚠ 不同 AP   无符号 = 无法判断
                ap_tag = same_ap_tag(d, st.mac_link)
                label = "[%d] " % idx + d["serial"] + (
                    (" · " + d["model"]) if d["model"] else "")
                if d["transport"] != "wifi":
                    label += " · USB"
                elif ap_tag:
                    label += " · " + ap_tag
                if d["battery"]:
                    label += "  %s%%%s" % (
                        d["battery"], "⚡" if d["charging"] == "1" else "")
                self.addstr(y, 2, label, curses.color_pair(C_DIM) | curses.A_BOLD)
                # 点击设备名同样可以聚焦（仅非聚焦状态下有意义）
                if not (self.dev_focus and 1 <= self.dev_focus <= len(links)):
                    self.click_regions.append(
                        (y, 2, min(w - 2, 2 + dwidth(label)),
                         lambda i=idx: self.set_device_focus(i)))
                y += 1

                if d["transport"] != "wifi":
                    # USB 设备没有网络指标，一行说完即可；不再补占位符
                    self.addstr(y, 4, "USB 直连（不经过 Wi-Fi，不上报无线指标）",
                                curses.color_pair(C_DIM))
                    y += 1
                    continue

                # 2) 延迟 + 信号 合并一行：窄终端只给数值，宽终端追加「量表 + 等级词」
                segs, rtt_val = [], None
                if d["rtt"]:
                    try:
                        rtt_val = float(d["rtt"])
                        segs.append("延迟 %.1f" % rtt_val)
                        if w >= 96:
                            _, lbl, mtr = rtt_level(rtt_val)
                            segs[-1] += " %s %s" % (mtr, lbl)
                    except ValueError:
                        pass
                if d["rssi"]:
                    segs.append("信号 %s" % d["rssi"])
                    try:
                        if w >= 96:
                            _, lbl, mtr = signal_level(float(d["rssi"]))
                            segs[-1] += " %s %s" % (mtr, lbl)
                    except ValueError:
                        pass
                attr2 = curses.color_pair(C_WARN if (rtt_val and rtt_val > 50) else C_DIM)
                self.addstr(y, 4, " · ".join(segs) if segs else "-", attr2)
                y += 1

                # 3) 吞吐：上限 / 平均 / 最大（+评级）
                if d["link"]:
                    try:
                        link_mbps = float(d["link"])
                        ceiling_mbps = link_mbps * 0.6
                        ceiling = link_rate_text(ceiling_mbps)
                    except ValueError:
                        link_mbps, ceiling_mbps, ceiling = None, None, "-"
                    try:
                        avg_v = float(avg or 0)
                    except ValueError:
                        avg_v = 0.0
                    try:
                        peak_v = float(peak or 0)
                    except ValueError:
                        peak_v = 0.0

                    if avg_v <= 0 and peak_v <= 0:
                        line3 = "速度 上限 %s MB/s · 暂无传输（健康 ≥30%%上限）" % ceiling
                        attr3 = curses.color_pair(C_DIM)
                        usage = None
                    else:
                        avg_txt = "<0.1" if avg_v < 0.8 else link_rate_text(avg_v)
                        peak_txt = link_rate_text(peak_v)
                        usage, grade = throughput_grade(peak_v, ceiling_mbps)
                        # 宽度不足时省略均值（它变化最慢、参考价值最低）
                        if w >= 96:
                            line3 = "速度 上限 %s MB/s · 平均 %s · 最大 %s" % (
                                ceiling, avg_txt, peak_txt)
                        elif w >= 78:
                            line3 = "速度 上限 %s MB/s · 最大 %s" % (ceiling, peak_txt)
                        else:
                            line3 = "速度 上限 %s MB/s · 峰值 %s" % (ceiling, peak_txt)
                        if grade and w >= 78:
                            # 明确的"占上限"而不是裸百分数
                            line3 += "（%s，占上限 %.0f%%）" % (
                                grade, usage if usage is not None else 0)
                        # 偏低时高亮：提醒瓶颈在延迟而非带宽
                        attr3 = curses.color_pair(
                            C_WARN if (usage is not None and usage < 10) else C_DIM)
                    self.addstr(y, 4, line3, attr3)
                    y += 1

                    # 窄终端放不下 AP 行时不显示，避免挤占诊断区
                    # BSSID 末段用于判断两台设备是否接在同一 AP（与菜单栏一致）
                    if d["ssid"] and w >= 78 and y < h - 8:
                        bssid_short = "-"
                        if d.get("bssid"):
                            parts = d["bssid"].split(":")
                            bssid_short = ("…" + ":".join(parts[-2:])
                                           if len(parts) >= 2 else d["bssid"])
                        line_ap = "AP %s · 信道 %s · %s MHz · BSSID %s" % (
                            d["ssid"], d["channel"] or "-", d["freq"] or "-", bssid_short)
                        self.addstr(y, 4, line_ap, curses.color_pair(C_DIM))
                        y += 1
                    # 该设备的操作：与菜单栏设备子菜单一一对应。
                    # 聚焦状态下才展开（否则每台都列会撑爆屏幕），提示按键即可。
                    if focusing and y < h - 7:
                        acts = "F 刷新 · S 重连 · X 断开 · W 无线调试 · V 开发者选项"
                        self.addstr(y, 4, acts, curses.color_pair(C_INFO))
                        y += 1

            # 设备多到放不下时明确告知，而不是静默丢弃。
            # 聚焦模式下 shown 只有一台，不能按「总台数 - 已显示」算折叠数。
            hidden = 0 if focusing else len(links) - len(shown)
            if hidden > 0 and y < h - 7:
                self.addstr(y, 4, "…另有 %d 台设备（终端高度不足，放大窗口可显示）" % hidden,
                            curses.color_pair(C_DIM))
                y += 1

            # Mac 侧（全局）：协商速率保留 Mbps 原值 + MB/s 参考，
            # 与菜单栏「更多信息 → 网络链路」的 Mac 口径一致
            ml = st.mac_link
            if ml["rate"] and y < h - 6:
                try:
                    mac_rate = "%s Mbps（≈ %s MB/s）" % (
                        ml["rate"], link_rate_text(float(ml["rate"])))
                except ValueError:
                    mac_rate = ml["rate"]
                mac = "Mac  最高速度 %s · 信号 %s · 信道 %s" % (
                    mac_rate, ml["rssi"] or "-", ml["channel"] or "-")
                if ml["battery"]:
                    pw = {"charging": "充电中", "charged": "已充满",
                          "ac": "外接电源"}.get(ml["power"], "使用电池")
                    mac += " · 电量 %s%%（%s）" % (ml["battery"], pw)
                self.addstr(y, 2, mac, curses.color_pair(C_DIM))
                y += 1

        # mDNS 被屏蔽时给出醒目横幅
        if not st.mdns_works:
            banner = (" ⚠ 此网络屏蔽了 mDNS 广播，无法自动发现新的无线调试设备。"
                      "按 Enter 查看解决方案 ")
            attr = curses.color_pair(C_WARN) | curses.A_REVERSE | curses.A_BOLD
            self.addstr(y, 1, pad_to(banner, w - 3), attr)
            self.click_regions.append((y, 1, w - 2, lambda: self.jump_to_issue("mDNS")))
            y += 1

        self.hline(y)
        y += 1

        # ---- 诊断与解决方案 ----
        hdr = "诊断与解决方案"
        self.addstr(y, 1, hdr, curses.color_pair(C_TITLE) | curses.A_BOLD)
        tip = "↑↓ 选择   Enter 查看方案"
        self.addstr(y, 3 + dwidth(hdr), tip, curses.color_pair(C_DIM))
        if self.busy:
            self.addstr(y, 3 + dwidth(hdr) + dwidth(tip) + 3, "⟳ 诊断中…",
                        curses.color_pair(C_WARN))
        y += 1

        remaining = h - y - 3
        shown = 0
        for idx, iss in enumerate(self.issues):
            if shown >= remaining:
                break
            sel = (idx == self.selected)
            color = {"ok": C_OK, "warn": C_WARN, "error": C_ERR, "info": C_INFO}[iss.level]
            icon = {"ok": "✓", "warn": "!", "error": "✗", "info": "i"}[iss.level]
            prefix = "▶ " if sel else "  "
            line = "%s[%s] %s" % (prefix, icon, iss.title)
            attr = curses.color_pair(color) | curses.A_BOLD | curses.A_REVERSE
            # 选中行整行反白，方便鼠标识别可点击区域
            self.addstr(y, 1, pad_to(line, w - 3), attr)
            self.click_regions.append((y, 1, w - 2, lambda i=idx: self.select_and_act(i)))
            y += 1
            shown += 1

            if sel:
                indent = 4
                avail = w - indent - 2
                for dl in iss.detail.split("\n"):
                    for wl in wrap_text(dl, avail):
                        if shown >= remaining:
                            break
                        self.addstr(y, indent, wl, curses.color_pair(C_DIM))
                        y += 1
                        shown += 1
                    if shown >= remaining:
                        break
                if iss.actions and shown < remaining:
                    # 按可用宽度收纳方案摘要，放不下的用 "等 N 项" 省略，
                    # 避免超宽被硬截断成半句话
                    avail = w - indent - 2
                    parts, used = [], 4
                    for a in iss.actions:
                        piece = ("   " if parts else "") + a[0]
                        if used + dwidth(piece) > avail - 8:
                            break
                        parts.append(piece)
                        used += dwidth(piece)
                    more = len(iss.actions) - len(parts)
                    acts = "▸ " + "".join(parts)
                    if more > 0:
                        acts += "  等 %d 项" % len(iss.actions)
                    self.addstr(y, indent - 2, acts, curses.color_pair(C_INFO))
                    y += 1
                    shown += 1
        if not self.issues:
            self.addstr(y, 2, "（无诊断结果，按 R 重新诊断）", curses.color_pair(C_DIM))
            y += 1

        # ---- 底部操作栏 ----
        yb = h - 2
        self.hline(yb)
        # 状态消息（如聚焦切换反馈）画在分隔线上方，不占用菜单栏位置
        if self.status_msg and yb - 1 > y:
            self.addstr(yb - 1, 1, self.status_msg, curses.color_pair(C_INFO))
        menu = self.build_menu()
        x = 2
        for i, m in enumerate(menu):
            label = " %s " % m.label
            lw = dwidth(label)
            if x + lw >= w - 2:
                break
            attr = curses.color_pair(C_INFO) | curses.A_REVERSE
            self.addstr(yb + 1, x, label, attr)
            self.click_regions.append((yb + 1, x, x + lw, m.fn))
            x += lw + 1

        self.scr.refresh()

    def build_menu(self):
        st = self.state
        menu = []
        menu.append(Menu("a", "守护 " + ("停止" if st.daemon_running else "启动"),
                         "", self.toggle_daemon))
        if st.daemon_running:
            menu.append(Menu("S", "重新连接", "", self.force_reconnect))
        menu.append(Menu("X", "断开连接", "(聚焦的单台，未聚焦则全部)", self.disconnect_devices))
        menu.append(Menu("c", "手动连接", "", self.do_connect_dialog))
        menu.append(Menu("p", "配对设备", "", self.do_pair_dialog))
        menu.append(Menu("d", "设备列表", "", self.show_devices))
        menu.append(Menu("l", "日志", "", self.show_log))
        menu.append(Menu("?", "帮助", "", self.show_help))
        menu.append(Menu("q", "退出", "", self.quit))
        return menu

    # -------------------------- 交互 --------------------------
    def jump_to_issue(self, keyword):
        """按标题关键字跳转到对应诊断项并展开方案"""
        for i, iss in enumerate(self.issues):
            if keyword in iss.title or keyword in iss.detail:
                if iss.actions:
                    self.select_and_act(i)
                else:
                    self.selected = i
                    self.draw()
                return
        self.flash("没有找到相关诊断项")

    def select_and_act(self, idx):
        """点击某条诊断：选中并执行"""
        if idx >= len(self.issues):
            return
        self.selected = idx
        self.draw()
        self.show_actions_dialog(self.issues[idx])

    def do_selected(self):
        if not self.issues:
            return
        iss = self.issues[self.selected]
        acts = [a for a in iss.actions if a[1] is not None]
        if iss.actions:
            self.show_actions_dialog(iss)

    def show_actions_dialog(self, iss):
        """显示解决方案选择框"""
        acts = iss.actions
        if not acts:
            return
        sel = 0
        while True:
            h, w = self.scr.getmaxyx()
            bw = min(78, w - 4)
            bh = min(len(acts) + 6, h - 4)
            y0 = (h - bh) // 2
            x0 = (w - bw) // 2
            win = curses.newwin(bh, bw, y0, x0)
            win.keypad(True)
            win.box()
            win.addstr(0, 2, " 解决方案 " [:bw - 4], curses.color_pair(C_INFO) | curses.A_BOLD)
            for i, (label, _) in enumerate(acts[:bh - 5]):
                attr = curses.color_pair(C_SEL) if i == sel else 0
                pre = "▶ " if i == sel else "  "
                win.addstr(2 + i, 2, (pre + label)[:bw - 4], attr)
            win.addstr(bh - 2, 2, "↑↓ 选择  Enter 执行  Esc 返回"[:bw - 4],
                       curses.color_pair(C_DIM))
            win.refresh()
            ch = win.getch()
            if ch == 27:
                return
            elif ch in (curses.KEY_UP, ord('k')):
                sel = (sel - 1) % len(acts)
            elif ch in (curses.KEY_DOWN, ord('j')):
                sel = (sel + 1) % len(acts)
            elif ch in (10, 13, curses.KEY_ENTER):
                label, action_id = acts[sel]
                self.run_action(label, action_id)
                return

    def run_action(self, label, action_id):
        """执行动作。action_id 为字符串动作标识或可调用对象"""
        try:
            if callable(action_id):
                msg = action_id()
            elif isinstance(action_id, str):
                msg = self.dispatch_action(action_id)
            else:
                msg = None
        except Exception as e:  # noqa
            msg = "执行出错: %s" % e
        if msg:
            self.show_text("执行结果", str(msg))

    def dispatch_action(self, action_id):
        """动作分发：全部走显式 ID，不依赖按文案猜"""
        if action_id == "usb_help":
            return ("【方式 A】插 USB 自动读取端口（最可靠）\n\n"
                    "1. 用数据线把手机连到这台 Mac\n"
                    "2. 手机弹窗「是否允许 USB 调试」→ 点「允许」\n"
                    "3. 回到本界面按 R 重新诊断\n\n"
                    "原理：无线调试端口每次随机分配，通过 USB 读取手机的\n"
                    "实际监听端口，完全不受网络屏蔽影响。\n"
                    "读取成功后本工具会自动连接，并记住该端口用于断线重连。")
        if action_id == "manual_connect":
            if not self.state.has_usb:
                # 无 USB 时，提示手机上看哪里找端口
                hint = "手机：设置 → 开发者选项 → 无线调试 → 页面顶部显示 IP:端口"
            else:
                hint = "手机页面会显示，或按 R 让工具自动读取"
            ep = self.ask("手动连接", "输入 IP:端口", hint=hint)
            if not ep:
                return None
            if ":" not in ep:
                return "格式不对，应为 IP:端口，例如 192.168.1.5:37001"
            return adb_connect(ep) + "\n\n提示：连接成功后端口会被记住，掉线可自动重连。"
        if action_id == "phone_dev_settings":
            return open_android_dev_settings()
        if action_id == "phone_wireless":
            return open_android_wireless_debug()
        if action_id == "reconnect_now":
            self.refresh_async()
            return "已触发重新诊断，稍候片刻查看结果。"
        if action_id == "start_daemon":
            code, out = script("start", timeout=60)
            self.refresh_async()
            return out.strip() or "已启动守护"
        if action_id == "show_log":
            return "".join(read_log_tail(200)) or "（暂无日志）"
        if action_id == "help":
            return self.help_text()
        if action_id == "help_devopts":
            return ("【开启开发者选项】\n\n"
                    "方法一（推荐，自动）：\n"
                    "  插上 USB → 点「在手机上自动打开开发者选项页」\n"
                    "方法二（手动）：\n"
                    "  设置 → 关于手机 → 连点「版本号」7 次\n\n"
                    "开启后返回：设置 → 系统 → 开发者选项")
        if action_id == "help_wireless":
            return ("【开启无线调试】\n\n"
                    "设置 → 开发者选项 → 无线调试 → 打开\n\n"
                    "首次连接需要配对：\n"
                    "  1. 点「使用配对码配对设备」\n"
                    "  2. 本工具按 P 输入配对端口和 6 位码\n"
                    "  3. 配对成功后再按 C 输入「无线调试端口」连接\n"
                    "\n注意：配对端口 ≠ 无线调试端口，别填错。")
        return "未实现的动作: " + action_id

    def ask(self, title, prompt, default="", hint=""):
        d = InputDialog(self.scr, title, prompt, default, hint)
        self.scr.refresh()
        return d.edit()

    def toggle_daemon(self):
        if self.busy:
            return
        self.busy = True
        self.status_msg = "正在切换守护状态…"
        self.draw()
        act = "stop" if self.state.daemon_running else "start"
        code, out = script(act, timeout=60)
        self.busy = False
        self.refresh_async()
        self.flash(out.strip().split("\n")[-1][:60] if out.strip() else "完成")

    def disconnect_devices(self):
        """断开 adb 连接：聚焦时只断该台，未聚焦则断开全部。

        与 S（重连）对称。断开只是踢掉 adb 连接，手机本身不受影响；
        守护仍会按记忆端点把它连回来（提示里说明）。
        """
        if self.busy:
            return
        targets = []
        # dev_focus: 0 = 显示全部，1–N = 聚焦第 N 台（1-based）
        focus = getattr(self, "dev_focus", 0)
        if focus:
            links = self.state.dev_links
            if 0 < focus <= len(links):
                targets = [links[focus - 1]["serial"]]
        if not targets:
            targets = [d for d in self.state.wifi_devices]
        if not targets:
            self.flash("当前没有可断开的设备")
            return
        self.busy = True
        self.draw()
        ok = 0
        for ep in targets:
            if adb("disconnect", ep) is not None:
                ok += 1
        time.sleep(1)
        self.busy = False
        self.refresh_async()
        scope = "这台" if focus else "全部 %d 台" % len(targets)
        self.flash("已断开 %s（守护仍在运行，可能自动连回）" % scope)

    def force_reconnect(self):
        if self.busy:
            return
        self.busy = True
        self.draw()
        eps = self.state.wifi_devices
        for ep in eps:
            adb("disconnect", ep)
        time.sleep(1)
        msgs = []
        for ep in eps:
            msgs.append(adb_connect(ep))
        self.busy = False
        self.refresh_async()
        self.flash("已重新连接" if eps else "当前无连接")

    def do_connect_dialog(self):
        hint = "见手机：开发者选项 → 无线调试 → 显示的就是 IP:端口"
        ep = self.ask("手动连接", "输入 IP:端口", hint=hint)
        if ep:
            out = adb_connect(ep)
            self.show_text("连接结果", out + "\n\n若提示 unauthorized，请在手机上确认授权。")

    def do_pair_dialog(self):
        code_, out = script("diag", timeout=40)
        info = parse_kv(out)
        port = self.ask("配对步骤 1/2",
                        "手机「无线调试 → 使用配对码配对设备」显示的【配对端口】",
                        hint="6 位配对码也会用在下一步；端口通常是 37000-40000")
        if not port:
            return
        if ":" in port:
            host, _, p = port.rpartition(":")
        else:
            host = info.get("DEV_WIFI_IP") or info.get("MAC_IP", "")
            p = port
        pair_code = self.ask("配对步骤 2/2", "输入手机上显示的 6 位配对码", hint="例如 123456")
        if not pair_code:
            return
        self.busy = True
        self.draw()
        res = adb_pair("%s:%s" % (host, p), pair_code)
        self.busy = False
        self.refresh_async()
        self.show_text("配对结果", res + "\n\n配对成功后请按 C 输入【无线调试端口】进行连接"
                       "（注意这不是配对端口）。")

    def set_device_focus(self, n):
        """设备聚焦：0 显示全部，1–9 只看第 N 台。

        多手机场景下一屏放不下所有设备时，用它单独看某台的完整指标。
        序号与「链路质量」区的显示顺序一致（即 netinfo 的设备顺序）。
        """
        links = self.state.dev_links
        if n == 0:
            self.dev_focus = 0
            self.status_msg = "显示全部设备"
        elif 1 <= n <= len(links):
            self.dev_focus = n
            d = links[n - 1]
            name = d["model"] or d["serial"]
            self.status_msg = "只看 %s（按 0 显示全部）" % name
        else:
            # 超过实际设备数时给出明确反馈，而不是静默忽略
            self.status_msg = "没有第 %d 台设备（当前共 %d 台）" % (n, len(links))
            return
        self.scroll = 0

    def show_devices(self):
        code, out = adb("devices", "-l")
        self.show_text("adb devices -l", out)

    def refresh_link_quality(self, serial=None):
        """刷新链路质量：跳过 60 秒缓存立即采集。

        与菜单栏一致——链路质量是「与这台设备通信」的质量，所以支持按设备刷新：
        传 serial 只刷这一台（其余设备缓存原样保留），不传则刷新全部。
        """
        who = "全部设备" if not serial else (serial or "")
        self.status_msg = "正在刷新链路质量（%s）…" % who
        self.busy = True
        try:
            self.scr.erase()
            self.scr.refresh()
            args = ["netinfo-refresh"]
            if serial:
                args.append(serial)
            # 不带 kv：脚本返回中文文案，直接看是否带成功标记
            code, out = script(*args, timeout=60)
            ok = code == 0 and ("链路质量已刷新" in (out or ""))
            self.status_msg = ("已刷新 %s 的链路质量" % who) if ok else (
                "刷新失败（%s 可能无响应）" % who)
        except Exception:
            self.status_msg = "刷新失败"
        finally:
            self.busy = False
        self.refresh_async()

    def open_settings_focused(self, page):
        """W / V 键：聚焦某台时只对这台跳转设置页，否则交给脚本自动挑一台。"""
        links = self.state.dev_links
        serial = None
        if self.dev_focus and 1 <= self.dev_focus <= len(links):
            serial = links[self.dev_focus - 1]["serial"]
        if page == "wireless":
            self.show_text("在手机上打开无线调试", open_android_wireless_debug(serial))
        else:
            self.show_text("在手机上打开开发者选项", open_android_dev_settings(serial))

    def refresh_focused_or_all(self):
        """F 键：聚焦某台时只刷这台，否则刷新全部。
        与菜单栏「每台设备各自带刷新入口」是同一语义。"""
        links = self.state.dev_links
        if self.dev_focus and 1 <= self.dev_focus <= len(links):
            self.refresh_link_quality(links[self.dev_focus - 1]["serial"])
        else:
            self.refresh_link_quality()

    def reconnect_focused_or_all(self):
        """S 键：聚焦某台时只重连这台，否则逐台重连全部。
        对应菜单栏的「重连这台设备」与「全部设备 → 逐台重连」。"""
        links = self.state.dev_links
        if self.dev_focus and 1 <= self.dev_focus <= len(links):
            serial = links[self.dev_focus - 1]["serial"]
            self.status_msg = "正在重连 %s…" % serial
            self.busy = True
            try:
                # 不带 kv：脚本 text 模式输出以 ✓ / ✗ 开头，据此判定
                code, out = script("recover", "--serial", serial, timeout=90)
                ok = code == 0 and ("✓" in (out or ""))
                self.status_msg = ("已重连 %s" % serial) if ok else (
                    "重连失败：%s 可能不在线" % serial)
            except Exception:
                self.status_msg = "重连失败"
            finally:
                self.busy = False
            self.refresh_async()
        else:
            self.force_reconnect()

    def show_log(self):
        lines = read_log_tail(300)
        self.show_text("守护日志（最近 300 行）", "".join(lines) or "（暂无日志）")

    def show_help(self):
        self.show_text("使用帮助", self.help_text())

    def help_text(self):
        return """ADB 无线调试管理器 —— 使用说明
══════════════════════════════════════════════════════

【这是什么】
  让这台 Mac 通过 Wi-Fi 调试 Android 手机，掉线自动重连。
  不需要记住任何命令，界面上点选即可完成所有操作。

【第一步：手机端准备】
  1. 设置 → 关于手机 → 连点「版本号」7 次
  2. 设置 → 开发者选项 → 无线调试 → 打开
  3. 记下页面上显示的「IP:端口」

【第二步：连接】
  本工具提供三种自动发现方式，任一可用即可：

  ① mDNS 广播   —— 标准方式。手机打开无线调试后自动广播。
                    ⚠ 很多公司 Wi-Fi 会屏蔽组播
  ② USB 读取    —— 插上 USB 线，工具直接读取手机真实端口。
                    ★ 最可靠，企业网络下推荐
  ③ 记忆端点    —— 记录连通过的地址，掉线后自动重试。

【⚠ 关于「网络无法自动发现」】
  如果你的公司 Wi-Fi 屏蔽了组播（很常见），表现为：
      mDNS: 被屏蔽 ✗   且长时间发现不到设备
  这不是配置错误，而是网络策略限制。解决方案：

  A. 【推荐】插上了 USB 线 → 工具自动读取端口，无需任何手动输入
  B. 换到手机热点 或 家里 Wi-Fi 测试（通常不屏蔽）
  C. 在手机无线调试页面，把 IP:端口 用「手动连接」输入一次，
     工具会记下来，之后端口不变就能自动重连
  D. 找网管关闭 Wi-Fi 的「客户端隔离 / 组播隔离」（企业环境通常较难）

【常用按键】
  ↑ ↓      在诊断项之间移动
  Enter    执行当前诊断项给出的解决方案
  A        启动 / 停止后台守护（开机自启）
  C        手动输入 IP:端口 连接
  P        配对设备（Android 11+ 首次连接需要）
  D        查看设备列表
  1-9      只看第 N 台设备的链路指标（多手机时用）
  0        取消聚焦，显示全部设备
  F        刷新链路质量（聚焦时只刷该台，否则全部）
  S        重连（聚焦时只重连该台，否则逐台重连）
  W        在手机上打开「无线调试」（聚焦时只作用于该台）
  V        在手机上打开「开发者选项」（聚焦时只作用于该台）
  L        查看守护日志
  R        重新诊断
  Q        退出界面（守护进程继续在后台工作）

【常见问题】
  · 显示 unauthorized
      手机弹窗「允许 USB 调试」需点允许；否则删除 ~/.android/adbkey*
      后重启 adb 再连。
  · 手机重启后连不上
      无线调试端口会变化。插 USB 让工具自动读取，或用 C 手动输入新端口。
  · 界面乱码
      确保终端支持 UTF-8；或改用 ./adbwifi --cli 纯文本模式。
"""

    def show_text(self, title, text):
        self.detail_view = text
        self.detail_title = title
        self.scroll = 0
        scroll_viewer(self.scr, title, text)

    def flash(self, msg):
        self.status_msg = msg
        self.draw()

    def quit(self):
        self.running = False


def scroll_viewer(stdscr, title, text, width=None):
    """可滚动文本框（键盘 + 滚轮）"""
    maxh, maxw = stdscr.getmaxyx()
    wrapw = max(20, maxw - 3)
    lines = []
    for ln in text.split("\n"):
        if not ln:
            lines.append("")
        else:
            lines.extend(wrap_text(ln, wrapw))

    top = 0
    while True:
        stdscr.erase()
        h, w = stdscr.getmaxyx()
        stdscr.addstr(0, 0, (" " + title + " ")[:w - 1],
                      curses.color_pair(C_HEADER) | curses.A_BOLD)
        body_h = h - 3
        for i in range(body_h):
            idx = top + i
            if idx >= len(lines):
                break
            try:
                stdscr.addstr(1 + i, 1, lines[idx][:w - 2])
            except curses.error:
                pass
        stdscr.addstr(h - 2, 0, "─" * (w - 1), curses.color_pair(C_BORDER))
        hint = " ↑↓/PgUp/PgDn 滚动   q/Esc/Enter 返回 "
        stdscr.addstr(h - 1, 0, hint[:w - 1], curses.color_pair(C_DIM))
        # 右侧滚动位置指示（不覆盖标题）
        if len(lines) > body_h:
            total = max(len(lines) - body_h, 1)
            frac = top / total
            row = 1 + int(frac * (body_h - 1))
            try:
                stdscr.addstr(row, w - 2, "▓", curses.color_pair(C_INFO))
            except curses.error:
                pass
        stdscr.refresh()

        ch = stdscr.getch()
        if ch in (ord('q'), 27, 10, 13, curses.KEY_ENTER):
            return
        elif ch in (curses.KEY_UP, ord('k')):
            top = max(0, top - 1)
        elif ch in (curses.KEY_DOWN, ord('j')):
            top = min(max(0, len(lines) - body_h), top + 1)
        elif ch == curses.KEY_PPAGE:
            top = max(0, top - body_h)
        elif ch == curses.KEY_NPAGE:
            top = min(max(0, len(lines) - body_h), top + body_h)
        elif ch == curses.KEY_HOME:
            top = 0
        elif ch == curses.KEY_END:
            top = max(0, len(lines) - body_h)
        elif ch == curses.KEY_MOUSE:
            try:
                _, mx, my, _, bstate = curses.getmouse()
                if bstate & MOUSE_WHEEL_UP:
                    top = max(0, top - 3)
                elif bstate & MOUSE_WHEEL_DOWN:
                    top = min(max(0, len(lines) - body_h), top + 3)
            except curses.error:
                pass


# ============================== 主循环 ==============================

def main_loop(stdscr):
    curses.curs_set(0)
    stdscr.keypad(True)
    try:
        # 注意：不启用 REPORT_MOUSE_POSITION。
        # 在某些 ncurses 上「滚轮向下」与 REPORT_MOUSE_POSITION 使用同一位(0x8000000)，
        # 若同时监听鼠标移动，会导致移动被误判成滚轮滚动。
        curses.mousemask(curses.ALL_MOUSE_EVENTS)
        curses.mouseinterval(0)
        print("\033[?1000h", end="", flush=True)
    except Exception:
        pass

    app = App(stdscr)
    app.init_colors()

    # 首次诊断放到后台，界面立刻可用
    t = threading.Thread(target=app.refresh_state, daemon=True)
    t.start()

    last_draw = 0
    last_event_check = 0
    while app.running:
        now = time.time()

        # 实时感知：设备接入/断开/插拔等事件发生后立即重新诊断
        # 只 stat 事件日志文件（几乎零成本），不轮询 adb
        if not app.busy and now - last_event_check > 0.4:
            last_event_check = now
            if event_seq() != app.last_event_seq:
                last_draw = 0          # 强制重绘
                app.refresh_async()

        if now - last_draw > 0.5:
            app.draw()
            last_draw = now

        stdscr.nodelay(True)
        try:
            ch = stdscr.getch()
        except curses.error:
            ch = -1
        if ch == -1:
            time.sleep(0.05)
            continue

        # ---- 鼠标 ----
        if ch == curses.KEY_MOUSE:
            try:
                _, mx, my, _, bstate = curses.getmouse()
            except curses.error:
                continue
            if bstate & MOUSE_WHEEL_UP:
                app.selected = max(0, app.selected - 1)
            elif bstate & MOUSE_WHEEL_DOWN:
                if app.issues:
                    app.selected = min(len(app.issues) - 1, app.selected + 1)
            elif bstate & MOUSE_LEFT:
                hit = None
                for (ry, rx1, rx2, cb) in app.click_regions:
                    if ry == my and rx1 <= mx < rx2:
                        hit = cb
                        break
                if hit:
                    hit()
                else:
                    # 点空白处：仅移动选中项，不弹窗（避免误触）
                    if app.issues:
                        app.selected = min(app.selected, len(app.issues) - 1)
            last_draw = 0
            continue

        # ---- 键盘 ----
        if ch in (ord('q'), ord('Q')):
            if ch == ord('q'):
                app.quit()
            else:
                app.show_help()
        elif ch in (curses.KEY_UP, ord('k')):
            app.selected = max(0, app.selected - 1)
        elif ch in (curses.KEY_DOWN, ord('j')):
            if app.issues:
                app.selected = min(len(app.issues) - 1, app.selected + 1)
        elif ch in (10, 13, curses.KEY_ENTER):
            app.do_selected()
        elif ch in (ord('r'), ord('R')):
            app.refresh_async()
        elif ch in (ord('a'), ord('A')):
            app.toggle_daemon()
        elif ch in (ord('s'), ord('S')):
            app.reconnect_focused_or_all()
        elif ch in (ord('c'), ord('C')):
            app.do_connect_dialog()
        elif ch in (ord('p'), ord('P')):
            app.do_pair_dialog()
        elif ch in (ord('d'), ord('D')):
            app.show_devices()
        elif ord('0') <= ch <= ord('9'):
            # 0 = 显示全部设备；1-9 = 只看第 N 台（超出范围则忽略）
            app.set_device_focus(ch - ord('0'))
            last_draw = 0              # 立即重绘，否则要等下一次定时刷新才生效
        elif ch in (ord('l'), ord('L')):
            app.show_log()
        elif ch in (ord('f'), ord('F')):
            app.refresh_focused_or_all()
        elif ch in (ord('w'), ord('W')):
            app.open_settings_focused("wireless")
        elif ch in (ord('v'), ord('V')):
            app.open_settings_focused("dev")
        elif ch == ord('?'):
            app.show_help()
        last_draw = 0


def cli_fallback():
    """TERM=dumb 或不支持 curses 时的纯文本模式"""
    print("ADB 无线调试管理器（纯文本模式）\n")
    st = collect_state()
    issues = diagnose(st)
    print("守护进程:", "运行中" if st.daemon_running else "已停止")
    print("无线设备:", ", ".join(st.wifi_devices) or "无")
    _ms = st.mdns_state
    print("mDNS:", {"ok": "可用", "stalled": "曾卡死已恢复",
                    "flaky": "无响应重试中", "blocked": "被屏蔽"}.get(_ms, "未知"))
    # 纯 Wi-Fi 质量（Mac ↔ AP）
    wq = st.wifi_quality
    if wq and wq["theo"]:
        try:
            _t = float(wq["theo"]); _n = float(wq["rate_now"])
            _u = float(wq["rate_usable"]); _r = int(float(wq["rate_ratio"]))
            _lb = "接近满速" if _r >= 80 else ("部分降级" if _r >= 50 else "严重降级")
            _s = 3 if _r >= 80 else (2 if _r >= 50 else 1)
            print("带宽: %s 理论 %.0f MB/s · 当前协商 %.1f · 实际可用 %.0f MB/s（达成率 %d%% %s）" % (
                meter(_s, 3), _t / 8, _n / 8, _u / 8, _r, _lb))
        except ValueError:
            pass
    if wq and wq["snr"]:
        try:
            _snr = float(wq["snr"])
            _ss, _sl = snr_grade(_snr)
            print("Wi-Fi: %s %s · 信噪比 %.0f dB %s %s" % (
                wq["phy"] or "", ("%s MHz" % wq["bw"]) if wq["bw"] else "",
                _snr, meter(_ss, 5), _sl))
            if wq["rtt"]:
                _r = float(wq["rtt"])
                _rs, _rl = wifi_rtt_grade(_r)
                _extra = ""
                if wq["jitter"]:
                    _extra = " · 抖动 %s ms %s" % (
                        wq["jitter"], jitter_grade(float(wq["jitter"])))
                print("      延迟 %.1f ms %s %s%s" % (_r, meter(_rs, 3), _rl, _extra))
        except ValueError:
            pass
    # 信道拥塞：信号好但延迟抖动大时，最常见的根因
    cc = st.channel_crowd
    if cc:
        _lbl = {"low": "空闲", "medium": "一般", "high": "拥挤"}.get(cc["crowd"], "?")
        print("信道: %s  拥挤度: %d 个 AP（%s）" % (
            cc["channel"] or "-", cc["aps"], _lbl))
        if cc["crowd"] == "high":
            _st = cc["strongest"].replace("|", " ")
            _bs = cc["best"].replace("|", "（空闲 ")
            print("      最强干扰 %s dBm · 建议换到信道 %s 个 AP）" % (_st, _bs)
                  if _st else "      建议换到更空闲的信道")
    # 链路质量摘要：与交互界面同一份数据、同一套评级，纯文本下给一行精简版
    links = st.dev_links
    if links:
        avg, peak = st.rate_stats
        print()
        print("网络速度:")
        for d in links:
            head = "  " + d["serial"] + ((" · " + d["model"]) if d["model"] else "")
            if d["transport"] != "wifi":
                head += " · USB"
            else:
                _tag = same_ap_tag(d, st.mac_link)
                if _tag:
                    head += " · " + _tag
            if d["battery"]:
                head += "  电量 %s%%%s" % (
                    d["battery"], "（充电中）" if d["charging"] == "1" else "")
            print(head)
            if d["transport"] != "wifi":
                print("    USB 直连（不经过 Wi-Fi）")
                continue
            segs = []
            try:
                if d["rtt"]:
                    v = float(d["rtt"])
                    _, lbl, mtr = rtt_level(v)
                    segs.append("延迟 %.1f ms %s %s" % (v, mtr, lbl))
            except ValueError:
                pass
            try:
                if d["rssi"]:
                    _, lbl, mtr = signal_level(float(d["rssi"]))
                    segs.append("信号 %s dBm %s %s" % (d["rssi"], mtr, lbl))
            except ValueError:
                pass
            if segs:
                print("    " + " · ".join(segs))
            if d["link"]:
                try:
                    ceil = float(d["link"]) * 0.6
                    ceil_txt = link_rate_text(ceil)
                except ValueError:
                    ceil, ceil_txt = 0, "-"
                try:
                    avg_v = float(avg or 0)
                except ValueError:
                    avg_v = 0.0
                try:
                    peak_v = float(peak or 0)
                except ValueError:
                    peak_v = 0.0
                if avg_v <= 0 and peak_v <= 0:
                    print("    速度 上限 %s MB/s · 暂无传输（≥30%% / 10-30%% / <10%% 分档）"
                          % ceil_txt)
                else:
                    avg_txt = "<0.1" if avg_v < 0.8 else link_rate_text(avg_v)
                    usage_v, grade = throughput_grade(peak_v, ceil)
                    print("    速度 上限 %s MB/s · 平均 %s MB/s · 最大 %s MB/s（%s %.0f%%）" % (
                        ceil_txt, avg_txt, link_rate_text(peak_v),
                        grade or "-", usage_v or 0))
            if d["ssid"]:
                bssid_short = "-"
                if d.get("bssid"):
                    bparts = d["bssid"].split(":")
                    bssid_short = ("…" + ":".join(bparts[-2:])
                                   if len(bparts) >= 2 else d["bssid"])
                print("    AP %s · 信道 %s · %s MHz · BSSID %s" % (
                    d["ssid"], d["channel"] or "-", d["freq"] or "-", bssid_short))

    print()
    for iss in issues:
        icon = {"ok": "✓", "warn": "!", "error": "✗", "info": "i"}[iss.level]
        print("[%s] %s" % (icon, iss.title))
        for dl in iss.detail.split("\n"):
            print("    " + dl)
        if iss.actions:
            print("    可选操作:")
            for lb, _ in iss.actions:
                print("      - " + lb)
        print()
    print("提示：请在支持 curses 的终端中运行 ./adbwifi 以获得完整交互界面。")


def main():
    if not os.path.exists(SCRIPT):
        print("找不到守护脚本: %s" % SCRIPT, file=sys.stderr)
        return 2
    if "--cli" in sys.argv or not sys.stdout.isatty():
        cli_fallback()
        return 0

    def on_term(sig, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, on_term)

    try:
        curses.wrapper(main_loop)
    except KeyboardInterrupt:
        pass
    finally:
        try:
            print("\033[?1000l", end="", flush=True)
        except Exception:
            pass
    print("已退出（守护进程仍在后台运行；如需停止请运行 ./adbwifi 后按 A）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
