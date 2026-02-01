#!/bin/sh
set -eu

REPO="${REPO:-sockc/opbox}"
REF="${REF:-main}"
BASE="https://raw.githubusercontent.com/${REPO}/${REF}/openwrt"

BIN="/usr/bin/sb-shunt"
LIBDIR="/usr/lib/sb-shunt/lib"
INITD="/etc/init.d/sb-shunt"

need_root() { [ "$(id -u)" = "0" ] || { echo "[ERR] need root"; exit 1; }; }

dl() {
  url="$1"; out="$2"
  mkdir -p "$(dirname "$out")"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL  "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
  else
    echo "[ERR] need curl or wget"; exit 1
  fi
}

install_files() {
  echo "[*] Installing files from ${REPO}@${REF} ..."
  dl "${BASE}/sb-shunt" "${BIN}"
  chmod +x "${BIN}"

  dl "${BASE}/lib/common.sh" "${LIBDIR}/common.sh"
  dl "${BASE}/lib/deps.sh"   "${LIBDIR}/deps.sh"
  dl "${BASE}/lib/fw.sh"     "${LIBDIR}/fw.sh"
  dl "${BASE}/lib/sub.sh"    "${LIBDIR}/sub.sh"
  dl "${BASE}/lib/config.sh" "${LIBDIR}/config.sh"

  dl "${BASE}/init.d/sb-shunt" "${INITD}"
  chmod +x "${INITD}"

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
