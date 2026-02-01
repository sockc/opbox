#!/bin/sh
. /usr/lib/sb-shunt/lib/common.sh

FW3="/etc/firewall.user"
FW4="/etc/firewall4.user"

fw_script_path() { echo "$1/firewall.user"; }

fw_write_script() {
  sbdir="$1"
  f="$(fw_script_path "$sbdir")"
  lan_if="${LAN_IF:-}"
  [ -n "$lan_if" ] || lan_if="$(get_lan_if)"

  cat >"$f" <<EOF
#!/bin/sh
# SB-Shunt injected rules (iptables-nft)
LAN_IF="${lan_if}"

# Chains
iptables -t nat -N SB_SHUNT 2>/dev/null || iptables -t nat -F SB_SHUNT
iptables -t nat -N SB_DNS   2>/dev/null || iptables -t nat -F SB_DNS

# Hook once
iptables -t nat -C PREROUTING -i "\$LAN_IF" -p tcp -j SB_SHUNT 2>/dev/null || \
  iptables -t nat -A PREROUTING -i "\$LAN_IF" -p tcp -j SB_SHUNT

iptables -t nat -C PREROUTING -i "\$LAN_IF" -p udp --dport 53 -j SB_DNS 2>/dev/null || \
  iptables -t nat -A PREROUTING -i "\$LAN_IF" -p udp --dport 53 -j SB_DNS

iptables -t nat -C PREROUTING -i "\$LAN_IF" -p tcp --dport 53 -j SB_DNS 2>/dev/null || \
  iptables -t nat -A PREROUTING -i "\$LAN_IF" -p tcp --dport 53 -j SB_DNS

# Exclude RFC1918/reserved
for cidr in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
  iptables -t nat -C SB_SHUNT -d "\$cidr" -j RETURN 2>/dev/null || iptables -t nat -A SB_SHUNT -d "\$cidr" -j RETURN
done

# DNS to sing-box dns-in (1053)
iptables -t nat -C SB_DNS -j REDIRECT --to-ports 1053 2>/dev/null || iptables -t nat -A SB_DNS -j REDIRECT --to-ports 1053

# TCP to sing-box redirect-in (12345)
iptables -t nat -C SB_SHUNT -p tcp -j REDIRECT --to-ports 12345 2>/dev/null || iptables -t nat -A SB_SHUNT -p tcp -j REDIRECT --to-ports 12345
EOF
  chmod +x "$f"
}

fw_inject_userfile() {
  sbdir="$1"
  hook="sh $(fw_script_path "$sbdir") >/dev/null 2>&1"
  if [ -f "$FW4" ]; then
    grep -qF "$hook" "$FW4" 2>/dev/null || echo "$hook" >>"$FW4"
  else
    touch "$FW3" >/dev/null 2>&1 || true
    grep -qF "$hook" "$FW3" 2>/dev/null || echo "$hook" >>"$FW3"
  fi
}

fw_remove_userfile_hook() {
  sbdir="$1"
  hook="sh $(fw_script_path "$sbdir") >/dev/null 2>&1"
  [ -f "$FW4" ] && sed -i "\|$hook|d" "$FW4" 2>/dev/null || true
  [ -f "$FW3" ] && sed -i "\|$hook|d" "$FW3" 2>/dev/null || true
}

fw_apply_now() {
  sbdir="$1"
  f="$(fw_script_path "$sbdir")"
  [ -x "$f" ] && sh "$f" || true
  /etc/init.d/firewall restart >/dev/null 2>&1 || true
}

fw_install() {
  sbdir="$1"
  fw_write_script "$sbdir"
  fw_inject_userfile "$sbdir"
  fw_apply_now "$sbdir"
}

fw_uninstall() {
  sbdir="$1"
  fw_remove_userfile_hook "$sbdir"
  rm -f "$(fw_script_path "$sbdir")" >/dev/null 2>&1 || true

  # best-effort cleanup existing chains
  iptables -t nat -D PREROUTING -p tcp -j SB_SHUNT 2>/dev/null || true
  iptables -t nat -D PREROUTING -p udp --dport 53 -j SB_DNS 2>/dev/null || true
  iptables -t nat -D PREROUTING -p tcp --dport 53 -j SB_DNS 2>/dev/null || true
  iptables -t nat -F SB_SHUNT 2>/dev/null || true
  iptables -t nat -X SB_SHUNT 2>/dev/null || true
  iptables -t nat -F SB_DNS 2>/dev/null || true
  iptables -t nat -X SB_DNS 2>/dev/null || true

  /etc/init.d/firewall restart >/dev/null 2>&1 || true
}

