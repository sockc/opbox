#!/bin/sh
. /usr/lib/sb-shunt/lib/common.sh
. /usr/lib/sb-shunt/lib/deps.sh

sub_update_nodes() {
  kind="$1"   # clash | sbox
  src="$2"    # url or local file
  out="$3"    # /etc/sb-shunt/nodes.json
  tmpdir="/tmp/sb-sub.$$"
  mkdir -p "$tmpdir"

  f="$tmpdir/sub.json"

  if [ "$kind" = "clash" ]; then
    ensure_clash2singbox || { echo "[ERR] clash2singbox 不可用"; rm -rf "$tmpdir"; return 1; }
    cd "$tmpdir" || return 1
    /usr/bin/clash2singbox -url "$src" >/dev/null 2>&1 || /usr/bin/clash2singbox -u "$src" >/dev/null 2>&1 || {
      echo "[ERR] clash2singbox 转换失败"
      rm -rf "$tmpdir"; return 1
    }
    [ -f "$tmpdir/config.json" ] || { echo "[ERR] 未生成 config.json"; rm -rf "$tmpdir"; return 1; }
    mv "$tmpdir/config.json" "$f"
  else
    if [ -f "$src" ]; then
      cp -f "$src" "$f"
    else
      dl_to "$src" "$f" || { echo "[ERR] 订阅下载失败"; rm -rf "$tmpdir"; return 1; }
    fi
  fi

  # 1) 验证 JSON
  if ! jq -e '.' "$f" >/dev/null 2>&1; then
    echo "[ERR] 订阅内容不是 JSON（可能被拦截/返回 HTML/空文件）"
    echo "[DBG] 文件头 200 字节："
    head -c 200 "$f" | cat -v; echo
    rm -rf "$tmpdir"; return 1
  fi

  # 2) 识别 outbounds 容器
  ob_kind="$(jq -r '
    if type=="object" and has("outbounds") then (.outbounds|type)
    elif type=="array" then "array"
    else "none" end
  ' "$f" 2>/dev/null)"

  if [ "$ob_kind" = "none" ] || [ -z "$ob_kind" ]; then
    echo "[ERR] 订阅 JSON 中找不到 outbounds"
    echo "[DBG] 顶层 keys："
    jq -r 'keys|join(",")' "$f" 2>/dev/null || true
    rm -rf "$tmpdir"; return 1
  fi

  tmp_nodes="$tmpdir/nodes.json"

  # 3) 抽取节点（兼容老 jq：不使用 IN()）
  jq -c '
    def arr:
      if (type=="object") and (.outbounds!=null) then .outbounds
      elif (type=="array") then .
      else [] end;

    arr
    | to_entries
    | map(
        .value
        + { tag: (.value.tag // .value.name // ("node-" + (.key|tostring))) }
      )
    | map(
        select(
          (.type!=null)
          and (.type!="direct")
          and (.type!="block")
          and (.type!="dns")
          and (.type!="selector")
          and (.type!="urltest")
          and (.type!="loadbalance")
          and (.type!="group")
        )
      )
  ' "$f" >"$tmp_nodes" 2>/dev/null || {
    echo "[ERR] 解析 outbounds 失败（jq/内容异常）"
    rm -rf "$tmpdir"; return 1
  }

  n="$(jq -r 'length' "$tmp_nodes" 2>/dev/null || echo 0)"
  case "$n" in ''|*[!0-9]*) n=0;; esac

  if [ "$n" -lt 1 ]; then
    echo "[ERR] 节点为空"
    echo "[DBG] outbounds 容器类型：$ob_kind"
    echo "[DBG] outbounds 前 3 条（精简）："
    jq -c '
      def arr:
        if (type=="object") and (.outbounds!=null) then .outbounds
        elif (type=="array") then .
        else [] end;
      arr[0:3]
    ' "$f" 2>/dev/null || true

    echo "[DBG] outbounds.type 前 30 条："
    jq -r '
      def arr:
        if (type=="object") and (.outbounds!=null) then .outbounds
        elif (type=="array") then .
        else [] end;
      arr[]? | .type
    ' "$f" 2>/dev/null | head -n 30 || true

    rm -rf "$tmpdir"; return 1
  fi

  mkdir -p "$(dirname "$out")" >/dev/null 2>&1 || true
  mv "$tmp_nodes" "$out"

  rm -rf "$tmpdir" >/dev/null 2>&1 || true
  echo "[OK] 节点导入成功：$n"
  return 0
}
