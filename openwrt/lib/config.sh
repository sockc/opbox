#!/bin/sh
# SB-SHUNT CONFIG.SH v20260202-dns-legacy-auto

detect_dns_fmt() {
  # sing-box >= 1.12 支持 dns.servers[].type；更老版本用 legacy address 格式
  v="$(sing-box version 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+/) {print $i; exit}}')"
  # 解析主次版本
  major="$(echo "$v" | cut -d. -f1)"
  minor="$(echo "$v" | cut -d. -f2)"
  [ -n "$major" ] && [ -n "$minor" ] || { echo legacy; return; }
  # >=1.12 -> new
  if [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 12 ]; }; then
    echo new
  else
    echo legacy
  fi
}

gen_config() {
  MODE="$1"
  NODES_FILE="$2"
  OUT_FILE="$3"

  : "${REDIR_PORT:=12345}"
  : "${DNS_PORT:=1053}"
  : "${PROXY_DEFAULT:=auto}"

  : "${API_ENABLE:=0}"
  : "${API_LISTEN:=127.0.0.1}"
  : "${API_PORT:=9090}"
  : "${API_SECRET:=}"

  : "${PANEL_ENABLE:=0}"
  : "${UI_DIR:=/etc/sb-shunt/ui}"
  : "${UI_DL_URL:=}"

  : "${DNS_CN:=223.5.5.5}"
  : "${DNS_FOREIGN:=1.1.1.1}"

  : "${GEOIP_CN_URL:=https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs}"
  : "${GEOSITE_CN_URL:=https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs}"
  : "${GEOSITE_ADS_URL:=https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs}"

  [ -s "$NODES_FILE" ] || { echo "[ERR] nodes.json 不存在或为空：$NODES_FILE"; return 1; }

  DNS_FMT="$(detect_dns_fmt)"
  echo "[DBG] sing-box dns fmt: $DNS_FMT"

  jq -n \
    --arg mode "$MODE" \
    --arg dns_fmt "$DNS_FMT" \
    --argjson redir_port "$REDIR_PORT" \
    --argjson dns_port "$DNS_PORT" \
    --arg proxy_default "$PROXY_DEFAULT" \
    --arg api_enable "$API_ENABLE" \
    --arg api_listen "$API_LISTEN" \
    --arg api_port "$API_PORT" \
    --arg api_secret "$API_SECRET" \
    --arg panel_enable "$PANEL_ENABLE" \
    --arg ui_dir "$UI_DIR" \
    --arg ui_dl_url "$UI_DL_URL" \
    --arg dns_cn "$DNS_CN" \
    --arg dns_foreign "$DNS_FOREIGN" \
    --arg geoip_cn_url "$GEOIP_CN_URL" \
    --arg geosite_cn_url "$GEOSITE_CN_URL" \
    --arg geosite_ads_url "$GEOSITE_ADS_URL" \
    --slurpfile nodes "$NODES_FILE" '
      def nodes: $nodes[0];
      def node_tags: (nodes | map(.tag));

      def rs_common: [
        { tag:"geoip-cn", type:"remote", format:"binary", url:$geoip_cn_url, download_detour:"direct", update_interval:"1d" },
        { tag:"geosite-cn", type:"remote", format:"binary", url:$geosite_cn_url, download_detour:"direct", update_interval:"1d" }
      ];

      def rs_ads:
        if $mode=="2" then
          [ { tag:"geosite-ads", type:"remote", format:"binary", url:$geosite_ads_url, download_detour:"direct", update_interval:"1d" } ]
        else [] end;

      def dns_servers:
        if $dns_fmt=="new" then
          [
            { tag:"dns_cn",   type:"udp", server:$dns_cn,      detour:"direct" },
            { tag:"dns_proxy",type:"udp", server:$dns_foreign, detour:"proxy"  }
          ]
        else
          [
            { tag:"dns_cn",   address:$dns_cn,      detour:"direct" },
            { tag:"dns_proxy",address:$dns_foreign, detour:"proxy"  }
          ]
        end;

      def dns_rules:
        (if $mode=="2" then [ { rule_set:["geosite-ads"], server:"dns_proxy" } ] else [] end)
        + [ { rule_set:["geosite-cn"], server:"dns_cn" }, { server:"dns_proxy" } ];

      def private_cidrs: [
        "0.0.0.0/8","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8",
        "169.254.0.0/16","172.16.0.0/12","192.0.0.0/24","192.0.2.0/24",
        "192.168.0.0/16","198.18.0.0/15","198.51.100.0/24","203.0.113.0/24",
        "224.0.0.0/4","240.0.0.0/4",
        "fc00::/7","fe80::/10"
      ];

      {
        log: { level:"info", timestamp:true, output:"/tmp/sb-shunt.log" },

        dns: {
          independent_cache: true,
          servers: dns_servers,
          rules: dns_rules
        },

        inbounds: [
          { type:"redirect", tag:"redir-in", listen:"0.0.0.0", listen_port:$redir_port },
          { type:"direct",   tag:"dns-in",   listen:"0.0.0.0", listen_port:$dns_port }
        ],

        outbounds:
          (nodes + [
            { type:"direct", tag:"direct" },
            { type:"block",  tag:"block"  },
            { type:"dns",    tag:"dns-out" },

            { type:"urltest", tag:"auto",
              outbounds: node_tags,
              url:"http://www.gstatic.com/generate_204",
              interval:"5m",
              tolerance: 50
            },

            { type:"selector", tag:"proxy",
              outbounds: (["auto"] + node_tags),
              default: $proxy_default,
              interrupt_exist_connections: true
            }
          ]),

        route: {
          rule_set: (rs_common + rs_ads),
          rules:
            ([
              { ip_cidr: private_cidrs, outbound:"direct" }
            ]
            + (if $mode=="2" then [ { rule_set:["geosite-ads"], outbound:"block" } ] else [] end)
            + [
              { rule_set:["geoip-cn","geosite-cn"], outbound:"direct" }
            ]),
          final:"proxy"
        },

        experimental:
          (if $api_enable=="1" then
            {
              cache_file: { enabled:true, path:"/etc/sb-shunt/cache.db" },
              clash_api:
                (
                  {
                    external_controller: ($api_listen + ":" + $api_port),
                    secret: $api_secret
                  }
                  + (if $panel_enable=="1" then
                      {
                        external_ui: $ui_dir,
                        external_ui_download_url: $ui_dl_url
                      }
                    else {} end)
                )
            }
          else
            { cache_file: { enabled:true, path:"/etc/sb-shunt/cache.db" } }
          end)
      }
    ' >"$OUT_FILE" || return 1

  [ -s "$OUT_FILE" ] || { echo "[ERR] 生成的 config.json 为空：$OUT_FILE"; return 1; }
  jq -e '.' "$OUT_FILE" >/dev/null 2>&1 || { echo "[ERR] config.json 不是合法 JSON"; return 1; }

  echo "[OK] 生成配置成功：$OUT_FILE"
  return 0
}
