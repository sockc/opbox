#!/bin/sh
# SB-SHUNT CONFIG.SH v20260202-sb1.8.11-dns-final-atomic

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

  OUT_TMP="${OUT_FILE}.tmp.$$"
  rm -f "$OUT_TMP" 2>/dev/null || true

  jq -n \
    --arg mode "$MODE" \
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

      {
        log: { level:"info", timestamp:true, output:"/tmp/sb-shunt.log" },

        dns: {
          independent_cache: true,
          servers: [
            { tag:"dns_cn",    address:$dns_cn,      detour:"direct" },
            { tag:"dns_proxy", address:$dns_foreign, detour:"proxy"  }
          ],
          rules: [
            # 只有“有条件”的规则；默认走 final，避免 missing conditions
            { rule_set:["geosite-cn"], server:"dns_cn" }
          ],
          final: "dns_proxy"
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
              default: $proxy_default
            }
          ]),

        route: {
          rule_set: (rs_common + rs_ads),
          rules:
            (
              [
                # 让被劫持到 1053 的 DNS 走 dns-out
                { inbound:["dns-in"], outbound:"dns-out" },

                # 私网直连
                { ip_is_private:true, outbound:"direct" }
              ]
              + (if $mode=="2" then [ { rule_set:["geosite-ads"], outbound:"block" } ] else [] end)
              + [
                { rule_set:["geoip-cn","geosite-cn"], outbound:"direct" }
              ]
            ),
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
                      { external_ui: $ui_dir, external_ui_download_url: $ui_dl_url }
                    else {} end)
                )
            }
          else
            { cache_file: { enabled:true, path:"/etc/sb-shunt/cache.db" } }
          end)
      }
    ' >"$OUT_TMP" || { rm -f "$OUT_TMP"; return 1; }

  [ -s "$OUT_TMP" ] || { echo "[ERR] 生成的 config.json 为空"; rm -f "$OUT_TMP"; return 1; }
  jq -e '.' "$OUT_TMP" >/dev/null 2>&1 || { echo "[ERR] config.json 非法"; rm -f "$OUT_TMP"; return 1; }

  mv -f "$OUT_TMP" "$OUT_FILE"
  echo "[OK] 生成配置成功：$OUT_FILE"
  return 0
}
