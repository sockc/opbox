#!/bin/sh
set -eu

: "${REPO:=YOUR_GH_USER/YOUR_REPO}"
: "${REF:=main}"

BIN_PATH="/usr/bin/sb-shunt"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/${REF}"

has_cmd() { command -v "$1" >/dev/null 2>&1; }

download() {
  url="$1"
  out="$2"
  if has_cmd curl; then
    curl -fsSL "$url" -o "$out"
  elif has_cmd wget; then
    wget -qO "$out" "$url"
  else
    echo "[ERR] 缺少 curl / wget，无法下载" >&2
    exit 1
  fi
}

need_root() {
  if [ "$(id -u)" != "0" ]; then
    echo "[ERR] 请用 root 运行" >&2
    exit 1
  fi
}

need_root

tmp="$(mktemp)"
download "${RAW_BASE}/sb-shunt.sh" "$tmp"
chmod +x "$tmp"

mkdir -p "$(dirname "$BIN_PATH")"
mv "$tmp" "$BIN_PATH"
chmod +x "$BIN_PATH"

echo "[OK] 已安装到：$BIN_PATH"
exec "$BIN_PATH"
