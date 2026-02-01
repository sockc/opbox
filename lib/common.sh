#!/bin/sh

need_root() { [ "$(id -u)" = "0" ] || { echo "[ERR] need root"; return 1; }; }

rand_str() {
  n="${1:-16}"
  tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c "$n" || echo "sb$(date +%s)"
}

cmd_ok() { command -v "$1" >/dev/null 2>&1; }

dl_to() {
  url="$1"; out="$2"
  mkdir -p "$(dirname "$out")"
  if cmd_ok curl; then
    curl -fsSL "$url" -o "$out"
  elif cmd_ok wget; then
    wget -qO "$out" "$url"
  else
    echo "[ERR] need curl or wget"; return 1
  fi
}

sb_version() {
  cmd_ok sing-box || { echo "0.0.0"; return 0; }
  sing-box version 2>/dev/null | sed -n 's/.*version[[:space:]]\+\([0-9.]\+\).*/\1/p' | head -n1
}

ver2int() { echo "$1" | awk -F. '{printf "%d%03d%03d\n",$1,$2,$3}'; }

sb_ver_ge() {
  a="$(sb_version)"; b="$1"
  [ "$(ver2int "$a")" -ge "$(ver2int "$b")" ]
}

get_lan_if() {
  # OpenWrt: network.lan.device (DSA) or network.lan.ifname (swconfig)
  ifname="$(uci -q get network.lan.device 2>/dev/null || true)"
  [ -n "$ifname" ] || ifname="$(uci -q get network.lan.ifname 2>/dev/null || true)"
  [ -n "$ifname" ] || ifname="br-lan"
  echo "$ifname"
}
#!/bin/sh

need_root() { [ "$(id -u)" = "0" ] || { echo "[ERR] need root"; return 1; }; }

cmd_ok() { command -v "$1" >/dev/null 2>&1; }

rand_str() {
  n="${1:-16}"
  tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c "$n" || echo "sb$(date +%s)"
}

dl_to() {
  url="$1"; out="$2"
  mkdir -p "$(dirname "$out")"
  if cmd_ok curl; then
    curl -fsSL "$url" -o "$out"
  elif cmd_ok wget; then
    wget -qO "$out" "$url"
  else
    echo "[ERR] need curl or wget"
    return 1
  fi
}

get_lan_if() {
  ifname="$(uci -q get network.lan.device 2>/dev/null || true)"
  [ -n "$ifname" ] || ifname="$(uci -q get network.lan.ifname 2>/dev/null || true)"
  [ -n "$ifname" ] || ifname="br-lan"
  echo "$ifname"
}

sb_version() {
  cmd_ok sing-box || { echo "0.0.0"; return 0; }
  sing-box version 2>/dev/null | sed -n 's/.*version[[:space:]]\+\([0-9.]\+\).*/\1/p' | head -n1
}

ver2int() { echo "$1" | awk -F. '{printf "%d%03d%03d\n",$1,$2,$3}'; }

sb_ver_ge() {
  a="$(sb_version)"; b="$1"
  [ "$(ver2int "$a")" -ge "$(ver2int "$b")" ]
}
