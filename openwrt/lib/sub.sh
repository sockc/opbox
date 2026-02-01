#!/bin/sh
# SB-SHUNT SUB.SH v20260202-fix3-outfile

. /usr/lib/sb-shunt/lib/common.sh
. /usr/lib/sb-shunt/lib/deps.sh

sub_update_nodes() {
  KIND="$1"
  SRC="$2"
  OUTFILE="$3"

  echo "[DBG] sub_update_nodes: KIND=$KIND OUTFILE=$OUTFILE"

  TMPDIR="/tmp/sb-sub.$$"
  mkdir -p "$TMPDIR"
  SUBJSON="$TMPDIR/sub.json"
  NODES_TMP="$TMPDIR/nodes.json"

  if [ "$KIND" = "clash" ]; then
    ensure_clash2singbox || { echo "[ERR] clash2singbox 不可用"; rm -rf "$TMPDIR"; return 1; }
    cd "$TMPDIR" || return 1
    /usr/bin/clash2singbox -url "$SRC" >/dev/null 2>&1 || /usr/bin/clash2singbox -u "$SRC" >/dev/null 2>&1 || {
      echo "[ERR] clash2singbox 转换失败"
      rm -rf "$TMPDIR"; return 1
    }
    [ -f "$TMPDIR/config.json" ] || { echo "[ERR] 未生成 config.json"; rm -rf "$TMPDIR"; return 1; }
    mv "$TMPDIR/config.json" "$SUBJSON"
  else
    if [ -f "$SRC" ]; then
      cp -f "$SRC" "$SUBJSON"
    else
      dl_to "$SRC" "$SUBJSON" || { echo "[ERR] 订阅下载失败"; rm -rf "$TMPDIR"; return 1; }
    fi
  fi

  # JSON 校验
  jq -e '.' "$SUBJSON" >/dev/null 2>&1 || {
    echo "[ERR] 订阅内容不是 JSON"
    echo "[DBG] 文件头 200 字节："
    head -c 200 "$SUBJSON" | cat -v; echo
    rm -rf "$TMPDIR"; return 1
  }

  # 抽取节点（兼容老 jq）
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
  ' "$SUBJSON" >"$NODES_TMP" 2>/dev/null || {
    echo "[ERR] 解析 outbounds 失败"
    rm -rf "$TMPDIR"; return 1
  }

  N="$(jq -r 'length' "$NODES_TMP" 2>/dev/null || echo 0)"
  case "$N" in ''|*[!0-9]*) N=0;; esac
  [ "$N" -ge 1 ] || { echo "[ERR] 节点为空"; rm -rf "$TMPDIR"; return 1; }

  mkdir -p "$(dirname "$OUTFILE")" || true
  cat "$NODES_TMP" >"$OUTFILE" 2>/dev/null || { echo "[ERR] 写入失败：$OUTFILE"; rm -rf "$TMPDIR"; return 1; }
  sync >/dev/null 2>&1 || true

  [ -s "$OUTFILE" ] || { echo "[ERR] 节点文件未落盘：$OUTFILE"; rm -rf "$TMPDIR"; return 1; }

  echo "[OK] 节点导入成功：$N -> $OUTFILE"
  rm -rf "$TMPDIR" >/dev/null 2>&1 || true
  return 0
}
