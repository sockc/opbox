#!/bin/sh
set -eu

REPO="${REPO:-sockc/opbox}"
REF="${REF:-main}"

ROOT="https://raw.githubusercontent.com/${REPO}/${REF}"
OW="${ROOT}/openwrt"

BIN="/usr/bin/sb-shunt"
LIBDIR="/usr/lib/sb-shunt/lib"
INITD="/etc/init.d/sb-shunt"

need_root() { [ "$(id -u)" = "0" ] || { echo "[ERR] 请用 root 运行"; exit 1; }; }

dl() {
  url="$1"; out="$2"
  mkdir -p "$(dirname "$out")"
  echo "[DL] $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --connect-timeout 10 --max-time 60 "$url" -o "$out" || {
      echo "[ERR] 下载失败：$url"
      exit 1
    }
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url" || {
      echo "[ERR] 下载失败：$url"
      exit 1
    }
  else
    echo "[ERR] 缺少 curl / wget"
    exit 1
  fi
}

need_root

echo "[*] Installing files from ${REPO}@${REF} ..."

# openwrt 目录下的
dl "${OW}/sb-shunt" "${BIN}"
chmod +x "${BIN}"

dl "${OW}/init.d/sb-shunt" "${INITD}"
chmod +x "${INITD}"

# lib 在仓库根目录（重要修复点）
dl "${ROOT}/lib/common.sh" "${LIBDIR}/common.sh"
dl "${ROOT}/lib/deps.sh"   "${LIBDIR}/deps.sh"
dl "${ROOT}/lib/fw.sh"     "${LIBDIR}/fw.sh"
dl "${ROOT}/lib/sub.sh"    "${LIBDIR}/sub.sh"
dl "${ROOT}/lib/config.sh" "${LIBDIR}/config.sh"

echo "[OK] Files installed."
/etc/init.d/sb-shunt enable >/dev/null 2>&1 || true

echo "[*] Run: sb-shunt"
exec "${BIN}"
