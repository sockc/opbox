#!/bin/sh

ensure_deps() {
  echo "[*] opkg update..."
  opkg update >/dev/null 2>&1 || true

  pkgs="ca-bundle ca-certificates curl wget jq ip-full iptables-nft nftables kmod-tun"
  for p in $pkgs; do
    opkg install "$p" >/dev/null 2>&1 || true
  done
}

ensure_singbox() {
  if command -v sing-box >/dev/null 2>&1; then
    return 0
  fi
  echo "[*] Installing sing-box..."
  opkg update >/dev/null 2>&1 || true
  opkg install sing-box >/dev/null 2>&1 || {
    echo "[ERR] opkg 无法安装 sing-box（请确认你的 OpenWrt feeds / 架构支持）"
    return 1
  }
}

# Clash 订阅转换：自动下载 clash2singbox（GitHub latest release + 资产匹配）
ensure_clash2singbox() {
  [ -x /usr/bin/clash2singbox ] && return 0

  echo "[*] Downloading clash2singbox ..."
  tmp="/tmp/clash2singbox.$$"
  json="/tmp/clash2singbox_release.$$"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://api.github.com/repos/xmdhs/clash2singbox/releases/latest -o "$json"
  else
    wget -qO "$json" https://api.github.com/repos/xmdhs/clash2singbox/releases/latest
  fi

  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) pat="amd64|x86_64" ;;
    aarch64|arm64) pat="arm64|aarch64" ;;
    armv7l|armv7) pat="armv7|armv7l|arm" ;;
    mipsel|mipsle) pat="mipsel|mipsle" ;;
    mips) pat="mips" ;;
    *) pat="$arch" ;;
  esac

  url="$(jq -r --arg pat "$pat" '
    .assets[].browser_download_url
    | select(test("linux";"i"))
    | select(test($pat;"i"))
  ' "$json" 2>/dev/null | head -n1)"

  [ -n "$url" ] || {
    echo "[ERR] clash2singbox 未找到匹配资产（arch=$arch），你可以手动放置 /usr/bin/clash2singbox"
    return 1
  }

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$tmp" "$url"
  else
    wget -qO "$tmp" "$url"
  fi
  chmod +x "$tmp"
  mv "$tmp" /usr/bin/clash2singbox
  chmod +x /usr/bin/clash2singbox
  rm -f "$json" >/dev/null 2>&1 || true
  echo "[OK] clash2singbox ready."
}
#!/bin/sh

ensure_deps() {
  opkg update >/dev/null 2>&1 || true
  for p in ca-bundle ca-certificates curl wget jq ip-full iptables-nft nftables kmod-tun; do
    opkg install "$p" >/dev/null 2>&1 || true
  done
}

ensure_singbox() {
  command -v sing-box >/dev/null 2>&1 && return 0
  opkg update >/dev/null 2>&1 || true
  opkg install sing-box >/dev/null 2>&1 || {
    echo "[ERR] opkg 无法安装 sing-box（请确认 feeds/架构）"
    return 1
  }
}

ensure_clash2singbox() {
  [ -x /usr/bin/clash2singbox ] && return 0

  echo "[*] Downloading clash2singbox ..."
  json="/tmp/clash2singbox_release.$$"
  tmp="/tmp/clash2singbox.bin.$$"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://api.github.com/repos/xmdhs/clash2singbox/releases/latest -o "$json"
  else
    wget -qO "$json" https://api.github.com/repos/xmdhs/clash2singbox/releases/latest
  fi

  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) pat="amd64|x86_64" ;;
    aarch64|arm64) pat="arm64|aarch64" ;;
    armv7l|armv7) pat="armv7|armv7l|arm" ;;
    mipsel|mipsle) pat="mipsel|mipsle" ;;
    mips) pat="mips" ;;
    *) pat="$arch" ;;
  esac

  url="$(jq -r --arg pat "$pat" '
    .assets[].browser_download_url
    | select(test("linux";"i"))
    | select(test($pat;"i"))
  ' "$json" 2>/dev/null | head -n1)"

  [ -n "$url" ] || { echo "[ERR] clash2singbox 未找到匹配资产（arch=$arch）"; rm -f "$json"; return 1; }

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$tmp" "$url"
  else
    wget -qO "$tmp" "$url"
  fi
  chmod +x "$tmp"
  mv "$tmp" /usr/bin/clash2singbox
  chmod +x /usr/bin/clash2singbox
  rm -f "$json" >/dev/null 2>&1 || true
  echo "[OK] clash2singbox ready."
}

