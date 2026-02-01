#!/bin/sh
. /usr/lib/sb-shunt/lib/common.sh
. /usr/lib/sb-shunt/lib/deps.sh

sub_update_nodes() {
  kind="$1"
  src="$2"
  out="$3"
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

  # JSON 校验
  jq -e '.' "$f" >/dev/null 2>&1 || {
    echo "[ERR] 订阅内容不是 JSON（可能返回 HTML/空文件）"
    echo "[DBG] 文件头 200 字节："
    head -c 200 "$f" | cat -v; echo
    rm -rf "$tmpdir"; return 1
  }

  tmp_nodes="$tmpdir/nodes.json"

  # 抽取节点（兼容老 jq，不用 IN()）
  jq -c '
    def arr:
      if (type=="object") and (.outbounds!=null) then .outbounds
      elif (type=="array") then .
      else [] end;

    arr
    | to_entries
    | map(.value + { tag: (.value.tag // .value.name // ("node-" + (.key|tostring))) })
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
  ' "$f" >"$tmp_nodes" 2>/dev/null || {
    echo "[ERR] 解析 outbounds 失败"
    rm -rf "$tmpdir"; return 1
  }

  n="$(jq -r 'length' "$tmp_nodes" 2>/dev/null || echo 0)"
  case "$n" in ''|*[!0-9]*) n=0;; esac
  [ "$n" -ge 1 ] || { echo "[ERR] 节点为空"; rm -rf "$tmpdir"; return 1; }

  # 关键：写入 nodes.json（用 cp，避免 mv 跨分区/失败后文件丢失）
  mkdir -p "$(dirname "$out")" || true
  cp -f "$tmp_nodes" "$out" 2>/dev/null || {
    echo "[ERR] 写入失败：$out"
    rm -rf "$tmpdir"; return 1
  }
  sync >/dev/null 2>&1 || true

  [ -s "$out" ] || {
    echo "[ERR] 节点文件未落盘（为空或不存在）：$out"
    rm -rf "$tmpdir"; return 1
  }

  echo "[OK] 节点导入成功：$n -> $out"
  rm -rf "$tmpdir" >/dev/null 2>&1 || true
  return 0
}
