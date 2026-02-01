#!/bin/sh
set -eu

# ========= 基本可配项（也可运行时通过环境变量覆盖）=========
: "${REPO:=YOUR_GH_USER/YOUR_REPO}"
: "${REF:=main}"
: "${SVC:=sb-shunt}"
: "${CONF_DIR:=/etc/sing-box}"
: "${CONF_FILE:=/etc/sing-box/sb-shunt.json}"
: "${WORKDIR:=/usr/share/sb-shunt}"
: "${BIN:=/usr/bin/sing-box}"
: "${WEB_PANEL:=false}" # 是否安装 web 面板，默认为 false
: "${PANEL_PORT:=8080}" # Web 面板端口，默认 8080

RAW_BASE="https://raw.githubusercontent.com/${REPO}/${REF}"
SELF="/usr/bin/sb-shunt"

# ========= 工具函数 =========
has_cmd() { command -v "$1" >/dev/null 2>&1; }
pause() { printf "\n按回车继续..." ; read -r _ || true; }

need_root() {
  if [ "$(id -u)" != "0" ]; then
    echo "[ERR] 请用 root 运行" >&2
    exit 1
  fi
}

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

svc_running() {
  /etc/init.d/"$SVC" status >/dev/null 2>&1
}

show_status() {
  printf "服务：%s  " "$SVC"
  if svc_running; then
    echo "状态：运行中"
  else
    echo "状态：未运行"
  fi

  if [ -x "$BIN" ]; then
    ver="$($BIN version 2>/dev/null | head -n1 || true)"
    [ -n "$ver" ] && echo "sing-box：$ver"
  else
    echo "sing-box：未安装"
  fi
}

opkg_try_install() {
  # 兼容：有些包在不同源/版本可能不存在，失败不直接退出
  for p in "$@"; do
    opkg install "$p" >/dev/null 2>&1 || true
  done
}

install_deps() {
  echo "[*] opkg update ..."
  opkg update >/dev/null 2>&1 || true

  echo "[*] 安装依赖（kmod-tun / diag / ca-bundle / curl 等）..."
  opkg_try_install ca-bundle ca-certificates curl wget
  opkg_try_install kmod-tun kmod-inet-diag kmod-netlink-diag
  opkg_try_install ip-full iptables-nft nftables

  echo "[*] 安装 sing-box ..."
  opkg install sing-box >/dev/null 2>&1 || true

  if [ ! -x "$BIN" ]; then
    echo "[ERR] 未找到 $BIN（你的 OpenWrt 源可能没有 sing-box 包）。" >&2
    echo "      你可以换软件源/自己放入 sing-box 二进制到：$BIN" >&2
    return 1
  fi
  return 0
}

write_init() {
  mkdir -p /etc/init.d "$WORKDIR" "$CONF_DIR"
  cat > "/etc/init.d/$SVC" <<'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=10

BIN="/usr/bin/sing-box"
CONF="/etc/sing-box/sb-shunt.json"
WORKDIR="/usr/share/sb-shunt"

start_service() {
  [ -x "$BIN" ] || return 1
  [ -f "$CONF" ] || return 1
  mkdir -p "$WORKDIR"

  procd_open_instance
  procd_set_param command "$BIN" run -c "$CONF" -D "$WORKDIR"
  procd_set_param respawn 3600 5 5
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_set_param file "$CONF"
  procd_close_instance
}

reload_service() {
  stop
  start
}
EOF
  chmod +x "/etc/init.d/$SVC"
}

# ========= 配置生成（两种模式）=========
# 说明：
# - 采用 rule_set(.srs) 做 “国内直连/国外代理” 分流，避免 geoip/geosite 被移除的问题。([sing-box.sagernet.org](https://sing-box.sagernet.org/configuration/route/rule/))
# - tun + auto_route + auto_redirect：OpenWrt fw4 兼容由 sing-box 自动处理（更省事）。([sing-box.sagernet.org](https://sing-box.sagernet.org/configuration/inbound/tun/))
# - route.final 用来指定默认出站（不匹配规则时走哪个）。([sing-box.sagernet.org](https://sing-box.sagernet.org/configuration/route/))
gen_config_mode1() {
  proxy_host="$1"
  proxy_port="$2"
  proxy_user="$3"
  proxy_pass="$4"

  # DNS：简单规则（“With DNS leaks” 示例的思路：CN 走 local，其它走 google）([sing-box.sagernet.org](https://sing-box.sagernet.org/zh/manual/proxy/client/))
  # 路由：CN 直连，其它走 proxy；包含 hijack-dns + 私网直连 + sniff。([sing-box.sagernet.org](https://sing-box.sagernet.org/zh/manual/proxy/client/))
  cat > "$CONF_FILE" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true,
    "output": "/tmp/sb-shunt.log"
  },
  "dns": {
    "servers": [
      {
        "tag": "google",
        "type": "tls",
        "server": "8.8.8.8",
        "detour": "proxy"
      },
      {
        "tag": "local",
        "type": "https",
        "server": "223.5.5.5",
        "detour": "direct"
      }
    ],
    "rules": [
      { "rule_set": "geosite-geolocation-cn", "server": "local" },
      {
        "type": "logical",
        "mode": "and",
        "rules": [
          { "rule_set": "geosite-geolocation-!cn", "invert": true },
          { "rule_set": "geoip-cn" }
        ],
        "server": "local"
      }
    ],
    "final": "google"
  },
  "inbounds": [
    {
      "type": "tun",
      "address": ["172.19.0.1/30"],
      "auto_route": true,
      "auto_redirect": true,
      "strict_route": true
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    {
      "type": "socks",
      "tag": "proxy",
      "server": "${proxy_host}",
      "server_port": ${proxy_port}$( [ -n "$proxy_user" ] && printf ',\n      "username": "%s"' "$proxy_user" )$( [ -n "$proxy_pass" ] && printf ',\n      "password": "%s"' "$proxy_pass" )
    }
  ],
  "route": {
    "default_domain_resolver": "local",
    "auto_detect_interface": true,
    "final": "proxy",
    "rules": [
      { "action": "sniff" },
      {
        "type": "logical",
        "mode": "or",
        "rules": [
          { "protocol": "dns" },
          { "port": 53 }
        ],
        "action": "hijack-dns"
      },
      { "ip_is_private": true, "action": "route", "outbound": "direct" },
      { "rule_set": "geosite-geolocation-cn", "action": "route", "outbound": "direct" },
      {
        "type": "logical",
        "mode": "and",
        "rules": [
          { "rule_set": "geoip-cn" },
          { "rule_set": "geosite-geolocation-!cn", "invert": true }
        ],
        "action": "route",
        "outbound": "direct"
      }
    ],
    "rule_set": [
      {
        "type": "remote",
        "tag": "geosite-geolocation-cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-cn.srs"
      },
      {
        "type": "remote",
        "tag": "geosite-geolocation-!cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs"
      },
      {
        "type": "remote",
        "tag": "geoip-cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs"
      }
    ]
  },
  "experimental": {
    "cache_file": {
      "enabled": true,
      "store_rdrc": true
    }
  }
}
EOF
}

gen_config_mode2() {
  proxy_host="$1"
  proxy_port="$2"
  proxy_user="$3"
  proxy_pass="$4"

  # DNS：采用“Without DNS leaks, but slower” 的思路（logical 规则对 cn 场景给 google 附带 client_subnet）([sing-box.sagernet.org](https://sing-box.sagernet.org/zh/manual/proxy/client/))
  # Route：额外 reject 853/udp443/stun，减少常见绕过；其余同“国内直连/国外代理”。([sing-box.sagernet.org](https://sing-box.sagernet.org/zh/manual/proxy/client/))
  cat > "$CONF_FILE" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true,
    "output": "/tmp/sb-shunt.log"
  },
  "dns": {
    "servers": [
      {
        "tag": "google",
        "type": "tls",
        "server": "8.8.8.8",
        "detour": "proxy"
      },
      {
        "tag": "local",
        "type": "https",
        "server": "223.5.5.5",
        "detour": "direct"
      }
    ],
    "rules": [
      { "rule_set": "geosite-geolocation-cn", "server": "local" },
      {
        "type": "logical",
        "mode": "and",
        "rules": [
          { "rule_set": "geosite-geolocation-!cn", "invert": true },
          { "rule_set": "geoip-cn" }
        ],
        "server": "google",
        "client_subnet": "114.114.114.114/24"
      }
    ],
    "final": "google"
  },
  "inbounds": [
    {
      "type": "tun",
      "address": ["172.19.0.1/30"],
      "auto_route": true,
      "auto_redirect": true,
      "strict_route": true
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    {
      "type": "socks",
      "tag": "proxy",
      "server": "${proxy_host}",
      "server_port": ${proxy_port}$( [ -n "$proxy_user" ] && printf ',\n      "username": "%s"' "$proxy_user" )$( [ -n "$proxy_pass" ] && printf ',\n      "password": "%s"' "$proxy_pass" )
    }
  ],
  "route": {
    "default_domain_resolver": "local",
    "auto_detect_interface": true,
    "final": "proxy",
    "rules": [
      { "action": "sniff" },
      {
        "type": "logical",
        "mode": "or",
        "rules": [
          { "protocol": "dns" },
          { "port": 53 }
        ],
        "action": "hijack-dns"
      },
      { "ip_is_private": true, "action": "route", "outbound": "direct" },
      {
        "type": "logical",
        "mode": "or",
        "rules": [
          { "port": 853 },
          { "network": "udp", "port": 443 },
          { "protocol": "stun" }
        ],
        "action": "reject"
      },
      { "rule_set": "geosite-geolocation-cn", "action": "route", "outbound": "direct" },
      {
        "type": "logical",
        "mode": "and",
        "rules": [
          { "rule_set": "geoip-cn" },
          { "rule_set": "geosite-geolocation-!cn", "invert": true }
        ],
        "action": "route",
        "outbound": "direct"
      }
    ],
    "rule_set": [
      {
        "type": "remote",
        "tag": "geosite-geolocation-cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-cn.srs"
      },
      {
        "type": "remote",
        "tag": "geosite-geolocation-!cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs"
      },
      {
        "type": "remote",
        "tag": "geoip-cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs"
      }
    ]
  },
  "experimental": {
    "cache_file": {
      "enabled": true,
      "store_rdrc": true
    }
  }
}
EOF
}

validate_config() {
  if ! "$BIN" check -c "$CONF_FILE" >/dev/null 2>&1; then
    echo "[ERR] 配置校验失败：$CONF_FILE" >&2
    "$BIN" check -c "$CONF_FILE" 2>&1 || true
    return 1
  fi
  return 0
}

do_install() {
  echo "选择安装模式："
  echo "  1) 普通分流（国内直连 / 国外代理）"
  echo "  2) 完整分流（更严格 DNS + 禁用常见绕过）"
  printf "请输入 [1-2]: "
  read -r mode

  printf "上游代理（SOCKS5）地址 [127.0.0.1]: "
  read -r proxy_host
  proxy_host="${proxy_host:-127.0.0.1}"

  printf "上游代理（SOCKS5）端口 [7890]: "
  read -r proxy_port
  proxy_port="${proxy_port:-7890}"

  printf "SOCKS5 用户名（可空）: "
  read -r proxy_user

  printf "SOCKS5 密码（可空）: "
  read -r proxy_pass

  if ! install_deps; then
    pause
    return
  fi

  mkdir -p "$CONF_DIR" "$WORKDIR"

  case "$mode" in
    1) gen_config_mode1 "$proxy_host" "$proxy_port" "$proxy_user" "$proxy_pass" ;;
    2) gen_config_mode2 "$proxy_host" "$proxy_port" "$proxy_user" "$proxy_pass" ;;
    *) echo "[ERR] 模式无效" >&2; pause; return ;;
  esac

  if ! validate_config; then
    pause
    return
  fi

  write_init
  /etc/init.d/"$SVC" enable >/dev/null 2>&1 || true
  /etc/init.d/"$SVC" restart >/dev/null 2>&1 || true

  echo "[OK] 安装完成 ✅"
  echo "     配置：$CONF_FILE"
  echo "     日志：/tmp/sb-shunt.log"
  pause
}

do_uninstall() {
  echo "[*] 停止并移除服务/配置..."
  /etc/init.d/"$SVC" stop >/dev/null 2>&1 || true
  /etc/init.d/"$SVC" disable >/dev/null 2>&1 || true
  rm -f "/etc/init.d/$SVC"
  rm -f "$CONF_FILE"
  rm -rf "$WORKDIR"

  echo "是否卸载 sing-box 包？(y/N): \c"
  read -r yn
  case "$yn" in
    y|Y)
      opkg remove sing-box >/dev/null 2>&1 || true
      ;;
  esac

  echo "[OK] 已卸载"
  pause
}

do_update() {
  echo "[*] 更新脚本..."
  tmp="$(mktemp)"
  if download "${RAW_BASE}/sb-shunt.sh" "$tmp"; then
    chmod +x "$tmp"
    mv "$tmp" "$SELF"
    chmod +x "$SELF"
    echo "[OK] 脚本已更新：$SELF"
  else
    echo "[ERR] 脚本下载失败（检查 REPO/REF 是否正确）" >&2
    rm -f "$tmp" || true
    pause
    return
