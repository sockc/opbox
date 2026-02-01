#!/bin/sh

# ==================================================
# OpenWrt Sing-Box 全能脚本 v2.2
# 修复：自动安装逻辑、增加备用转换源、DNS预检
# ==================================================

# --- 变量定义 ---
SB_PATH="/usr/bin/sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
UI_DIR="${CONFIG_DIR}/ui"
INIT_FILE="/etc/init.d/sing-box"
LOG_FILE="/var/log/sing-box.log"

# Sing-box 版本
SB_VERSION="1.8.11"
# 转换服务器列表
CONVERTER_MAIN="https://api.acl4ssr.cn/sub?target=singbox&config=https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/config/ACL4SSR_Online_Full.ini"
CONVERTER_BACKUP="https://sub.xeton.dev/sub?target=singbox&config=https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/config/ACL4SSR_Online_Full.ini"
YACD_URL="https://github.com/haishanh/yacd/archive/gh-pages.zip"

# --- 颜色 ---
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m'; PLAIN='\033[0m'

log() { echo -e "${GREEN}[INFO] $1${PLAIN}"; }
err() { echo -e "${RED}[ERROR] $1${PLAIN}"; }
warn() { echo -e "${YELLOW}[WARN] $1${PLAIN}"; }

# --- 0. 环境预检 ---
pre_check() {
    # 尝试修复 DNS，防止无法解析域名 (临时改为阿里DNS)
    if ! ping -c 1 -W 1 api.acl4ssr.cn >/dev/null 2>&1; then
        warn "检测到 DNS 解析可能存在问题，尝试临时添加 223.5.5.5 ..."
        echo "nameserver 223.5.5.5" >> /etc/resolv.conf
    fi
}

# --- 1. 依赖与安装 ---
check_dependencies() {
    [ ! -f "/bin/opkg" ] && { err "非 OpenWrt 系统"; exit 1; }
    
    # 检查核心依赖
    pkgs="curl wget ca-certificates unzip jq iptables-mod-tproxy kmod-tun"
    need_update=0
    for p in $pkgs; do
        if ! opkg list-installed | grep -q "^$p"; then
            echo -e "缺少依赖: ${BLUE}$p${PLAIN}"
            need_update=1
        fi
    done

    if [ $need_update -eq 1 ]; then
        log "更新软件源并安装依赖..."
        opkg update
        opkg install $pkgs
        [ $? -ne 0 ] && warn "部分依赖安装失败，尝试继续..."
    fi
}

check_install() {
    # 核心检查：如果文件不存在，强制安装
    if [ ! -f "$SB_PATH" ] || [ ! -f "$INIT_FILE" ]; then
        warn "未检测到 Sing-Box 安装，正在自动安装..."
        install_singbox_bin
        create_service
    fi
}

install_singbox_bin() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  PLATFORM="linux-amd64" ;;
        aarch64) PLATFORM="linux-arm64" ;;
        armv7l)  PLATFORM="linux-armv7" ;;
        *)       err "不支持架构: $ARCH"; exit 1 ;;
    esac

    log "下载 Sing-Box ($PLATFORM)..."
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/sing-box-${SB_VERSION}-${PLATFORM}.tar.gz"
    
    curl -L --retry 3 -o /tmp/sb.tar.gz "$DOWNLOAD_URL"
    if [ $? -ne 0 ]; then err "核心文件下载失败，请检查网络"; exit 1; fi
    
    tar -zxf /tmp/sb.tar.gz -C /tmp/
    mv /tmp/sing-box-${SB_VERSION}-${PLATFORM}/sing-box ${SB_PATH}
    chmod +x ${SB_PATH}
    rm -rf /tmp/sb.tar.gz /tmp/sing-box-*
}

create_service() {
    log "创建系统服务..."
    cat > ${INIT_FILE} <<EOF
#!/bin/sh /etc/rc.common
START=99; STOP=10; USE_PROCD=1
PROG=${SB_PATH}; CONF=${CONFIG_FILE}
start_service() {
    procd_open_instance
    procd_set_param command \$PROG run -c \$CONF
    procd_set_param user root
    procd_set_param limits core="unlimited"
    procd_set_param respawn
    procd_close_instance
    iptables -I FORWARD -o sing-tun -j ACCEPT
    iptables -I FORWARD -i sing-tun -j ACCEPT
}
stop_service() {
    iptables -D FORWARD -o sing-tun -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i sing-tun -j ACCEPT 2>/dev/null
}
EOF
    chmod +x ${INIT_FILE}
    /etc/init.d/sing-box enable
}

# --- 2. 订阅与配置 ---
fix_config_interface() {
    log "适配 OpenWrt Tun 模式..."
    tmp_file=$(mktemp)
    jq 'del(.inbounds) | .inbounds = [{
        "type": "tun", "interface_name": "sing-tun", "inet4_address": "172.19.0.1/30",
        "auto_route": true, "strict_route": true, "stack": "system", "sniff": true
    }]' ${CONFIG_FILE} > $tmp_file && mv $tmp_file ${CONFIG_FILE}
}

import_subscription() {
    mkdir -p ${CONFIG_DIR}
    check_install # 确保已安装

    echo -e " 1. 自动转换 (默认源: acl4ssr)"
    echo -e " 2. 自动转换 (备用源: xeton)"
    echo -e " 3. 直链下载 (Sing-box 格式)"
    read -p " 请选择 [1-3]: " st
    
    API_URL=""
    if [ "$st" == "1" ]; then API_URL="$CONVERTER_MAIN"; fi
    if [ "$st" == "2" ]; then API_URL="$CONVERTER_BACKUP"; fi

    if [ "$st" == "1" ] || [ "$st" == "2" ]; then
        read -p " 粘贴订阅链接: " ul
        [ -z "$ul" ] && return
        safe_link=$(echo "$ul" | sed 's/:/%3A/g;s/\//%2F/g;s/?/%3F/g;s/&/%26/g;s/=/%3D/g')
        FINAL_URL="${API_URL}&url=${safe_link}"
        
        log "正在通过转换服务器获取配置..."
        curl -L -k --retry 2 --connect-timeout 10 -o ${CONFIG_FILE} "$FINAL_URL"
    elif [ "$st" == "3" ]; then
        read -p " 粘贴 JSON 直链: " jl
        curl -L -k -o ${CONFIG_FILE} "$jl"
    fi

    # 验证下载结果
    if [ -s "${CONFIG_FILE}" ] && jq -e . ${CONFIG_FILE} >/dev/null 2>&1; then
        fix_config_interface
        log "✅ 配置导入成功！"
        /etc/init.d/sing-box restart
    else
        err "❌ 配置下载失败或格式错误！"
        echo -e "原因可能是：\n1. 路由器无法连接转换服务器 (DNS错误)\n2. 订阅链接无效\n3. 转换服务器维护中"
        rm -f ${CONFIG_FILE}
    fi
}

# --- 3. 面板管理 ---
manage_panel() {
    check_install
    echo -e " 1. 安装面板 (Yacd)"
    echo -e " 2. 卸载面板 (纯后台)"
    echo -e " 3. 仅开启 API"
    read -p " 选择: " p_op
    
    if [ "$p_op" == "1" ]; then
        mkdir -p ${UI_DIR}
        curl -L -o /tmp/yacd.zip "${YACD_URL}"
        unzip -o -q /tmp/yacd.zip -d /tmp/
        cp -r /tmp/yacd-gh-pages/* ${UI_DIR}/
        rm -rf /tmp/yacd*
        jq '.experimental.clash_api = {"external_controller":"0.0.0.0:9090","external_ui":"'${UI_DIR}'","secret":""}' ${CONFIG_FILE} > ${CONFIG_FILE}.tmp && mv ${CONFIG_FILE}.tmp ${CONFIG_FILE}
        log "面板已安装: http://$(uci get network.lan.ipaddr):9090/ui"
    
    elif [ "$p_op" == "2" ]; then
        rm -rf "${UI_DIR}"
        jq 'del(.experimental.clash_api)' ${CONFIG_FILE} > ${CONFIG_FILE}.tmp && mv ${CONFIG_FILE}.tmp ${CONFIG_FILE}
        log "面板已卸载。"
    
    elif [ "$p_op" == "3" ]; then
        jq '.experimental.clash_api = {"external_controller":"0.0.0.0:9090","secret":""}' ${CONFIG_FILE} > ${CONFIG_FILE}.tmp && mv ${CONFIG_FILE}.tmp ${CONFIG_FILE}
        log "API 已开启 (端口9090)"
    fi
    /etc/init.d/sing-box restart
}

# --- 主菜单 ---
show_menu() {
    pre_check
    clear
    echo -e "${BLUE}=== Sing-Box 全能脚本 v2.2 ===${PLAIN}"
    echo -e " 1. 导入订阅 (含自动安装)"
    echo -e " 2. 面板管理 (安装/卸载/API)"
    echo -e " 3. 强制重装核心"
    echo -e " 4. 服务控制 (启动/停止/日志)"
    echo -e " 0. 退出"
    read -p " 选项: " opt
    
    case "$opt" in
        1) check_dependencies; import_subscription ;;
        2) check_dependencies; manage_panel ;;
        3) install_singbox_bin; create_service ;;
        4) 
           read -p "1.启动 2.停止 3.重启 4.日志 : " s_opt
           case $s_opt in
             1) /etc/init.d/sing-box start ;;
             2) /etc/init.d/sing-box stop ;;
             3) /etc/init.d/sing-box restart ;;
             4) tail -n 20 -f ${LOG_FILE} ;;
           esac
           ;;
        0) exit 0 ;;
        *) echo "无效选项" ;;
    esac
}

if [ "$(id -u)" != "0" ]; then echo "需要 Root"; exit 1; fi
show_menu
