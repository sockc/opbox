#!/bin/sh
set -eu

REPO="${REPO:-sockc/opbox}"
REF="${REF:-main}"
ROOT="https://raw.githubusercontent.com/${REPO}/${REF}"

BIN="/usr/bin/sb-shunt"
LIBDIR="/usr/lib/sb-shunt/lib"
INITD="/etc/init.d/sb-shunt"

need_root() {
  [ "$(id -u)" = "0" ] || { echo "[ERR] need root"; exit 1; }
}

dl() {
  url="$1"
  out="$2"
  mkdir -p "$(dirname "$out")"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
  else
    echo "[ERR] need curl or wget"
    exit 1
  fi
}

install_files() {
  echo "[*] Installing files from ${REPO}@${REF} ..."

  # entry + openwrt specific
  dl "${ROOT}/openwrt/sb-shunt"        "${BIN}"
  dl "${ROOT}/openwrt/init.d/sb-shunt" "${INITD}"

  # libs at repo root (/lib)
  dl "${ROOT}/lib/common.sh" "${LIBDIR}/common.sh"
  dl "${ROOT}/lib/deps.sh"   "${LIBDIR}/deps.sh"
  dl "${ROOT}/lib/fw.sh"     "${LIBDIR}/fw.sh"
  dl "${ROOT}/lib/sub.sh"    "${LIBDIR}/sub.sh"
  dl "${ROOT}/lib/config.sh" "${LIBDIR}/config.sh"

  chmod +x "${BIN}" "${INITD}"
  echo "[OK] Files installed."
}

post() {
  /etc/init.d/sb-shunt enable >/dev/null 2>&1 || true
  echo "[*] Run: sb-shunt"
  "${BIN}" || true
}

need_root
install_files
post
