#!/bin/sh
. /usr/lib/sb-shunt/lib/common.sh

gen_config() {
  mode="$1"       # 1/2
  nodes_file="$2" # nodes.json
  out="$3"        # config.json

  # 规则集 URL（支持 GH_PREFIX 镜像：例如 https://ghp.ci/https://github.com）
  GH_PREFIX="${GH_PREFIX:-https://github.com}"
  geoip_cn="${GH_PREFIX}/SagerNet/sing-geoip/raw/refs/heads/rule-set/geoip-cn.srs"
  geosite_cn="${GH_PREFIX}/SagerNet/sing-geosite/raw/refs/heads/rule-set/geosite-geolocation-cn.srs"
  geosite_ads="${GH_PREFIX}/SagerNet/sing-geosite/raw/refs/heads/rule-set/geosite-category-ads-all.srs"

  # selector 默认值
  sd="${SELECTOR_DEFAULT:-auto}"

  # API/面板
  api_enable="${API_ENABLE:-0}"
  api_listen="${API_LISTEN:-127.0.0.1}"
  api_port="${API_PORT:-9090}"
  api_secret="${API_SECRET:-}"
  panel_enable="${PANEL_ENABLE:-0}"
  ui_dir="${UI_DIR:-/usr/share/sb-shunt/ui}"
  ui_dl="${UI_DL_URL:-https://github.com/MetaCubeX/Yacd-meta/archive/gh-pages.zip}"

  # 版本分支：1.11+ 使用 sniff/hijack-dns 动作:contentReference[oaicite:1]{index=1}
  if sb_ver_ge "1.11.0"; then
    jq -n \
      --arg mode "$mode" \
      --arg sd "$sd" \
      --arg geoip_cn "$geoip_cn" \
      --arg geosite_cn "$geosite_cn" \
      --arg geosite_ads "$geosite_ads" \
      --arg api_enable "$api_enable" \
      --arg api_listen "$api_listen" \
      --arg api_port "$api_port" \
      --arg api_secret "$api_secret" \
      --arg panel_enable "$panel_enable" \
      --arg ui_dir "$ui_dir" \
      --arg ui_dl "$ui_dl" \
      --slurpfile nodes "$nodes_file" '
      def nodes: $nodes[0];
      def node_tags: (nodes | map(.tag));

      {
        log: { disabled:false, level:"info", timestamp:true, output:"/tmp/sb-shunt.log" },

        dns: {
          servers: [
            { tag:"dns_cn", address:"223.5.5.5", strategy:"ipv4_only", detour:"direct" },
            { tag:"dns_proxy", address:"https://1.1.1.1/dns-query", strategy:"ipv4_only", detour:"proxy" }
          ],
          rules: (
            ( ($mode=="2")
              ? [ { rule_set:["geosite-ads"], action:{ action:"reject", method:"default" } } ]
              : []
            )
            + [ { rule_set:["geosite-cn"], action:{ action:"route", server:"dns_cn" } } ]
          ),
          final: "dns_proxy",
          strategy: "ipv4_only",
          reverse_mapping: true
        },

        inbounds: [
          { type:"redirect", tag:"redir-in", listen:"::", listen_port:12345 },
          { type:"direct", tag:"dns-in", listen:"::", listen_port:1053 }
        ],

        outbounds: (
          [
            { type:"direct", tag:"direct" },
            { type:"block",  tag:"block" },
            { type:"dns",    tag:"dns-out" }
          ]
          + nodes
          + [
            { type:"urltest", tag:"auto",
              outbounds: node_tags,
              url:"http://www.gstatic.com/generate_204",
              interval:"300s", tolerance:50
            },
            { type:"selector", tag:"proxy", default:$sd,
              outbounds: (["auto"] + node_tags)
            }
          ]
        ),

        route: {
          auto_detect_interface: true,
          rule_set: (
            [
              { tag:"geoip-cn", type:"remote", format:"binary", url:$geoip_cn, update_interval:"1d", download_detour:"direct" },
              { tag:"geosite-cn", type:"remote", format:"binary", url:$geosite_cn, update_interval:"1d", download_detour:"direct" }
            ]
            + ( ($mode=="2")
                ? [ { tag:"geosite-ads", type:"remote", format:"binary", url:$geosite_ads, update_interval:"3d", download_detour:"direct" } ]
                : []
              )
          ),
          rules: (
            [
              { inbound:["redir-in"], action:"sniff" },
              { inbound:["dns-in"], action:"hijack-dns" }
            ]
            + ( ($mode=="2")
                ? [ { rule_set:["geosite-ads"], action:"reject" } ]
                : []
              )
            + [
              { rule_set:["geosite-cn","geoip-cn"], action:"route", outbound:"direct" }
            ]
          ),
          final: "proxy"
        },

        experimental: (
          {
            cache_file: { enabled:true, path:"/etc/sb-shunt/cache.db", store_rdrc:true }
          }
          + ( ($api_enable=="1")
              ? {
                  clash_api: (
                    {
                      external_controller: ($api_listen + ":" + $api_port),
                      secret: $api_secret
                    }
                    + ( ($panel_enable=="1")
                        ? { external_ui: $ui_dir, external_ui_download_url: $ui_dl }
                        : {}
                      )
                  )
                }
              : {}
            )
        )
      }' >"$out"
  else
    # 旧版本：inbound sniff + dns-in 路由到 dns-out（兼容老内核）
    jq -n \
      --arg mode "$mode" \
      --arg sd "$sd" \
      --arg geoip_cn "$geoip_cn" \
      --arg geosite_cn "$geosite_cn" \
      --arg geosite_ads "$geosite_ads" \
      --slurpfile nodes "$nodes_file" '
      def nodes: $nodes[0];
      def node_tags: (nodes | map(.tag));

      {
        log: { disabled:false, level:"info", timestamp:true, output:"/tmp/sb-shunt.log" },

        dns: {
          servers: [
            { tag:"dns_cn", address:"223.5.5.5", strategy:"ipv4_only", detour:"direct" },
            { tag:"dns_proxy", address:"https://1.1.1.1/dns-query", strategy:"ipv4_only", detour:"proxy" }
          ],
          rules: (
            ( ($mode=="2") ? [ { rule_set:["geosite-ads"], server:"dns_cn" } ] : [] )
            + [ { rule_set:["geosite-cn"], server:"dns_cn" } ]
          ),
          final: "dns_proxy",
          strategy: "ipv4_only",
          reverse_mapping: true
        },

        inbounds: [
          { type:"redirect", tag:"redir-in", listen:"::", listen_port:12345, sniff:true, sniff_override_destination:true },
          { type:"direct", tag:"dns-in", listen:"::", listen_port:1053 }
        ],

        outbounds: (
          [
            { type:"direct", tag:"direct" },
            { type:"block",  tag:"block" },
            { type:"dns",    tag:"dns-out" }
          ]
          + nodes
          + [
            { type:"urltest", tag:"auto",
              outbounds: node_tags,
              url:"http://www.gstatic.com/generate_204",
              interval:"300s", tolerance:50
            },
            { type:"selector", tag:"proxy", default:$sd,
              outbounds: (["auto"] + node_tags)
            }
          ]
        ),

        route: {
          auto_detect_interface: true,
          rule_set: (
            [
              { tag:"geoip-cn", type:"remote", format:"binary", url:$geoip_cn, update_interval:"1d", download_detour:"direct" },
              { tag:"geosite-cn", type:"remote", format:"binary", url:$geosite_cn, update_interval:"1d", download_detour:"direct" }
            ]
            + ( ($mode=="2")
                ? [ { tag:"geosite-ads", type:"remote", format:"binary", url:$geosite_ads, update_interval:"3d", download_detour:"direct" } ]
                : []
              )
          ),
          rules: (
            ( ($mode=="2") ? [ { rule_set:["geosite-ads"], outbound:"block" } ] : [] )
            + [
              { inbound:["dns-in"], outbound:"dns-out" },
              { rule_set:["geosite-cn","geoip-cn"], outbound:"direct" }
            ]
          ),
          final: "proxy"
        },

        experimental: { cache_file: { enabled:true, path:"/etc/sb-shunt/cache.db", store_rdrc:true } }
      }' >"$out"
  fi
}

