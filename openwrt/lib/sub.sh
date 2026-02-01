#!/bin/sh
. /usr/lib/sb-shunt/lib/common.sh
. /usr/lib/sb-shunt/lib/deps.sh

sub_update_nodes() {
  kind="$1"   # clash | sbox
  src="$2"    # url or local file
  out="$3"    # nodes.json
  tmpdir="/tmp/sb-sub.$$"
  mkdir -p "$tmpdir"

  if [ "$kind" = "clash" ]; then
    ensure_clash2singbox || { rm -rf "$tmpdir"; return 1; }
    cd "$tmpdir" || return 1
    /usr/bin/clash2singbox -url "$src" >/dev/null 2>&1 || /usr/bin/clash2singbox -u "$src" >/dev/null 2>&1 || {
      echo "[ERR] clash2singbox 转换失败"
      rm -rf "$tmpdir"; return 1
    }
    [ -f "$tmpdir/config.json" ] || { echo "[ERR] 未生成 config.json"; rm -rf "$tmpdir"; return 1; }
    f="$tmpdir/config.json"
  else
    f="$tmpdir/sub.json"
    if [ -f "$src" ]; then
      cp -f "$src" "$f"
    else
      dl_to "$src" "$f" || { echo "[ERR] 订阅下载失败"; rm -rf "$tmpdir"; return 1; }
    fi
  fi

  # 兼容：输入可能是 {outbounds:[...]} 或直接是 [...]
  # 兼容：tag 缺失时自动生成 node-<index>
  jq -c '
    def arr:
      if (type=="object") and (.outbounds!=null) then .outbounds
      elif (type=="array") then .
      else [] end;

    arr
    | to_entries
    | map(.value | .tag = (.value.tag // .value.name // ("node-" + (.key|tostring))))
    | map(select(
        (.type!=null)
        and (.type!="direct")
        and (.type!="block")
        and (.type!="dns")
        and (.type!="selector")
        and (.type!="urltest")
        and (.type!="loadbalance")
        and (.type!="group")
      ))
  ' "$f" >"$out" 2>/dev/null || {
    echo "[ERR] 解析订阅失败（jq/内容异常）"
    rm -rf "$tmpdir"; return 1
  }

  n="$(jq -r 'length' "$out" 2>/dev/null || echo 0)"
  case "$n" in ''|*[!0-9]*) n=0;; esac
  if [ "$n" -lt 1 ]; then
    echo "[ERR] 节点为空"
    echo "[DBG] outbounds.type（前30条）："
    jq -r 'if (type=="object" and .outbounds) then .outbounds else . end | .[]?.type' "$f" 2>/dev/null | head -n 30 || true
    rm -rf "$tmpdir"; return 1
  fi

  rm -rf "$tmpdir" >/dev/null 2>&1 || true
  return 0
}
