#!/bin/sh
. /usr/lib/sb-shunt/lib/common.sh
. /usr/lib/sb-shunt/lib/deps.sh

# 输出：nodes.json（数组，每项是一个 outbound，必须含 tag/type）
sub_update_nodes() {
  kind="$1"    # clash | sbox
  src="$2"     # url or local file
  out="$3"     # /etc/sb-shunt/nodes.json
  tmpdir="/tmp/sb-sub.$$"
  mkdir -p "$tmpdir"

  if [ "$kind" = "clash" ]; then
    ensure_clash2singbox

    cd "$tmpdir" || return 1
    # clash2singbox 默认生成/修改 config.json（按其 README 行为）
    # 兼容不同参数名：-url 或 -u
    /usr/bin/clash2singbox -url "$src" >/dev/null 2>&1 || /usr/bin/clash2singbox -u "$src" >/dev/null 2>&1 || {
      echo "[ERR] clash2singbox 转换失败"
      rm -rf "$tmpdir" >/dev/null 2>&1 || true
      return 1
    }

    [ -f "$tmpdir/config.json" ] || {
      echo "[ERR] clash2singbox 未生成 config.json"
      rm -rf "$tmpdir" >/dev/null 2>&1 || true
      return 1
    }

    # 从转换结果中提取“真实节点 outbounds”
    jq -c '
      .outbounds
      | map(select(.tag and .type))
      | map(select(.type | IN("direct","block","dns","selector","urltest","loadbalance","group") | not))
    ' "$tmpdir/config.json" >"$out" || return 1

  else
    # sing-box JSON：支持（1）含 outbounds 的完整片段，（2）直接 array
    f="$tmpdir/sub.json"
    if [ -f "$src" ]; then
      cp -f "$src" "$f"
    else
      dl_to "$src" "$f"
    fi

    jq -c '
      if type=="object" and .outbounds then .outbounds
      elif type=="array" then .
      else [] end
      | map(select(.tag and .type))
      | map(select(.type | IN("direct","block","dns","selector","urltest","loadbalance","group") | not))
    ' "$f" >"$out" || return 1
  fi

  # 基本校验：至少 1 个节点
  n="$(jq 'length' "$out" 2>/dev/null || echo 0)"
  [ "$n" -ge 1 ] || { echo "[ERR] 节点为空"; rm -rf "$tmpdir" >/dev/null 2>&1 || true; return 1; }

  rm -rf "$tmpdir" >/dev/null 2>&1 || true
  return 0
}
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

    jq -c '
      .outbounds
      | map(select(.tag and .type))
      | map(select(.type | IN("direct","block","dns","selector","urltest","loadbalance","group") | not))
    ' "$tmpdir/config.json" >"$out" || { rm -rf "$tmpdir"; return 1; }

  else
    f="$tmpdir/sub.json"
    if [ -f "$src" ]; then
      cp -f "$src" "$f"
    else
      dl_to "$src" "$f" || { rm -rf "$tmpdir"; return 1; }
    fi

    jq -c '
      if type=="object" and .outbounds then .outbounds
      elif type=="array" then .
      else [] end
      | map(select(.tag and .type))
      | map(select(.type | IN("direct","block","dns","selector","urltest","loadbalance","group") | not))
    ' "$f" >"$out" || { rm -rf "$tmpdir"; return 1; }
  fi

  n="$(jq 'length' "$out" 2>/dev/null || echo 0)"
  [ "$n" -ge 1 ] || { echo "[ERR] 节点为空"; rm -rf "$tmpdir"; return 1; }

  rm -rf "$tmpdir" >/dev/null 2>&1 || true
  return 0
}
