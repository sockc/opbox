#!/bin/sh

# ==================================================
# OpenWrt Sing-Box 全能管理脚本 v2.1
# 更新：增加卸载面板功能、优化节点选择逻辑说明
# ==================================================

# --- 颜色定义 ---
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
PLAIN='\033[0m'

# --- 变量定义 ---
SB_PATH="/usr/bin/sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
UI_DIR="${CONFIG_DIR}/ui"
INIT_FILE="/etc/init.d/sing-box"
LOG_FILE="/var/log/sing-box.log"

# --- 版本配置 ---
SB_VERSION="1.8.11"
CONVERTER_URL="https://api.acl4ssr.cn/sub?target=singbox&config=https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/config/ACL4SSR_Online_Full.ini"
YACD_URL="https://github.com/haishanh/yacd/archive/gh-pages.zip"

# ==================================================
# 基础函数
# ==================================================

log() { echo -e "${GREEN}[INFO] $1${PLAIN}"; }
err() { echo -e "${RED}[ERROR] $1${PLAIN}"; }
warn() { echo -e "${YELLOW}[WARN] $1${PLAIN}"; }

# 依赖检查
check_dependencies() {
    if ! command -v opkg >/dev/null 2>&1; then
        err "非 OpenWrt 系统，无法运行。"
        exit 1
    fi
    DEPENDENCIES="curl wget ca-certificates unzip jq iptables-mod-tproxy kmod-tun"
    for DEP in $DEPENDENCIES; do
        if ! opkg list-installed | grep -q "^$DEP"; then
            echo -e "安装依赖: ${BLUE}$DEP${PLAIN} ..."
            opkg update >/dev/null 2>&1
            opkg install "$DEP"
        fi
    done
}

# 架构检查
check_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  PLATFORM="linux-amd64" ;;
        aarch64) PLATFORM="linux-arm64" ;;
        armv7l)  PLATFORM="linux-armv7" ;;
        *)       err "不支持的架构: $ARCH"; exit 1 ;;
    esac
}

# ==================================================
# 核心安装
# ==================================================

install_singbox_bin() {
    check_arch
    log "下载 Sing-Box ($PLATFORM)..."
    local DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/sing-box-${SB_VERSION}-${PLATFORM}.tar.gz"
    
    curl -L -o /tmp/sb.tar.gz "$DOWNLOAD_URL"
    if [ $? -ne 0 ]; then err "下载失败"; exit 1; fi
    
    tar -zxf /tmp/sb.tar.gz -C /tmp/
    mv /tmp/sing-box-${SB_VERSION}-${PLATFORM}/sing-box ${SB_PATH}
    chmod +x ${SB_PATH}
    rm -rf /tmp/sb.tar.gz /tmp/sing-box-*
}

create_service() {
    cat > ${INIT_FILE} <<EOF
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1
PROG=${SB_PATH}
CONF=${CONFIG_FILE}

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

# ==================================================
# 配置管理
# ==================================================

fix_config_interface() {
    log "优化配置适配 OpenWrt Tun..."
    tmp_file=$(mktemp)
    jq 'del(.inbounds) | .inbounds = [{
        "type": "tun",
        "interface_name": "sing-tun",
        "inet4_address": "172.19.0.1/30",
        "auto_route": true,
        "strict_route": true,
        "stack": "system",
        "sniff": true
    }]' ${CONFIG_FILE} > $tmp_file && mv $tmp_file ${CONFIG_FILE}
}

import_subscription() {
    mkdir -p ${CONFIG_DIR}
    echo -e " 1. 订阅链接自动转换 (推荐)"
    echo -e " 2. Sing-box JSON 直链"
    read -p "选择: " subtype
    
    if [ "$subtype" == "1" ]; then
        read -p "粘贴订阅链接: " user_link
        [ -z "$user_link" ] && return
        safe_link=$(echo "$user_link" | sed 's/:/%3A/g;s/\//%2F/g;s/?/%3F/g;s/&/%26/g;s/=/%3D/g')
        FINAL_URL="${CONVERTER_URL}&url=${safe_link}"
        curl -L -o ${CONFIG_FILE} "$FINAL_URL"
    elif [ "$subtype" == "2" ]; then
        read -p "粘贴 JSON 直链: " json_link
        curl -L -o ${CONFIG_FILE} "$json_link"
    fi
    
    if jq -e . ${CONFIG_FILE} >/dev/null 2>&1; then
        fix_config_interface
        log "配置导入成功！默认策略为自动选择(URLTest)。"
    else
        err "配置下载或解析失败。"
    fi
}

# ==================================================
# 面板管理 (新增卸载逻辑)
# ==================================================

enable_api_only() {
    # 仅开启 API 不下载面板文件，适合用手机 App 控制
    if [ -f "${CONFIG_FILE}" ]; then
        log "正在开启 API (端口 9090)..."
        tmp_file=$(mktemp)
        # 外部 UI 路径留空，仅开启控制器
        jq '.experimental.clash_api = {
            "external_controller": "0.0.0.0:9090",
            "secret": ""
        }' ${CONFIG_FILE} > $tmp_file && mv $tmp_file ${CONFIG_FILE}
        log "API 已开启。可用手机连接 http://$(uci get network.lan.ipaddr):9090 管理节点。"
    else
        err "请先导入配置。"
    fi
}

install_dashboard() {
    log "正在安装 Yacd 面板..."
    mkdir -p ${UI_DIR}
    curl -L -o /tmp/yacd.zip "${YACD_URL}"
    unzip -o -q /tmp/yacd.zip -d /tmp/
    cp -r /tmp/yacd-gh-pages/* ${UI_DIR}/
    rm -rf /tmp/yacd*
    
    if [ -f "${CONFIG_FILE}" ]; then
        tmp_file=$(mktemp)
        jq '.experimental.clash_api = {
            "external_controller": "0.0.0.0:9090",
            "external_ui": "'${UI_DIR}'",
            "secret": ""
        }' ${CONFIG_FILE} > $tmp_file && mv $tmp_file ${CONFIG_FILE}
        echo -e "${GREEN}面板地址: http://$(uci get network.lan.ipaddr):9090/ui${PLAIN}"
    fi
}

uninstall_dashboard() {
    log "正在卸载 Web 面板..."
    
    # 1. 删除 Web 文件以节省空间
    if [ -d "${UI_DIR}" ]; then
        rm -rf "${UI_DIR}"
        echo -e "Web 文件已删除。"
    else
        echo -e "Web 文件不存在，跳过删除。"
    fi

    # 2. 修改配置文件关闭 API
    if [ -f "${CONFIG_FILE}" ]; then
        tmp_file=$(mktemp)
        # 使用 jq 删除 experimental.clash_api 字段
        jq 'del(.experimental.clash_api)' ${CONFIG_FILE} > $tmp_file && mv $tmp_file ${CONFIG_FILE}
        echo -e "配置文件已更新，API 端口已关闭。"
    fi

    echo -e "${GREEN}面板及 API 已完全卸载。当前为纯自动选路模式。${PLAIN}"
    echo -e "${YELLOW}提示：若需切换节点，请重新安装面板或开启 API。${PLAIN}"
    
    /etc/init.d/sing-box restart
}

# ==================================================
# 菜单
# ==================================================

show_menu() {
    clear
    echo -e "${BLUE}=== OpenWrt Sing-Box 管理脚本 v2.1 ===${PLAIN}"
    echo -e " 1. 安装核心 & 依赖"
    echo -e " 2. 导入订阅 (自动转 Singbox)"
    echo -e "------------------------------------"
    echo -e " 3. 安装 Web 面板 (Yacd)"
    echo -e " 4. 卸载 Web 面板 (纯自动模式)"
    echo -e " 5. 仅开启 API (无面板, 手机App控制)"
    echo -e "------------------------------------"
    echo -e " 6. 启动服务"
    echo -e " 7. 停止服务"
    echo -e " 8. 重启服务"
    echo -e " 9. 查看日志"
    echo -e " 0. 退出"
    read -p " 选项: " num

    case "$num" in
        1) check_dependencies; install_singbox_bin; create_service ;;
        2) check_dependencies; import_subscription; /etc/init.d/sing-box restart ;;
        3) check_dependencies; install_dashboard; /etc/init.d/sing-box restart ;;
        4) check_dependencies; uninstall_dashboard ;;
        5) check_dependencies; enable_api_only; /etc/init.d/sing-box restart ;;
        6) /etc/init.d/sing-box start ;;
        7) /etc/init.d/sing-box stop ;;
        8) /etc/init.d/sing-box restart ;;
        9) tail -n 20 -f ${LOG_FILE} ;;
        0) exit 0 ;;
        *) echo "错误输入" ;;
    esac
}

if [ "$(id -u)" != "0" ]; then echo "需要 Root 权限"; exit 1; fi
show_menu
