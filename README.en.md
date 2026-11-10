# adb-wifi-manager

> An **automatic wireless ADB connection daemon** for Android devices on macOS — making
> "plug in USB once, then stay wireless forever" a reality.
>
> [中文文档](README.md) · [Performance Goals](#performance-goals--technical-design) · [Technical Design](#performance-goals--technical-design)

---

## The Problem This Project Solves

Wireless debugging is essential for Android development, but Android 11+ introduced
several **inherent pitfalls** that force developers to waste time re-connecting the
device every single day.

### Pitfall 1: Random ports — every connection is one-shot

Android 11+ assigns a **random port** every time wireless debugging is enabled
(e.g. `192.168.1.5:38845`). Restart the phone, switch networks, or even just toggle
the switch off and on — and the port changes. The address cached by `adb connect`
becomes invalid instantly.

**Every single time you must: unlock the phone → open Settings → navigate to
Wireless debugging → copy the IP and port → connect manually.**

### Pitfall 2: The wireless debugging switch cannot be toggled by command

Intuitively you should be able to run `adb shell settings put global adb_wifi_enabled 1`,
but Android requires the `WRITE_SECURE_SETTINGS` permission, which a regular adb shell
does not have. The attempt fails outright:

```
java.lang.SecurityException: Permission denial: writing to settings requires:
android.permission.WRITE_SECURE_SETTINGS
```

This is a deliberate OS security boundary and **cannot be bypassed**. So
"automation" breaks down at step one.

### Pitfall 3: Corporate networks block mDNS

Android 11+ officially relies on mDNS (`_adb-tls-connect._tcp`) service advertisement.
But **many corporate Wi-Fi networks and routers block multicast**, so
`adb mdns services` returns nothing and the standard discovery flow is unusable.

### Pitfall 4: No automatic recovery after disconnection

Even once connected, Wi-Fi fluctuations, laptop sleep/wake, or the phone screen
turning off will drop the connection. Reconnecting depends on remembering the previous
address — and once that address is stale, the device is **unreachable until you
plug in USB and start over**.

---

### How This Project Solves It

| Pitfall | Solution |
|---|---|
| Random ports, one-shot connections | Switch to `adb tcpip 5555` — **fixed port**, configured once and usable long-term |
| Switch cannot be toggled by command | On USB plug-in, run `adb tcpip` automatically — **no special permission needed** |
| mDNS blocked | Five concurrent discovery paths: mDNS, USB inspection, endpoint memory, tcpip probe, **subnet scan** |
| No recovery after disconnect | **Persistent memory + subnet scanning** — recover the phone even after an IP change, without USB |

**The result**: plug in USB once. After that, phone reboots, IP changes, drops, and
Mac sleep/wake are all recovered **automatically — without ever touching the phone's
settings screen**.

> The only scenario still requiring USB: after the phone **reboots** (tcpip mode is
> lost). Plug in once and it recovers. Everything else is fully automatic.

---

## Quick Start

One-line install / update (downloads the latest stable release and sets up launchd plus
the menu bar app):

```bash
curl -fsSL https://raw.githubusercontent.com/DuRunzhe/adb-wifi-manager/main/get.sh | bash
```

Optional environment variables:

| Variable | Description |
|---|---|
| `ADBWIFI_VERSION=0.0.3` | Pin a version; Alpha tags work too (e.g. `0.0.2-alpha.1`) |
| `ADBWIFI_DIR=~/mycode/adb-wifi-manager` | Install directory (the default) |
| `ADBWIFI_SKIP_INSTALL=1` | Download and deploy only; skip launchd and the app |

Install a specific version:

```bash
curl -fsSL https://raw.githubusercontent.com/DuRunzhe/adb-wifi-manager/main/get.sh \
  | ADBWIFI_VERSION=0.0.2-alpha.1 bash
```

> Downloads are verified against SHA256. An existing directory is overwritten by the
> release (keeping `config.sh`). If you manage the source with git, prefer
> `git pull && ./install.sh` to avoid overwriting your working tree.

After installation:

```bash
cd ~/mycode/adb-wifi-manager
./adbwifi                 # ★ Launch the TUI (recommended, no arguments)
```

- The daemon is managed by **launchd** — starts on login, restarts on crash
- The menu bar app is installed to `~/Applications/AdbWifiBar.app` (double-click in
  Finder, or add it to Login Items)

Alternatively, grab `adb-wifi-manager-<version>.zip` from
[Releases](https://github.com/DuRunzhe/adb-wifi-manager/releases), unzip it, and run
`./install.sh` (the prebuilt app is included, no Xcode required); or run `./install.sh`
inside a cloned repository.

---

## Performance Goals & Technical Design

This tool is a **24/7 background daemon**, so performance is a hard requirement rather
than a nice-to-have: it must react instantly to disconnections while staying invisible
to the system when everything is stable.

### Performance Goals

| Goal | Target | Status |
|---|---|---|
| **Responsiveness** | Disconnect → reconnected within 2 s | ✅ **0.9–1.5 s** measured |
| **Idle overhead** | Negligible load when connected | ✅ USB probing skipped; **0.87** concurrent adb processes on average |
| **Diagnostic latency** | `diag` response (called on every menu open) | ✅ **0.2–0.4 s** (worst case was 16 s before optimization) |
| **Scan efficiency** | Full /24 subnet scan | ✅ **0.9 s** (was 7.3 s) |
| **Memory footprint** | Resident memory | ✅ bash process, a few MB |
| **Dependency footprint** | No runtime deps beyond adb | ✅ Pure bash + system tools |

### Core Design Principle

> **Do less when stable; spend only when necessary.**

Most of the time the phone is connected, and every probe during that period is wasted
work. All probing logic short-circuits on "is a usable connection already present?"

### Technical Design

#### 1. Event-driven, not polling

Instead of a fixed `while sleep 10` loop, the daemon subscribes to the
`adb track-devices` event stream:

```
adb track-devices  →  events.log  →  main loop wakes immediately
                                  →  TUI detects file change and redraws
                                  →  menu bar DispatchSource refreshes the icon
```

Events are written to `state/events.log` and consumed by all three readers from the
**same data source** — so the TUI and the menu bar can never disagree (no more
"terminal says connected, menu bar says disconnected").

The trade-off is a lightweight event check during waits. After optimization only a
single `sleep` subprocess remains:

```bash
# Before: fork sleep + stat every 0.25 s (80 subprocesses per 10 s of waiting)
sleep 0.25
now=$(stat -f%m "$evf")

# After: builtin time check, builtin -nt comparison (only sleep remains)
sleep 0.3
if [ "$evf" -nt "$mark" ]; then ...
```

#### 2. Five concurrent discovery paths

No single discovery method is reliable in real networks, so five are prepared:

| Step | Method | Mechanism | Trigger |
|---|---|---|---|
| ① | mDNS | `adb mdns services` reading `_adb-tls-connect._tcp` | Standard; fails when the network blocks multicast |
| ② | USB inspection | Read LISTEN ports from `/proc/net/tcp` on the device | With USB attached — 100% accurate |
| ③ | Endpoint memory | Remember previously successful `IP:PORT` | Primary reconnect mechanism |
| ④ | tcpip probe | Check whether the device listens on the fixed port | With USB attached |
| ⑤ | Subnet scan | Probe the local /24 concurrently | When the first four all fail; throttled to every 5 min |

#### 3. Bypassing the permission wall with `adb tcpip`

This is the key insight of the whole design. Since the wireless debugging switch
cannot be enabled, **take a different path that does not need that permission**:

```bash
# Requires WRITE_SECURE_SETTINGS — not possible
adb shell settings put global adb_wifi_enabled 1

# Requires no special permission — works
adb tcpip 5555
```

`adb tcpip` makes adbd listen on an additional TCP port **in parallel with the USB
channel**. Critically, it **only needs to run once** — afterwards adbd keeps listening
on 5555 regardless of whether USB is attached.

```
Plug in USB → adb tcpip 5555 → read phone's Wi-Fi IP → adb connect IP:5555
                                                        ↓
                                          Unplug USB — connection survives
```

#### 4. Fixing the "endpoint memory expires too early" defect

Early versions frequently failed to reconnect after a drop. The root cause was a
seemingly reasonable cleanup rule:

```bash
# Flawed: delete as soon as the port is unreachable
if nc -z "$ip" "$port"; then echo "$ep"; else stale+=("$ep"); fi
```

Brief dropouts, screen-off, or a subnet change would all trigger deletion — erasing
the "way home". Now:

```bash
# Only count failures; purge after 360 consecutive failures (~1 hour)
echo "$ep $((fails + 1))" >> known_fails.txt
```

Combined with subnet scanning, even a changed IP is rediscovered and the memory is
updated automatically.

#### 5. The five key performance optimizations

| Item | Before | After | Technique |
|---|---|---|---|
| Subnet scan | 254 `nc` processes, 7.3 s | **1 process, 0.9 s** | Single-process non-blocking concurrent connects (perl) |
| `diag` | up to 16 s | **0.2–0.4 s** | Merged duplicate mDNS queries into one collection |
| USB probing | 3–4 `adb shell` calls per round | **Skipped** when connected | Early short-circuit |
| Event wait | fork `sleep`+`stat` each round | Only `sleep` | Builtin `SECONDS` / `-nt` |
| Menu bar polling | Fixed 2 s | 5 s (configurable) | Event-driven; no need for high frequency |

**The `diag` optimization delivers the biggest win**: the original implementation ran
`adb mdns services` twice (`discover_mdns` once plus a count query), each taking up to
8 s. Since the menu bar calls `diag` every time the menu opens, every menu click wasted
over ten seconds — now merged into a single collection.

#### 6. Multi-ROM compatible settings navigation

Settings layouts vary widely across OEM ROMs. The approach is
"try in order, then verify the result":

```
① SubSettings + WirelessDebuggingFragment   ← AOSP standard; verified on MIUI
② Settings$WirelessDebuggingActivity        ← some ROMs
③ APPLICATION_DEVELOPMENT_SETTINGS          ← fallback
```

Verification is essential: on some ROMs (e.g. MIUI) `WirelessDebuggingActivity` is an
empty shell that silently redirects to the Settings home screen. Checking only whether
`am start` reports an error would falsely report success, so the code runs
`uiautomator dump` and reads the UI text to confirm the page actually shows.

#### 7. Compatibility with macOS's bundled bash 3.2

macOS ships `/bin/bash` 3.2, which introduces two traps:

- `case` inside `$(...)` is a syntax error → replaced with `if`
- `;&` (case fallthrough) requires bash 4+ → avoided entirely
- `EPOCHSECONDS`, associative arrays, etc. are unavailable → use `SECONDS` and other 3.2-safe constructs

This guarantees it **works out of the box — no `brew install bash` required**.

### Tech Stack

| Component | Choice | Rationale |
|---|---|---|
| Daemon | Pure bash | Zero runtime dependencies; works on any Mac |
| Terminal UI | Python 3 + curses | Bundled with macOS; broad terminal compatibility |
| Menu bar app | Swift + AppKit | Native; no Xcode project files needed |
| Process management | launchd | Native; start on login + restart on crash |
| Icon generation | Swift + SF Symbols | Matches system style; adapts to light/dark automatically |

Approximately **3,300 lines** in total
(daemon 1,134 / TUI 1,292 / menu bar 767 / icon generator 115).

---

## Terminal UI (TUI)

```bash
./adbwifi
```

Launching it shows the complete status and diagnosis; **every action is available via
mouse click or keyboard**:

```
 ADB Wireless Debug Manager   ● daemon running (auto-start)   Q quit  R refresh  ? help
```

### Key Bindings

| Key | Action |
|---|---|
| `↑` `↓` / `j` `k` | Move selection |
| `Enter` / click | Trigger the highlighted action |
| `R` | Re-diagnose immediately |
| `Q` | Quit (the daemon keeps running) |
| `?` | Help |

### Requirements

- macOS (tested on macOS 14/15, Apple Silicon)
- `adb` (Homebrew `android-platform-tools` or the Android SDK)
- Python 3 (bundled with macOS)
- Swift toolchain (only needed to build the menu bar app)

---

## ⚠ When the Network Blocks Automatic Discovery

Some corporate networks (e.g. office Wi-Fi) block mDNS multicast, so mDNS alone
finds nothing. The script already falls back to USB inspection and endpoint memory.
If the phone has **never** been connected via USB, connect manually once:

```bash
adb connect <phone-ip>:<port-shown-on-wireless-debugging-screen>
```

After that the endpoint is remembered and automatic reconnection takes over.

---

## Commands

| Command | Description |
|---|---|
| `./bin/adb-wifi.sh start` | Start the daemon (idempotent) |
| `./bin/adb-wifi.sh stop` | Stop the daemon and disable launchd auto-start |
| `./bin/adb-wifi.sh restart` | Restart |
| `./bin/adb-wifi.sh status` | Show status, connected devices, recent logs |
| `./bin/adb-wifi.sh log` | Follow the log in real time (Ctrl-C to exit) |
| `./bin/adb-wifi.sh once` | Run one discovery round in the foreground (for troubleshooting) |
| `./bin/adb-wifi.sh open` | Open the **Wireless debugging** page on the phone |
| `./bin/adb-wifi.sh open dev` | Open the **Developer options** page on the phone |
| `./bin/adb-wifi.sh recover` | Actively restore the wireless connection (**no USB needed**) |
| `./bin/adb-wifi.sh rate [secs]` | Show current adb transfer rate (default 1 s sample) |

Log location: `~/Library/Application Support/adb-wifi-manager/logs/adb-wifi.log`

---

## Discovery Mechanism

Android 11+ assigns a **random port** for wireless debugging, so the script combines
several complementary methods — any one of them succeeding is enough:

| Method | Description | Reliability |
|---|---|---|
| **mDNS** | `adb mdns services` reads `_adb-tls-connect._tcp` advertisements | Standard, but **many corporate Wi-Fi / APs block multicast** |
| **USB inspection** | With USB attached, read adbd's actual listening port | Most reliable — 100% accurate |
| **Endpoint memory** | Remember successful `IP:PORT` and retry after drops | Primary reconnect mechanism |

### Real-time event awareness

Device changes are **not detected by polling** but driven by the `adb track-devices`
event stream, with sub-second response:

| Change | Detection | Measured response |
|---|---|---|
| Wireless disconnect | `track-devices` pushes `offline` | **Reconnect in 0.9–1.5 s** |
| Device back online / new device | `track-devices` pushes `device` | Immediate |
| USB plugged in | Event + read the real port | Immediate; switches to the USB-discovered port |
| USB unplugged | Event push | Immediate |
| Mac network change | Subnet comparison | Restart adb immediately |

Implementation notes:

- A resident `adb track-devices` process writes events to `state/events.log`
- The main loop's wait is **interruptible by events** — it re-diagnoses immediately instead of waiting out the interval
- The TUI only `stat`s the event file (virtually free) and re-diagnoses on change
- The menu bar app uses `DispatchSource` on the same file; the timer is only a fallback

### Scenarios covered by automatic recovery

- ✅ Wireless drop → reconnect triggered instantly (measured **0.9–1.5 s**, vs. ~10 s with old polling)
- ✅ `adb server` crash → restarted and reconnected automatically
- ✅ Mac switches Wi-Fi / subnet changes → adb server restarted, stale endpoints cleaned
- ✅ Port change after device reboot → new port read automatically when USB is attached
- ✅ Stale endpoints → preserved with failure counting, purged only after prolonged failure

---

## Menu Bar App

Installed at `~/Applications/AdbWifiBar.app` (build output at `build/AdbWifiBar.app`).

| State | Icon |
|---|---|
| Daemon stopped | Phone with slash |
| Running, no device | Phone |
| Device connected | Phone + signal |

> The icon appears on the **left side** of the menu bar; reorder it with `⌘` + drag.
> If an SF Symbol is unavailable on the current macOS, it degrades gracefully and
> finally falls back to the text `ADB`.

### Icons

The menu bar icon and the app icon **use the same SF Symbol**
(`iphone.radiowaves.left.and.right`), each rendered by the most appropriate path:

| Location | Implementation | Notes |
|---|---|---|
| Menu bar | Rendered directly from the system SF Symbol (`setIcon`) | The system draws it at standard size and adapts to light/dark |
| App icon | `.icns` generated by `menubar/gen-icon.swift` | Dark slate rounded square with a white glyph; recognizable in Finder/Launchpad/`⌘Tab` |

Generated automatically at build time:

| File | Purpose |
|---|---|
| `Resources/icon_1024.png` | 1024px master image (app icon source) |
| `Resources/AdbWifiBar.icns` | Multi-resolution `.icns` (`CFBundleIconFile` in `Info.plist`) |

To change the icon, edit the symbol in `gen-icon.swift` (app icon) and the `updateIcon`
candidates in `main.swift` (menu bar), then rebuild.

> An early version tried loading the same PNG for the menu bar, but PNG scaling made the
> glyph visibly smaller (measured 42×28 → 30×20 px), so the menu bar reverted to system
> symbol rendering.

Since `LSUIElement` is `true` (menu-bar-only, no Dock icon), the app icon mainly
appears in Finder, Launchpad, `⌘Tab`, and system dialogs.

### Menu Contents

Opening the menu **re-samples the state in real time** (~0.2 s), using the **same `diag`
data source** as the TUI, so both always agree:

```
● Daemon running (auto-start)
  ✓ 192.168.1.50:5555
──
  [✓] Device connected (wireless port 5555)
        USB unplugged; wireless connection holds independently
──
  mDNS: blocked
  USB: not connected
  TCP mode: enabled (port 5555)
  Discovery: endpoint memory
  Host: 192.168.1.100
  Phone: Pixel 7
──
  Stop daemon
  Restore wireless connection (no USB needed)     ⌘R
  Open "Wireless debugging" on phone…             ⌘W
  Open adb devices
  View log…
  About ADB WiFi
  Quit menu bar (daemon keeps running)
```

Diagnosis is produced centrally by `DIAG_LEVEL / DIAG_CODE / DIAG_TITLE / DIAG_HINT / DIAG_ACTION`
in the script, so the menu bar and TUI never diverge. `DIAG_CODE` is a machine-readable
enum that the menu bar maps to localized strings (see the next section).

### Script Output Protocol (the app ⇄ script contract)

The menu bar app **never parses natural language** from the script. By default the script
prints Chinese text for the terminal and TUI; in `kv` mode it prints ASCII enum fields
only, and the UI text is rendered from the app's own i18n tables:

```bash
$ ADBWIFI_FORMAT=kv ./bin/adb-wifi.sh recover
RESULT=recovered
ENDPOINT=192.168.1.50:38075
VIA=known
```

| Command | Field | Values |
|---|---|---|
| `recover` | `RESULT` | `already` / `recovered` / `failed` |
| | `ENDPOINT` | `IP:PORT` (on success) |
| | `VIA` | `existing` / `known` / `scan` / `usb` |
| | `ERROR` | `no_usb` / `tcpip_failed` (failures only) |
| `open <page>` | `RESULT` | `opened` / `partial` / `need_usb` / `no_device` / `failed` |
| | `PAGE` | Requested page: `wireless` / `dev` |
| | `TITLE` | Page actually reached: `wireless` / `dev` |
| | `WIFI_TOGGLE` | `on` / `off` / `unknown` |
| `diag` | `DIAG_CODE` | See below (always emitted, regardless of `ADBWIFI_FORMAT`) |

`diag` still emits the Chinese `DIAG_TITLE` / `DIAG_HINT` for the terminal and TUI.
The app looks up `DIAG_CODE` in its i18n tables first, and falls back to the script text
when the code is unknown (older script, or a code this app build does not ship yet), so
a raw key is never shown to the user.

| `DIAG_CODE` | Meaning |
|---|---|
| `DAEMON_DOWN_NO_DEVICE` | Daemon stopped and no device connected |
| `CONNECTED_MDNS` | Connected, mDNS discovery works |
| `CONNECTED_VIA_TCPIP_USB` | Connected (USB auto-switched to TCP), cable plugged |
| `CONNECTED_VIA_TCPIP_WIRELESS` | Connected on the wireless port, USB unplugged |
| `CONNECTED_VIA_KNOWN` | Connected via a remembered endpoint (mDNS blocked) |
| `DEV_OPTIONS_OFF` | Developer options are off on the phone |
| `USB_AUTO_TCPIP_PENDING` | USB connected, wireless link being established |
| `ADB_WIFI_OFF` | Wireless debugging is off on the phone |
| `USB_CONNECTED_NO_WIRELESS` | USB connected, no wireless link yet |
| `NO_DEVICE_MDNS_OK` | No device found, mDNS works |
| `NO_DEVICE_MDNS_BLOCKED` | No device found and the network blocks mDNS |

Field names and value ranges are a **stable contract**: changing them requires updating
`menubar/main.swift`. Every new diagnostic branch must set `code` and add the matching
`diag.<CODE>.title` / `.hint` entries to all three language tables in `menubar/i18n.swift`.

### About & Version Updates

The **About ADB WiFi** item at the bottom of the menu shows the version (read from the
git tag by `build.sh`, overridable via `ADBWIFI_VERSION=x.y.z`) and links to the
project home / issues / releases.

There are two update entries:

| Entry | Style | Source | Notes |
|---|---|---|---|
| "Check for Updates" (stable) | Large default button (Return) | `releases/latest` | Primary entry, stable only |
| "Pre-release channel: Alpha" | Small text link | First prerelease in `/releases` | Secondary, may be unstable |

The stable check calls the GitHub API (`releases/latest`, falling back to tags without
a suffix when no Release exists) and compares versions segment by segment: for the same
core version, stable > pre-release; pre-release suffixes are compared numerically
(`alpha.10 > alpha.9`).

- **Opening About auto-checks the stable channel** (throttled to once per 60 s); the
  result is shown directly on the button, never in a popup:
  "Up to date, click to recheck" / "Check failed, click to retry" /
  "Download & Install vX.Y.Z"
- **One-click auto-update**: downloads `AdbWifiBar-<version>-universal.zip`, verifies
  the signature and notarization with `spctl`, then waits for the current process to
  exit, replaces `~/Applications/AdbWifiBar.app`, and relaunches it
- **The Alpha entry is a blue underlined hyperlink**: clicking it checks the
  pre-release channel; when one exists the link becomes "Download Alpha vX.Y.Z" and a
  second click opens the download page; results appear in the status line

### Releasing

Versioning (see [AGENTS.md](AGENTS.md)): starts at `v0.0.1`; an **odd PATCH is a stable
release, an even PATCH is an Alpha base**.

| Use | Tag examples |
|---|---|
| Stable | `v0.0.1`, `v0.0.3` |
| Alpha | `v0.0.2-alpha.1`, `v0.0.4-alpha.1` |

Pushing a tag builds and publishes a GitHub Release automatically
(`.github/workflows/release.yml`):

```bash
./menubar/build.sh          # verify the build locally
git tag v0.0.1
git push origin v0.0.1      # triggers GitHub Actions
```

The workflow first validates the tag against the odd/even rule (stable must not use an
even PATCH; Alpha must not use an odd base) and fails fast otherwise. Releases with an
`alpha.N` suffix are marked **prerelease**, so the stable check ignores them and they
only show up under the "Alpha" channel in the About window.

The workflow compiles a **universal binary (arm64 + x86_64)** on a macOS runner and
attaches:

| Asset | Contents |
|---|---|
| `AdbWifiBar-<version>-universal.zip` | Menu bar app only — drag into Applications |
| `adb-wifi-manager-<version>.zip` | Full package (source + prebuilt app); unzip and run `./install.sh` |
| `SHA256SUMS.txt` | Checksums |

The version comes from the tag (`v0.0.1` → `0.0.1`), matching the in-app update check.
For a universal build locally: `ADBWIFI_UNIVERSAL=1 ./menubar/build.sh`.

> Without Developer ID configured the app is ad-hoc signed and not notarized. On first
> launch, if Gatekeeper warns, right-click the app in Finder and choose **Open**. If
> Release creation fails, check Settings → Actions → General → Workflow permissions is
> set to "Read and write".

#### Developer ID Signing & Notarization (optional)

The default is ad-hoc signing, fine for personal use. For public distribution,
configure Developer ID signing + notarization; CI handles it automatically and
**falls back to ad-hoc when unset**.

Prerequisite: an Apple Developer Program account ($99/year).

1. Keychain Access → login → My Certificates, find
   `Developer ID Application: Your Name (TEAMID)`, right-click and export a `.p12`
   with a password
2. App Store Connect → Users and Access → Keys → App Store Connect API → create a key
   with the Developer role, download `AuthKey_XXXX.p8` (one-time download), note the
   Key ID and Issuer ID
3. Add these under Settings → Secrets and variables → Actions:

| Secret | Value |
|---|---|
| `MACOS_CERT_P12` | `base64 -i cert.p12 \| tr -d '\n'` |
| `MACOS_CERT_PASSWORD` | Password chosen when exporting the `.p12` |
| `APPLE_TEAM_ID` | 10-character Team ID |
| `APPLE_API_KEY_ID` | App Store Connect API Key ID |
| `APPLE_API_ISSUER_ID` | Issuer ID |
| `APPLE_API_KEY_P8` | `base64 -i AuthKey_XXXX.p8 \| tr -d '\n'` |

Once configured, pushing a tag makes the workflow import the certificate, sign with
hardened runtime, notarize via `notarytool submit --wait`, staple the ticket, then
package and upload. Verify afterwards:

```bash
spctl -a -t exec -vv /Applications/AdbWifiBar.app
# accepted, source=Notarized Developer ID
```

Local signed build:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./menubar/build.sh
```

Rebuild:

```bash
./menubar/build.sh
```

---

## Configuration

Configuration lives in the "Configurable options" block at the top of
`bin/adb-wifi.sh`.

You may also create `config.sh` in the project root (loaded automatically at startup;
no effect when absent):

```bash
CHECK_INTERVAL=10        # Polling interval (s)
TCP_TIMEOUT=3            # TCP probe timeout (s)
CONNECT_TIMEOUT=12       # adb connect timeout (s)
CANDIDATE_PORTS="..."    # Fallback ports to probe
ENABLE_NOTIFY=1          # System notification on connect

# USB auto-enable wireless (see "Fully automatic on USB plug-in")
AUTO_TCPIP=1             # 1 = auto-switch to TCP mode on USB, 0 = disable
TCPIP_PORT=5555          # TCP listening port
TCPIP_RETRY_INTERVAL=60  # Retry interval after a failed switch (s)

# USB-free automatic recovery
AUTO_SCAN=1              # 1 = allow subnet scanning to find the device, 0 = disable
SCAN_INTERVAL=300        # Minimum interval between scans (s)
MAX_KNOWN_FAILS=360      # Consecutive failures before an endpoint is dropped
SCAN_TIMEOUT=0.8         # Per-host scan timeout (s)
```

> Editing the script top directly works the same; `config.sh` merely separates personal
> settings from code so `git pull` won't overwrite them.

---

## Fully Automatic on USB Plug-in

**Goal**: plug in USB and establish a wireless adb connection with zero taps.

### Why not just enable the "Wireless debugging" switch

Android requires `WRITE_SECURE_SETTINGS` to write `adb_wifi_enabled`, which a regular
adb shell lacks — measured to throw:

```
java.lang.SecurityException: Permission denial: writing to settings requires:
android.permission.WRITE_SECURE_SETTINGS
```

This is an OS security boundary and **cannot be bypassed by adb commands**, so
"one-tap enable the switch" is not achievable.

### The adopted approach: `adb tcpip`

`adb tcpip <port>` makes adbd listen on an additional TCP port **with no special
permissions**, as long as USB is connected and authorized. The daemon runs the whole
chain automatically:

```
Plug in USB → no usable wireless connection detected → adb tcpip 5555
            → read phone Wi-Fi IP → adb connect IP:5555 → auto-reconnect on drop
```

Measured log excerpt:

```
[INFO] USB device ABC123DEF has wireless debugging off; switching to TCP mode (port 5555) ...
[INFO]   ✓ Wireless connection established automatically via USB: 192.168.1.50:5555
```

**The connection survives unplugging USB** — the TCP listener is independent of the
USB channel.

### Two discovery methods in parallel

| Method | Trigger | Characteristics |
|---|---|---|
| System "Wireless debugging" | Manually enabled on the phone | Random port (10000+); changes on reboot |
| **`adb tcpip`** | USB attached and not yet connected | **Fixed port 5555, no manual steps — recommended** |

They don't conflict: if a wireless-debugging port is available it is used directly,
otherwise the script switches to tcpip.

### Notes

- `adb tcpip` restarts adbd; the current USB connection **briefly drops** (~3 s) then recovers
- **After a phone reboot** tcpip mode is lost — plug in USB once (handled automatically)
- The port is open to other devices on the same Wi-Fi; the first connection requires
  tapping "Allow" on the phone. **Avoid on public networks**
- To disable: set `AUTO_TCPIP=0`
- Manual trigger: menu bar "Enable TCP mode now" or `adb tcpip 5555`

### Reverting to USB mode

```bash
adb usb
```

---

## USB-free Automatic Recovery

**Key insight**: `adb tcpip 5555` only needs to run once (over USB). Afterwards adbd
**keeps listening** on 5555, so `adb connect` works whether or not USB is attached:

| Operation | Needs USB? | Purpose |
|---|---|---|
| `adb tcpip 5555` | ✅ Yes | Make the phone **start** listening (one-time) |
| `adb connect IP:5555` | ❌ No | Reconnect after a drop |

### Recovery order

Menu bar "Restore wireless connection (no USB needed)" (`⌘R`), or
`./bin/adb-wifi.sh recover`:

```
Existing connection → endpoint memory → subnet scan (finds a changed IP)
```

Measured: same IP after a drop → **under 1 s**; changed IP → rediscovered by scan in **~5 s**.

### The critical defect that was fixed

In earlier implementations, `discover_known` **deleted an endpoint immediately** as
soon as a probe failed. Brief dropouts, screen-off, and subnet changes all triggered
deletion — erasing the "way home", after which only re-plugging USB helped. This was
the real reason "automatic recovery" didn't work.

Now:
- Unreachable endpoints are **preserved**, with a failure counter
- Only after `MAX_KNOWN_FAILS` consecutive failures (default 360 ≈ 1 hour) are they purged
- When memory is empty or fully stale, the local subnet is scanned automatically
  (at most once every 5 minutes)

### Related overhead controls

Subnet scanning is powerful but must not be abused, so it has two guards:

- **`SCAN_INTERVAL`** (default 300 s): minimum interval between scans
- **Precondition**: only triggered when all five discovery paths come up empty;
  never while a connection is healthy

For full performance data and optimization details, see
[Performance Goals & Technical Design](#performance-goals--technical-design).

### When USB is still required

- **After a phone reboot**: tcpip mode is lost and adbd returns to USB mode — plug in once
- After manually running `adb usb`
- When the phone switches to a Wi-Fi network that forbids client-to-client traffic (AP isolation)

Otherwise drops, IP changes, and Mac sleep/wake are all recovered automatically.

---

## Transfer Rate Monitoring

Displays bidirectional adb transfer rates in real time — no extra tools needed.

| Entry point | Display |
|---|---|
| Menu bar | `↓ 1.2 MB/s   ↑ 0 KB/s` plus cumulative totals |
| TUI | "Transfer: ↓ … ↑ …" in the status area, plus totals |
| CLI | `./bin/adb-wifi.sh rate 2` |

### Data source and trade-offs

adb **has no built-in rate command**, so the rate must be sampled and computed locally.

| Approach | Accuracy | Cost | Verdict |
|---|---|---|---|
| Read `netstat -anv` connection byte counters | High, available locally on the Mac | <10 ms per call, non-intrusive | ✅ **adopted** |
| Read device `/proc/net/dev` | High, but includes all phone app traffic | Needs `adb shell`, which **blocks during pull/push** | ❌ rejected |
| `nettop` | Medium, aggregated per process | Parsing overhead, coarse | ❌ rejected |

The key reason: the device-side approach runs `adb shell`, which was measured to deadlock
during a large `adb pull`, whereas netstat reads locally and never interferes with transfers.

### Field mapping (measured, not assumed)

The byte columns in macOS `netstat -anv -p tcp` are easy to get wrong. Verified with real transfers:

| Operation | Field 7 | Field 8 | Conclusion |
|---|---|---|---|
| `adb pull` (phone → Mac) | **+4.38 MB** | +72 bytes | Field 7 = **downlink** |
| `adb push` (Mac → phone) | +626 bytes | **+2.79 MB** | Field 8 = **uplink** |

So `↓` uses field 7 and `↑` uses field 8. Note also that `$N` column access in macOS awk is
unreliable — anchor on `ESTABLISHED` with a whole-line regex and use `split` instead.

### Sampling strategy

- **Non-blocking**: `diag` is called frequently by the menu bar, so it must never `sleep`;
  each call takes one sample and computes the delta
- **Interval guard**: returns 0 when two samples are less than 200 ms apart, avoiding
  division by zero and jitter
- **Rollback detection**: a reconnected link resets cumulative counters, so such deltas are
  discarded rather than shown as negative or absurd values
- **Millisecond precision**: timestamps come from `perl`, avoiding the truncation error of `date +%s`

> The local wireless link shows large latency jitter (9–420 ms), so throughput fluctuates.
> Taking several samples is more meaningful than trusting a single reading.

---

## One-tap Access to Phone Settings

Manually navigating Settings → Developer options → Wireless debugging is tedious.
This project provides one-tap access.

| Entry point | Action |
|---|---|
| Menu bar | "Open 'Wireless debugging' on phone…" (`⌘W`) / "Open Developer options…" |
| CLI | `./bin/adb-wifi.sh open` or `./bin/adb-wifi.sh open dev` |
| TUI | "Open wireless debugging page on phone automatically" in the diagnosis |
| Auto-triggered | When "wireless debugging switch is off" is detected, "▸ Resolve" jumps there |

### Compatibility approach

Settings layouts differ widely, so the script tries methods in order of reliability:

| Order | Method | Applicability |
|---|---|---|
| ① | `com.android.settings/.SubSettings` + `WirelessDebuggingFragment` | AOSP standard; **verified exact on MIUI 13/14** |
| ② | `com.android.settings/.Settings$WirelessDebuggingActivity` | Standalone page on some ROMs |
| ③ | `android.settings.APPLICATION_DEVELOPMENT_SETTINGS` | Fallback: open Developer options and let the user tap |

**Key point**: verifying whether ① actually landed on the wireless debugging page relies
on `uiautomator dump` reading the UI text. On some ROMs (e.g. MIUI)
`WirelessDebuggingActivity` is an empty shell that is silently redirected to the
Settings home screen — merely checking whether `am start` errored is not enough.

The verified command:

```bash
adb shell am start -n com.android.settings/.SubSettings \
  --es ':settings:show_fragment' \
  'com.android.settings.development.WirelessDebuggingFragment'
```

### Pitfalls encountered (all handled)

- `uiautomator dump /dev/tty` throws `FileNotFoundException` on MIUI, outputting only a stack trace
  → dump to `/sdcard/` and grep instead
- The device-side `grep` is unreliable with `'A\|B'` BRE alternation
  → use separate fixed-string matches
- Chinese keywords sometimes fail to match under certain shell escaping
  → try Chinese first, then fall back to `wireless debugging` (covers English systems)

Either USB or wireless works; USB is preferred when available so the active wireless
connection is not disturbed.

---

## FAQ

**Q: The log keeps saying "no available device found"?**
1. **Simplest fix: plug in USB** — the daemon switches to TCP mode and connects
   automatically (see "Fully Automatic on USB Plug-in")
2. Without USB, confirm wireless debugging is enabled (not just "USB debugging")
3. Confirm the phone and Mac are on the **same Wi-Fi** (watch for guest networks or
   5G/2.4G isolation)
4. Corporate networks may block multicast → run `adb connect` manually once to seed
   the endpoint memory
5. Run `./bin/adb-wifi.sh once` to see all discovery outputs

**Q: USB is plugged in but it still doesn't connect?**
1. Confirm the phone allowed the "USB debugging" prompt; `adb devices` should show
   `device`
2. Check the tcpip output in the log:
   `grep tcpip ~/Library/Application\ Support/adb-wifi-manager/logs/adb-wifi.log`
3. Some vendor ROMs restrict `adb tcpip`; in that case enable wireless debugging manually
4. Without a Wi-Fi connection the phone cannot switch to TCP; the daemon skips with a note

**Q: Connected, but `adb devices` shows `unauthorized`?**
Confirm the "Allow USB debugging" prompt on the phone. If that fails, delete
`~/.android/adbkey*`, restart the daemon, and re-authorize.

**Q: How do I fully uninstall?**
```bash
./bin/adb-wifi.sh stop
rm -rf ~/mycode/adb-wifi-manager
rm -rf ~/Library/Application\ Support/adb-wifi-manager
rm -f ~/Library/LaunchAgents/com.durunzhe.adb-wifi-manager.plist
rm -rf ~/Applications/AdbWifiBar.app
```

---

## Project Structure

```
adb-wifi-manager/
├── .github/workflows/release.yml   # Tag push → build & publish Release
├── AGENTS.md                       # Project rules: versioning & release flow
├── get.sh                          # One-line online install / update
├── bin/adb-wifi.sh                 # Daemon (core logic, pure bash, no deps)
├── bin/adbwifi-tui.py              # Terminal UI (curses)
├── install.sh                      # One-shot installer (launchd + menu bar app)
├── launchd/*.plist                 # launchd template
├── menubar/main.swift              # Menu bar app source
├── menubar/build.sh                # Build script (supports ADBWIFI_UNIVERSAL=1)
├── menubar/gen-icon.swift          # App icon generator (SF Symbol → png + icns)
├── Resources/                      # Generated app icon assets
├── prebuilt/AdbWifiBar.app         # Prebuilt app inside release packages only
└── build/AdbWifiBar.app            # Local build output
```

> The script deliberately uses bash 3.2-compatible constructs: macOS's bundled
> `/bin/bash` is 3.2, where `case` inside `$(...)` and `;&` are syntax errors — all avoided.

---

## License

[Apache License 2.0](LICENSE)
