#!/bin/bash
# get.sh —— 一键在线安装 / 更新 adb-wifi-manager
#
#   curl -fsSL https://raw.githubusercontent.com/DuRunzhe/adb-wifi-manager/main/get.sh | bash
#
# 可选环境变量：
#   ADBWIFI_VERSION=0.0.3                   指定版本（默认最新正式版；可传 Alpha）
#   ADBWIFI_DIR=~/mycode/adb-wifi-manager   安装目录
#   ADBWIFI_SKIP_INSTALL=1                  只下载部署，不注册 launchd / 不安装 App
set -uo pipefail

REPO="DuRunzhe/adb-wifi-manager"
DEST="${ADBWIFI_DIR:-$HOME/mycode/adb-wifi-manager}"

info() { printf '%s\n' "$*"; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "目前仅支持 macOS"
command -v curl >/dev/null 2>&1 || die "未找到 curl"
command -v rsync >/dev/null 2>&1 || die "未找到 rsync"
command -v ditto >/dev/null 2>&1 || die "未找到 ditto"

# 1) 解析版本
VERSION="${ADBWIFI_VERSION:-}"
if [ -n "$VERSION" ]; then
    VERSION="${VERSION#v}"
    info "使用指定版本: $VERSION"
else
    info "查询最新正式版本 ..."
    TAG=$(curl -fsSL --max-time 20 \
        -H 'Accept: application/vnd.github+json' \
        -H "User-Agent: adb-wifi-manager-get" \
        "https://api.github.com/repos/$REPO/releases/latest" \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    [ -n "$TAG" ] || die "未获取到最新正式版本；可用 ADBWIFI_VERSION=0.0.1 指定版本"
    VERSION="${TAG#v}"
    info "最新正式版本: $VERSION"
fi
TAG="v$VERSION"

# 2) 下载完整安装包
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ZIP="adb-wifi-manager-$VERSION.zip"
BASE="https://github.com/$REPO/releases/download/$TAG"
info "下载 $ZIP ..."
curl -fL --progress-bar --max-time 300 -o "$TMP/$ZIP" "$BASE/$ZIP" \
    || die "下载失败：版本 ${VERSION} 可能尚未发布（${BASE}）"

# 3) 校验（存在 SHA256SUMS.txt 时）
if curl -fsSL --max-time 30 -o "$TMP/SHA256SUMS.txt" "$BASE/SHA256SUMS.txt"; then
    WANT=$(awk -v f="$ZIP" '$2 == f {print $1}' "$TMP/SHA256SUMS.txt")
    if [ -n "$WANT" ]; then
        ACTUAL=$(shasum -a 256 "$TMP/$ZIP" | awk '{print $1}')
        [ "$WANT" = "$ACTUAL" ] || die "SHA256 校验失败，下载可能不完整"
        info "✓ SHA256 校验通过"
    fi
else
    info "⚠ 未获取到 SHA256SUMS.txt，跳过校验"
fi

# 4) 解压
info "解压 ..."
ditto -x -k "$TMP/$ZIP" "$TMP/unzip" || die "解压失败"
SRC="$TMP/unzip/adb-wifi-manager-$VERSION"
[ -d "$SRC" ] || die "解压结果异常：未找到 adb-wifi-manager-$VERSION"

# 5) 部署到目标目录（保留已有的 config.sh）
if [ -d "$DEST" ]; then
    info "覆盖更新已有安装: ${DEST}（config.sh 会保留）"
fi
mkdir -p "$DEST"
rsync -a --exclude 'config.sh' "$SRC/" "$DEST/"
chmod +x "$DEST/install.sh" "$DEST/bin/adb-wifi.sh" 2>/dev/null
info "✓ 已部署到 $DEST"

if [ "${ADBWIFI_SKIP_INSTALL:-0}" = "1" ]; then
    info "已跳过安装步骤（ADBWIFI_SKIP_INSTALL=1）"
    info "手动安装：cd \"$DEST\" && ./install.sh"
    exit 0
fi

# 6) 执行包内安装脚本（注册 launchd + 安装菜单栏 App）
cd "$DEST" || die "无法进入 $DEST"
info "开始安装（launchd + 菜单栏 App）..."
exec ./install.sh
