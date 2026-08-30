#!/bin/sh
#
# Frps 一键安装、DNS API 证书管理与 frpx 控制面板脚本
# 支持系统: Alpine Linux / Ubuntu / Debian / CentOS / RHEL
# 特性: 完美适配 NAT VPS（无 80/443 端口），支持 DNS-01 泛域名申请
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误: 该脚本必须以 root 用户运行！${PLAIN}"
    exit 1
fi

INIT_SYSTEM="unknown"
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    INIT_SYSTEM="systemd"
elif command -v rc-service >/dev/null 2>&1; then
    INIT_SYSTEM="openrc"
fi

install_dependencies() {
    echo -e "${YELLOW}--> 正在安装基础依赖...${PLAIN}"
    if command -v apk >/dev/null 2>&1; then
        apk update
        apk add --no-cache curl tar socat openssl ca-certificates shadow
        rc-update add crond default 2>/dev/null || true
        rc-service crond start 2>/dev/null || true
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -y
        apt-get install -y curl tar socat cron openssl ca-certificates
        systemctl enable cron 2>/dev/null || true
        systemctl start cron 2>/dev/null || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl tar socat crontabs openssl ca-certificates
        systemctl enable crond 2>/dev/null || true
        systemctl start crond 2>/dev/null || true
    fi
}

get_latest_frp_info() {
    echo -e "${YELLOW}--> 正在获取 Frp 最新版本信息...${PLAIN}"
    FRP_VERSION=$(curl -s "https://api.github.com/repos/fatedier/frp/releases/latest" | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/' || echo "")
    if [ -z "$FRP_VERSION" ]; then
        FRP_VERSION="0.58.1"
    fi

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) FRP_ARCH="amd64" ;;
        aarch64|arm64) FRP_ARCH="arm64" ;;
        armv7l|armv6l) FRP_ARCH="arm" ;;
        i386|i686)     FRP_ARCH="386" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
    esac
}

prompt_user_config() {
    echo -e "\n${GREEN}================== Frps 基础参数配置 ==================${PLAIN}"
    
    printf "请输入 Frp 绑定端口 [默认: 7000]: "
    read -r BIND_PORT
    BIND_PORT=${BIND_PORT:-7000}

    DEFAULT_TOKEN=$(openssl rand -hex 8)
    printf "请输入连接 Token [默认随机: %s]: " "$DEFAULT_TOKEN"
    read -r AUTH_TOKEN
    AUTH_TOKEN=${AUTH_TOKEN:-$DEFAULT_TOKEN}

    printf "请输入 vhost HTTP 端口 [NAT机请填写映射端口, 默认: 80]: "
    read -r VHOST_HTTP_PORT
    VHOST_HTTP_PORT=${VHOST_HTTP_PORT:-80}

    printf "请输入 vhost HTTPS 端口 [NAT机请填写映射端口, 默认: 443]: "
    read -r VHOST_HTTPS_PORT
    VHOST_HTTPS_PORT=${VHOST_HTTPS_PORT:-443}

    printf "请输入 Dashboard 端口 [默认: 7500]: "
    read -r DASHBOARD_PORT
    DASHBOARD_PORT=${DASHBOARD_PORT:-7500}

    printf "请输入 Dashboard 用户名 [默认: admin]: "
    read -r DASHBOARD_USER
    DASHBOARD_USER=${DASHBOARD_USER:-admin}

    DEFAULT_DASH_PWD=$(openssl rand -hex 6)
    printf "请输入 Dashboard 密码 [默认随机: %s]: " "$DEFAULT_DASH_PWD"
    read -r DASHBOARD_PWD
    DASHBOARD_PWD=${DASHBOARD_PWD:-$DEFAULT_DASH_PWD}

    echo -e "\n${GREEN}================== SSL 证书自动申请 ==================${PLAIN}"
    printf "是否需要配置/申请 SSL 证书? (y/n) [默认: y]: "
    read -r ENABLE_SSL
    ENABLE_SSL=${ENABLE_SSL:-y}

    DOMAIN_NAME=""
    DNS_TYPE=""
    case "$ENABLE_SSL" in
        [Yy]*)
            while true; do
                printf "请输入主域名 (例如 example.com，将同时签发 *.example.com): "
                read -r DOMAIN_NAME
                if [ -n "$DOMAIN_NAME" ]; then break; fi
                echo -e "${RED}域名不能为空！${PLAIN}"
            done

            printf "请输入通知邮箱 [例如: admin@%s]: " "$DOMAIN_NAME"
            read -r SSL_EMAIL
            SSL_EMAIL=${SSL_EMAIL:-"admin@$DOMAIN_NAME"}

            echo -e "\n请选择证书申请验证模式:"
            echo -e " ${GREEN}1.${PLAIN} Cloudflare DNS API (推荐, 免80/443端口, 支持泛域名)"
            echo -e " ${GREEN}2.${PLAIN} 阿里云 DNS API (Aliyun AccessKey)"
            echo -e " ${GREEN}3.${PLAIN} 腾讯云 DNSPod API (Tencent Cloud API)"
            echo -e " ${GREEN}4.${PLAIN} 独立 80 端口验证 (需要公网开放80端口)"
            printf "请选择 [1-4, 默认 1]: "
            read -r DNS_CHOICE
            DNS_CHOICE=${DNS_CHOICE:-1}

            case "$DNS_CHOICE" in
                1)
                    DNS_TYPE="dns_cf"
                    printf "请输入 Cloudflare API Token (需具备 DNS:Edit 权限): "
                    read -r CF_Token_IN
                    export CF_Token="$CF_Token_IN"
                    ;;
                2)
                    DNS_TYPE="dns_ali"
                    printf "请输入 阿里云 AccessKey ID: "
                    read -r Ali_Key_IN
                    printf "请输入 阿里云 AccessKey Secret: "
                    read -r Ali_Secret_IN
                    export Ali_Key="$Ali_Key_IN"
                    export Ali_Secret="$Ali_Secret_IN"
                    ;;
                3)
                    DNS_TYPE="dns_dp"
                    printf "请输入 DNSPod SecretId: "
                    read -r DP_Id_IN
                    printf "请输入 DNSPod SecretKey: "
                    read -r DP_Key_IN
                    export DP_Id="$DP_Id_IN"
                    export DP_Key="$DP_Key_IN"
                    ;;
                4)
                    DNS_TYPE="standalone"
                    ;;
                *)
                    DNS_TYPE="dns_cf"
                    ;;
            esac
            ;;
        *)
            ENABLE_SSL="n"
            ;;
    esac
}

setup_ssl_certificate() {
    echo -e "${YELLOW}--> 正在初始化 acme.sh 并申请证书...${PLAIN}"
    mkdir -p /etc/frp/ssl
    
    if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
        curl -sL https://get.acme.sh | sh -s email="$SSL_EMAIL"
    fi

    ACME_BIN="$HOME/.acme.sh/acme.sh"
    "$ACME_BIN" --set-default-ca --server letsencrypt

    if [ "$INIT_SYSTEM" = "openrc" ]; then
        RELOAD_CMD="rc-service frps restart"
    else
        RELOAD_CMD="systemctl restart frps"
    fi

    if [ "$DNS_TYPE" = "standalone" ]; then
        echo -e "${YELLOW}--> 正在临时释放 80 端口以完成验证...${PLAIN}"
        if [ "$INIT_SYSTEM" = "openrc" ]; then rc-service frps stop 2>/dev/null || true; else systemctl stop frps 2>/dev/null || true; fi
        "$ACME_BIN" --issue -d "$DOMAIN_NAME" --standalone --httpport 80 --force
    else
        echo -e "${YELLOW}--> 使用 DNS API (${DNS_TYPE}) 进行 TXT 验证，申请泛域名证书...${PLAIN}"
        "$ACME_BIN" --issue --dns "$DNS_TYPE" -d "$DOMAIN_NAME" -d "*.$DOMAIN_NAME" --force
    fi

    if [ $? -ne 0 ]; then
        echo -e "${RED}证书申请遇到错误，请检查 API Key/Token 是否正确或 DNS 解析是否生效！${PLAIN}"
        echo -e "${YELLOW}将继续部署 Frps 基础配置，后续可通过 frpx 重新签发。${PLAIN}"
        return
    fi

    "$ACME_BIN" --install-cert -d "$DOMAIN_NAME" \
        --key-file       "/etc/frp/ssl/${DOMAIN_NAME}.key" \
        --fullchain-file "/etc/frp/ssl/${DOMAIN_NAME}.crt" \
        --reloadcmd      "$RELOAD_CMD"

    echo "$DOMAIN_NAME" > /etc/frp/ssl/current_domain.info
    echo -e "${GREEN}证书申请并安装成功！${PLAIN}"
}

write_frps_config() {
    mkdir -p /etc/frp
    cat > /etc/frp/frps.toml <<EOF
# Frps 基础配置
bindPort = ${BIND_PORT}
auth.token = "${AUTH_TOKEN}"

# Web 穿透端口
vhostHTTPPort = ${VHOST_HTTP_PORT}
vhostHTTPSPort = ${VHOST_HTTPS_PORT}

# Dashboard 配置
webServer.addr = "0.0.0.0"
webServer.port = ${DASHBOARD_PORT}
webServer.user = "${DASHBOARD_USER}"
webServer.password = "${DASHBOARD_PWD}"

# 日志设置
log.to = "/var/log/frps.log"
log.level = "info"
log.maxDays = 7
EOF

    if [ -n "$DOMAIN_NAME" ] && [ -f "/etc/frp/ssl/${DOMAIN_NAME}.crt" ]; then
        cat >> /etc/frp/frps.toml <<EOF

# 证书配置
[transport.tls]
certFile = "/etc/frp/ssl/${DOMAIN_NAME}.crt"
keyFile = "/etc/frp/ssl/${DOMAIN_NAME}.key"
EOF
    fi
}

install_and_configure_frps() {
    echo -e "${YELLOW}--> 正在下载并解压 Frps...${PLAIN}"
    FRP_FILE="frp_${FRP_VERSION}_linux_${FRP_ARCH}"
    DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_FILE}.tar.gz"

    rm -rf /tmp/frp_install && mkdir -p /tmp/frp_install
    curl -sL "$DOWNLOAD_URL" -o /tmp/frp_install/frp.tar.gz
    tar -zxvf /tmp/frp_install/frp.tar.gz -C /tmp/frp_install

    mkdir -p /usr/local/bin /etc/frp
    cp "/tmp/frp_install/${FRP_FILE}/frps" /usr/local/bin/frps
    chmod +x /usr/local/bin/frps
    rm -rf /tmp/frp_install

    echo -e "${YELLOW}--> 正在写入 Frps 配置文件 (/etc/frp/frps.toml)...${PLAIN}"
    write_frps_config

    echo -e "${YELLOW}--> 正在注册并启动守护服务...${PLAIN}"
    if [ "$INIT_SYSTEM" = "openrc" ]; then
        cat > /etc/init.d/frps <<'EOF'
#!/sbin/openrc-run

name="frps"
description="Frp Server Service"
command="/usr/local/bin/frps"
command_args="-c /etc/frp/frps.toml"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"

depend() {
    need net
    after firewall
}
EOF
        chmod +x /etc/init.d/frps
        rc-update add frps default
        rc-service frps restart
    else
        cat > /etc/systemd/system/frps.service <<EOF
[Unit]
Description=Frp Server Service
After=network.target syslog.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c /etc/frp/frps.toml
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable frps
        systemctl restart frps
    fi
}

install_frpx_cli() {
    echo -e "${YELLOW}--> 正在配置 frpx 控制面板命令...${PLAIN}"
    cat > /usr/local/bin/frpx <<'EOF'
#!/bin/sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

INIT_SYS="unknown"
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    INIT_SYS="systemd"
elif command -v rc-service >/dev/null 2>&1; then
    INIT_SYS="openrc"
fi

get_service_status() {
    if [ "$INIT_SYS" = "openrc" ]; then
        rc-service frps status 2>/dev/null | grep -q "started" && echo "${GREEN}运行中${PLAIN}" || echo "${RED}未运行${PLAIN}"
    else
        systemctl is-active --quiet frps && echo "${GREEN}运行中${PLAIN}" || echo "${RED}未运行${PLAIN}"
    fi
}

show_status() {
    clear
    echo -e "${GREEN}================== Frps 服务运行状态 ==================${PLAIN}"
    echo -e "当前状态: $(get_service_status)"
    echo -e "初始化体系: ${CYAN}${INIT_SYS}${PLAIN}"
    echo ""
    if [ -f /etc/frp/frps.toml ]; then
        echo -e "${YELLOW}[当前核心配置参数]:${PLAIN}"
        grep -E 'bindPort|auth.token|vhostHTTPPort|vhostHTTPSPort|webServer.port|webServer.user' /etc/frp/frps.toml || true
    fi
    echo ""
    if [ "$INIT_SYS" = "openrc" ]; then
        rc-service frps status || true
    else
        systemctl status frps --no-pager || true
    fi
    echo -e "${GREEN}======================================================${PLAIN}"
    printf "\n按 Enter 键返回菜单..."
    read -r _
}

change_config() {
    clear
    echo -e "${GREEN}================== 更改 Frps 配置 ==================${PLAIN}"
    if [ ! -f /etc/frp/frps.toml ]; then
        echo -e "${RED}未检测到 /etc/frp/frps.toml 配置文件！${PLAIN}"
        printf "\n按 Enter 键返回菜单..."
        read -r _
        return
    fi

    echo -e "1. 快速修改常用端口与 Token"
    echo -e "2. 使用文本编辑器 (nano/vi) 直接编辑配置文件"
    echo -e "0. 返回主菜单"
    printf "请输入选项 [0-2]: "
    read -r cfg_opt

    case "$cfg_opt" in
        1)
            CUR_BIND=$(grep "^bindPort" /etc/frp/frps.toml | awk '{print $3}')
            CUR_TOKEN=$(grep "^auth.token" /etc/frp/frps.toml | awk -F'"' '{print $2}')
            CUR_HTTP=$(grep "^vhostHTTPPort" /etc/frp/frps.toml | awk '{print $3}')
            CUR_HTTPS=$(grep "^vhostHTTPSPort" /etc/frp/frps.toml | awk '{print $3}')
            CUR_DASH_PORT=$(grep "^webServer.port" /etc/frp/frps.toml | awk '{print $3}')
            CUR_DASH_USER=$(grep "^webServer.user" /etc/frp/frps.toml | awk -F'"' '{print $2}')
            CUR_DASH_PWD=$(grep "^webServer.password" /etc/frp/frps.toml | awk -F'"' '{print $2}')

            printf "Frp 绑定端口 [%s]: " "$CUR_BIND"
            read -r N_BIND; BIND_PORT=${N_BIND:-$CUR_BIND}

            printf "连接 Token [%s]: " "$CUR_TOKEN"
            read -r N_TOKEN; AUTH_TOKEN=${N_TOKEN:-$CUR_TOKEN}

            printf "vhost HTTP 端口 [%s]: " "$CUR_HTTP"
            read -r N_HTTP; VHOST_HTTP_PORT=${N_HTTP:-$CUR_HTTP}

            printf "vhost HTTPS 端口 [%s]: " "$CUR_HTTPS"
            read -r N_HTTPS; VHOST_HTTPS_PORT=${N_HTTPS:-$CUR_HTTPS}

            printf "Dashboard 端口 [%s]: " "$CUR_DASH_PORT"
            read -r N_DP; DASHBOARD_PORT=${N_DP:-$CUR_DASH_PORT}

            printf "Dashboard 用户名 [%s]: " "$CUR_DASH_USER"
            read -r N_DU; DASHBOARD_USER=${N_DU:-$CUR_DASH_USER}

            printf "Dashboard 密码 [%s]: " "$CUR_DASH_PWD"
            read -r N_DPW; DASHBOARD_PWD=${N_DPW:-$CUR_DASH_PWD}

            TLS_BLOCK=$(sed -n '/\[transport.tls\]/,$p' /etc/frp/frps.toml)

            cat > /etc/frp/frps.toml <<EOF
# Frps 基础配置
bindPort = ${BIND_PORT}
auth.token = "${AUTH_TOKEN}"

# Web 穿透端口
vhostHTTPPort = ${VHOST_HTTP_PORT}
vhostHTTPSPort = ${VHOST_HTTPS_PORT}

# Dashboard 配置
webServer.addr = "0.0.0.0"
webServer.port = ${DASHBOARD_PORT}
webServer.user = "${DASHBOARD_USER}"
webServer.password = "${DASHBOARD_PWD}"

# 日志设置
log.to = "/var/log/frps.log"
log.level = "info"
log.maxDays = 7
EOF
            if [ -n "$TLS_BLOCK" ]; then
                echo "" >> /etc/frp/frps.toml
                echo "$TLS_BLOCK" >> /etc/frp/frps.toml
            fi

            echo -e "${YELLOW}--> 正在重启 Frps 服务以应用配置...${PLAIN}"
            if [ "$INIT_SYS" = "openrc" ]; then rc-service frps restart; else systemctl restart frps; fi
            echo -e "${GREEN}配置更新成功并已重启！${PLAIN}"
            ;;
        2)
            EDITOR_BIN="vi"
            if command -v nano >/dev/null 2>&1; then EDITOR_BIN="nano"; fi
            $EDITOR_BIN /etc/frp/frps.toml
            if [ "$INIT_SYS" = "openrc" ]; then rc-service frps restart; else systemctl restart frps; fi
            echo -e "${GREEN}服务已重启。${PLAIN}"
            ;;
        *)
            return
            ;;
    esac
    printf "\n按 Enter 键返回菜单..."
    read -r _
}

cert_menu() {
    clear
    echo -e "${GREEN}================== SSL 证书与 DNS API 管理 ==================${PLAIN}"
    
    CUR_DOM=""
    if [ -f /etc/frp/ssl/current_domain.info ]; then
        CUR_DOM=$(cat /etc/frp/ssl/current_domain.info | tr -d ' \n\r')
    fi

    echo -e "当前绑定主域名: ${CYAN}${CUR_DOM:-未记录}${PLAIN}"
    echo ""
    echo -e " ${GREEN}1.${PLAIN} 查看证书信息与有效期"
    echo -e " ${GREEN}2.${PLAIN} 通过 Cloudflare DNS API 申请/续签 (免80端口, 支持通配符)"
    echo -e " ${GREEN}3.${PLAIN} 通过 阿里云 DNS API 申请/续签"
    echo -e " ${GREEN}4.${PLAIN} 通过 腾讯云 DNSPod API 申请/续签"
    echo -e " ${GREEN}5.${PLAIN} 通过 独立 80 端口验证申请 (仅限公网独立IP机型)"
    echo -e " ${GREEN}0.${PLAIN} 返回主菜单"
    printf "请输入选项 [0-5]: "
    read -r cert_opt

    if [ "$cert_opt" = "1" ]; then
        echo ""
        if [ -n "$CUR_DOM" ] && [ -f "/etc/frp/ssl/${CUR_DOM}.crt" ]; then
            echo -e "${YELLOW}--> 证书信息 (/etc/frp/ssl/${CUR_DOM}.crt):${PLAIN}"
            openssl x509 -in "/etc/frp/ssl/${CUR_DOM}.crt" -noout -issuer -subject -dates
        else
            echo -e "${RED}未找到已安装的有效证书。${PLAIN}"
        fi
        printf "\n按 Enter 键返回菜单..."
        read -r _; return
    elif [ "$cert_opt" = "0" ] || [ -z "$cert_opt" ]; then
        return
    fi

    echo ""
    printf "请输入申请证书的主域名 (例如 example.com) [%s]: " "$CUR_DOM"
    read -r IN_DOM
    REQ_DOM=${IN_DOM:-$CUR_DOM}

    if [ -z "$REQ_DOM" ]; then
        echo -e "${RED}域名不能为空！${PLAIN}"
        printf "\n按 Enter 键返回菜单..."
        read -r _; return
    fi

    printf "请输入通知邮箱 [例如: admin@%s]: " "$REQ_DOM"
    read -r REQ_MAIL
    REQ_MAIL=${REQ_MAIL:-"admin@$REQ_DOM"}

    mkdir -p /etc/frp/ssl
    ACME_BIN="$HOME/.acme.sh/acme.sh"
    if [ ! -f "$ACME_BIN" ]; then
        curl -sL https://get.acme.sh | sh -s email="$REQ_MAIL"
    fi
    "$ACME_BIN" --set-default-ca --server letsencrypt

    RELOAD_CMD="systemctl restart frps"
    if [ "$INIT_SYS" = "openrc" ]; then RELOAD_CMD="rc-service frps restart"; fi

    case "$cert_opt" in
        2)
            printf "请输入 Cloudflare API Token: "
            read -r CF_TOKEN_VAL
            export CF_Token="$CF_TOKEN_VAL"
            echo -e "${YELLOW}--> 正在通过 Cloudflare DNS API 签发泛域名证书...${PLAIN}"
            "$ACME_BIN" --issue --dns dns_cf -d "$REQ_DOM" -d "*.$REQ_DOM" --force
            ;;
        3)
            printf "请输入 阿里云 AccessKey ID: "
            read -r ALI_KEY_VAL
            printf "请输入 阿里云 AccessKey Secret: "
            read -r ALI_SEC_VAL
            export Ali_Key="$ALI_KEY_VAL"
            export Ali_Secret="$ALI_SEC_VAL"
            echo -e "${YELLOW}--> 正在通过 阿里云 DNS API 签发泛域名证书...${PLAIN}"
            "$ACME_BIN" --issue --dns dns_ali -d "$REQ_DOM" -d "*.$REQ_DOM" --force
            ;;
        4)
            printf "请输入 DNSPod SecretId: "
            read -r DP_ID_VAL
            printf "请输入 DNSPod SecretKey: "
            read -r DP_KEY_VAL
            export DP_Id="$DP_ID_VAL"
            export DP_Key="$DP_KEY_VAL"
            echo -e "${YELLOW}--> 正在通过 DNSPod API 签发泛域名证书...${PLAIN}"
            "$ACME_BIN" --issue --dns dns_dp -d "$REQ_DOM" -d "*.$REQ_DOM" --force
            ;;
        5)
            echo -e "${YELLOW}--> 正在释放 80 端口...${PLAIN}"
            if [ "$INIT_SYS" = "openrc" ]; then rc-service frps stop 2>/dev/null || true; else systemctl stop frps 2>/dev/null || true; fi
            "$ACME_BIN" --issue -d "$REQ_DOM" --standalone --httpport 80 --force
            ;;
    esac

    if [ $? -eq 0 ]; then
        "$ACME_BIN" --install-cert -d "$REQ_DOM" \
            --key-file       "/etc/frp/ssl/${REQ_DOM}.key" \
            --fullchain-file "/etc/frp/ssl/${REQ_DOM}.crt" \
            --reloadcmd      "$RELOAD_CMD"

        echo "$REQ_DOM" > /etc/frp/ssl/current_domain.info

        # 更新 frps.toml 中的证书路径
        if ! grep -q "\[transport.tls\]" /etc/frp/frps.toml; then
            cat >> /etc/frp/frps.toml <<EOF

# 证书配置
[transport.tls]
certFile = "/etc/frp/ssl/${REQ_DOM}.crt"
keyFile = "/etc/frp/ssl/${REQ_DOM}.key"
EOF
        else
            sed -i "s|certFile = .*|certFile = \"/etc/frp/ssl/${REQ_DOM}.crt\"|" /etc/frp/frps.toml
            sed -i "s|keyFile = .*|keyFile = \"/etc/frp/ssl/${REQ_DOM}.key\"|" /etc/frp/frps.toml
        fi

        echo -e "${GREEN}证书更新完成！${PLAIN}"
    else
        echo -e "${RED}证书申请失败，请核对 API Key 是否正确或 DNS 记录是否已被托管。${PLAIN}"
    fi

    echo -e "${YELLOW}--> 正在确保 Frps 服务启动...${PLAIN}"
    if [ "$INIT_SYS" = "openrc" ]; then rc-service frps restart; else systemctl restart frps; fi

    printf "\n按 Enter 键返回菜单..."
    read -r _
}

while true; do
    clear
    echo -e "${GREEN}======================================================${PLAIN}"
    echo -e "${CYAN}             Frps 控制面板 (frpx CLI)                 ${PLAIN}"
    echo -e "${GREEN}======================================================${PLAIN}"
    echo -e "服务运行状态: $(get_service_status)"
    echo -e "------------------------------------------------------"
    echo -e " ${GREEN}1.${PLAIN} 查看 Frps 服务状态与日志"
    echo -e " ${GREEN}2.${PLAIN} 更改 Frps 配置参数"
    echo -e " ${GREEN}3.${PLAIN} SSL 证书管理 (DNS API / 泛域名 / 80验证)"
    echo -e "------------------------------------------------------"
    echo -e " ${GREEN}4.${PLAIN} 启动 Frps 服务"
    echo -e " ${GREEN}5.${PLAIN} 停止 Frps 服务"
    echo -e " ${GREEN}6.${PLAIN} 重启 Frps 服务"
    echo -e "------------------------------------------------------"
    echo -e " ${GREEN}0.${PLAIN} 退出面板"
    echo -e "${GREEN}======================================================${PLAIN}"
    printf "请输入选择 [0-6]: "
    read -r choice

    case "$choice" in
        1) show_status ;;
        2) change_config ;;
        3) cert_menu ;;
        4)
            if [ "$INIT_SYS" = "openrc" ]; then rc-service frps start; else systemctl start frps; fi
            echo -e "${GREEN}已发送启动指令${PLAIN}"; sleep 1 ;;
        5)
            if [ "$INIT_SYS" = "openrc" ]; then rc-service frps stop; else systemctl stop frps; fi
            echo -e "${YELLOW}已发送停止指令${PLAIN}"; sleep 1 ;;
        6)
            if [ "$INIT_SYS" = "openrc" ]; then rc-service frps restart; else systemctl restart frps; fi
            echo -e "${GREEN}已发送重启指令${PLAIN}"; sleep 1 ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}输入无效，请重新选择${PLAIN}"; sleep 1 ;;
    esac
done
EOF

    chmod +x /usr/local/bin/frpx
}

print_summary() {
    SERVER_IP=$(curl -s4 ifconfig.me || curl -s4 api.ipify.org || echo "你的服务器IP")
    echo -e "\n${GREEN}================== Frps 安装与部署完成 ==================${PLAIN}"
    echo -e "初始化体系    : ${YELLOW}${INIT_SYSTEM}${PLAIN}"
    echo -e "Frps 绑定端口 : ${YELLOW}${BIND_PORT}${PLAIN}"
    echo -e "认证 Token    : ${YELLOW}${AUTH_TOKEN}${PLAIN}"
    echo -e "HTTP 端口     : ${YELLOW}${VHOST_HTTP_PORT}${PLAIN}"
    echo -e "HTTPS 端口    : ${YELLOW}${VHOST_HTTPS_PORT}${PLAIN}"
    echo -e "Dashboard 地址: ${YELLOW}http://${SERVER_IP}:${DASHBOARD_PORT}${PLAIN}"
    echo -e "Dashboard 账号: ${YELLOW}${DASHBOARD_USER}${PLAIN}"
    echo -e "Dashboard 密码: ${YELLOW}${DASHBOARD_PWD}${PLAIN}"
    
    if [ "$ENABLE_SSL" = "y" ] || [ "$ENABLE_SSL" = "Y" ]; then
        echo -e "绑定主域名    : ${YELLOW}${DOMAIN_NAME}${PLAIN}"
        echo -e "支持泛域名    : ${YELLOW}*.${DOMAIN_NAME}${PLAIN}"
        echo -e "证书路径      : /etc/frp/ssl/${DOMAIN_NAME}.crt"
    fi
    echo -e "配置文件路径  : /etc/frp/frps.toml"
    echo -e "------------------------------------------------------"
    echo -e "控制面板命令  : ${CYAN}frpx${PLAIN} (在终端输入 ${CYAN}frpx${PLAIN} 即可唤出)"
    echo -e "${GREEN}======================================================${PLAIN}\n"
}

main() {
    install_dependencies
    get_latest_frp_info
    prompt_user_config
    if [ "$ENABLE_SSL" = "y" ] || [ "$ENABLE_SSL" = "Y" ]; then
        setup_ssl_certificate
    fi
    install_and_configure_frps
    install_frpx_cli
    print_summary
}

main