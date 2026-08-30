cat << 'EOF' > /tmp/install_hy2.sh
#!/bin/bash
set -e

GREEN='\033[032m'
RED='\033[031m'
YELLOW='\033[033m'
BLUE='\033[036m'
PLAIN='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：请使用 root 权限运行此脚本！${PLAIN}"
   exit 1
fi

echo -e "${GREEN}=== Hysteria 2 一键安装程序 (Debian 12/13) ===${PLAIN}"

# 1. 基础依赖检查与安装
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget openssl jq systemd iptables iptables-persistent netfilter-persistent

# 2. 获取系统架构并下载 Hysteria 2 最新二进制
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) HY2_ARCH="amd64" ;;
  aarch64|arm64) HY2_ARCH="arm64" ;;
  armv7*) HY2_ARCH="armv7" ;;
  *) echo -e "${RED}不支持的 CPU 架构: $ARCH${PLAIN}"; exit 1 ;;
esac

echo -e "${YELLOW}正在获取 Hysteria 2 最新版本...${PLAIN}"
LATEST_TAG=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r .tag_name)
if [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]]; then
  LATEST_TAG="app/v2.5.2"
fi
DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/download/${LATEST_TAG}/hysteria-linux-${HY2_ARCH}"

echo -e "${YELLOW}下载并安装 Hysteria (${LATEST_TAG})...${PLAIN}"
curl -Lo /usr/local/bin/hysteria "$DOWNLOAD_URL"
chmod +x /usr/local/bin/hysteria

# 3. 创建必要目录
mkdir -p /etc/hysteria /etc/hysteria/certs

# 4. 收集用户配置信息
echo -e "\n${GREEN}--- 配置自定义参数 ---${PLAIN}"
read -rp "请输入监听端口 (默认: 443): " PORT
PORT=${PORT:-443}

read -rp "是否启用端口跳跃 (Port Hopping)? [Y/n] (默认: y): " ENABLE_HOP
ENABLE_HOP=${ENABLE_HOP:-y}

if [[ "$ENABLE_HOP" =~ ^[Yy]$ ]]; then
    read -rp "请输入端口跳跃范围 (格式: 起始端口:结束端口, 默认: 20000:40000): " HOP_RANGE
    HOP_RANGE=${HOP_RANGE:-20000:40000}
    CLIENT_HOP_RANGE=$(echo "$HOP_RANGE" | tr ':' '-')
else
    HOP_RANGE=""
    CLIENT_HOP_RANGE=""
fi

RANDOM_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
read -rp "请输入连接密码 (默认随机: ${RANDOM_PASS}): " PASSWORD
PASSWORD=${PASSWORD:-$RANDOM_PASS}

read -rp "请输入绑定的自签域名/伪装域名 (默认: bing.com): " SNI_DOMAIN
SNI_DOMAIN=${SNI_DOMAIN:-bing.com}

read -rp "请输入上行带宽 (Mbps, 默认: 100): " UP_MBPS
UP_MBPS=${UP_MBPS:-100}

read -rp "请输入下行带宽 (Mbps, 默认: 500): " DOWN_MBPS
DOWN_MBPS=${DOWN_MBPS:-500}

# 5. 生成自签名证书
echo -e "${YELLOW}正在生成自签名 TLS 证书...${PLAIN}"
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout /etc/hysteria/certs/server.key \
  -out /etc/hysteria/certs/server.crt \
  -subj "/CN=${SNI_DOMAIN}" -days 3650 >/dev/null 2>&1
chmod 644 /etc/hysteria/certs/server.crt
chmod 600 /etc/hysteria/certs/server.key

# 6. 生成配置文件与环境变量
cat << CONFIG_EOF > /etc/hysteria/config.yaml
listen: :${PORT}

tls:
  cert: /etc/hysteria/certs/server.crt
  key: /etc/hysteria/certs/server.key

auth:
  type: password
  password: "${PASSWORD}"

masquerade:
  type: proxy
  proxy:
    url: https://${SNI_DOMAIN}/
    rewriteHost: true

bandwidth:
  up: ${UP_MBPS} mbps
  down: ${DOWN_MBPS} mbps

sniff:
  enable: true
CONFIG_EOF

cat << ENV_EOF > /etc/hysteria/hop.env
HOP_RANGE="${HOP_RANGE}"
CLIENT_HOP_RANGE="${CLIENT_HOP_RANGE}"
UP_MBPS="${UP_MBPS}"
DOWN_MBPS="${DOWN_MBPS}"
ENV_EOF

# 7. 配置 iptables 端口跳跃
if [[ -n "$HOP_RANGE" ]]; then
    echo -e "${YELLOW}正在配置 iptables 端口转发规则...${PLAIN}"
    iptables -t nat -D PREROUTING -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$PORT" 2>/dev/null || true
    ip6tables -t nat -D PREROUTING -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$PORT" 2>/dev/null || true

    iptables -t nat -A PREROUTING -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$PORT"
    ip6tables -t nat -A PREROUTING -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$PORT" 2>/dev/null || true
    netfilter-persistent save >/dev/null 2>&1 || true
fi

# 8. 注册 Systemd 服务
cat << SERVICE_EOF > /etc/systemd/system/hysteria-server.service
[Unit]
Description=Hysteria 2 Server Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
systemctl enable hysteria-server
systemctl restart hysteria-server

# 9. 生成 hyx 交互控制面板
cat << 'HYX_EOF' > /usr/local/bin/hyx
#!/bin/bash

GREEN='\033[032m'
RED='\033[031m'
YELLOW='\033[033m'
BLUE='\033[036m'
PLAIN='\033[0m'

CONFIG_FILE="/etc/hysteria/config.yaml"
ENV_FILE="/etc/hysteria/hop.env"
SERVER_IP=$(curl -s4m 5 https://api.ipify.org || echo "YOUR_SERVER_IP")

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

print_node_links() {
    PORT=$(grep -E '^listen:' "$CONFIG_FILE" | awk '{print $2}' | tr -d ' :')
    PASS=$(grep -E 'password:' "$CONFIG_FILE" | head -n 1 | awk '{print $2}' | tr -d '"')
    SNI=$(grep -E 'url:' "$CONFIG_FILE" | head -n 1 | awk '{print $2}' | sed -E 's|https?://([^/]+)/?|\1|')
    UP=${UP_MBPS:-100}
    DOWN=${DOWN_MBPS:-500}

    echo -e "\n${BLUE}===================== 客户端导入信息 =====================${PLAIN}"
    echo -e "${YELLOW}[1] v2rayN / 通用客户端导入链接 (URI):${PLAIN}"
    echo -e " ${GREEN}hysteria2://${PASS}@${SERVER_IP}:${PORT}/?sni=${SNI}&insecure=1#Hy2_${SERVER_IP}${PLAIN}"

    if [[ -n "$CLIENT_HOP_RANGE" ]]; then
        echo -e "\n${YELLOW}[2] Mihomo / Clash Verge Rev (含端口跳跃 URI 链接):${PLAIN}"
        echo -e " ${GREEN}hysteria2://${PASS}@${SERVER_IP}:${PORT},${CLIENT_HOP_RANGE}/?sni=${SNI}&insecure=1&mport=${PORT},${CLIENT_HOP_RANGE}#Hy2_Hop_${SERVER_IP}${PLAIN}"
        
        echo -e "\n${YELLOW}[3] Mihomo JSON 格式配置 (列表项，逗号后带空格):${PLAIN}"
        echo " - {\"name\": \"Hy2_Hop_${SERVER_IP}\", \"type\": \"hysteria2\", \"server\": \"${SERVER_IP}\", \"ports\": \"${PORT},${CLIENT_HOP_RANGE}\", \"hop-interval\": \"30s\", \"password\": \"${PASS}\", \"sni\": \"${SNI}\", \"skip-cert-verify\": true, \"up\": \"${UP} Mbps\", \"down\": \"${DOWN} Mbps\"}"
    else
        echo -e "\n${YELLOW}[2] Mihomo JSON 格式配置 (列表项，逗号后带空格):${PLAIN}"
        echo " - {\"name\": \"Hy2_${SERVER_IP}\", \"type\": \"hysteria2\", \"server\": \"${SERVER_IP}\", \"port\": ${PORT}, \"password\": \"${PASS}\", \"sni\": \"${SNI}\", \"skip-cert-verify\": true, \"up\": \"${UP} Mbps\", \"down\": \"${DOWN} Mbps\"}"
    fi
    echo -e "${BLUE}===========================================================${PLAIN}"
}

show_status() {
    clear
    echo -e "${BLUE}=========================================${PLAIN}"
    echo -e "${GREEN}       Hysteria 2 管理控制面板          ${PLAIN}"
    echo -e "${BLUE}=========================================${PLAIN}"
    
    if systemctl is-active --quiet hysteria-server; then
        echo -e " 服务状态   : ${GREEN}运行中 (Running)${PLAIN}"
    else
        echo -e " 服务状态   : ${RED}已停止 (Stopped)${PLAIN}"
    fi

    if systemctl is-enabled --quiet hysteria-server 2>/dev/null; then
        echo -e " 开机自启   : ${GREEN}已启用${PLAIN}"
    else
        echo -e " 开机自启   : ${RED}已禁用${PLAIN}"
    fi
    
    PORT=$(grep -E '^listen:' "$CONFIG_FILE" | awk '{print $2}' | tr -d ' :')
    PASS=$(grep -E 'password:' "$CONFIG_FILE" | head -n 1 | awk '{print $2}' | tr -d '"')
    SNI=$(grep -E 'url:' "$CONFIG_FILE" | head -n 1 | awk '{print $2}' | sed -E 's|https?://([^/]+)/?|\1|')
    
    echo -e " 监听端口   : ${YELLOW}${PORT}${PLAIN}"
    if [[ -n "$HOP_RANGE" ]]; then
        echo -e " 端口跳跃   : ${GREEN}已启用 (${HOP_RANGE})${PLAIN}"
    else
        echo -e " 端口跳跃   : ${RED}未启用${PLAIN}"
    fi
    echo -e " 连接密码   : ${YELLOW}${PASS}${PLAIN}"
    echo -e " 伪装SNI    : ${YELLOW}${SNI}${PLAIN}"
    
    print_node_links

    echo " 1. 启动服务"
    echo " 2. 停止服务"
    echo " 3. 重启服务"
    echo " 4. 修改端口与密码"
    echo " 5. 端口跳跃管理 (开启/关闭/修改)"
    echo " 6. 查看实时日志"
    echo " 7. 卸载 Hysteria 2"
    echo " 0. 退出面板"
    echo -e "${BLUE}=========================================${PLAIN}"
}

manage_hopping() {
    PORT=$(grep -E '^listen:' "$CONFIG_FILE" | awk '{print $2}' | tr -d ' :')
    echo -e "\n${YELLOW}--- 端口跳跃设置 ---${PLAIN}"
    echo " 1. 开启/修改 端口跳跃范围"
    echo " 2. 关闭端口跳跃"
    echo " 0. 返回"
    read -rp "请选择: " hop_opt
    case "$hop_opt" in
        1)
            read -rp "请输入端口跳跃范围 (格式: 起始:结束, 默认: 20000:40000): " NEW_RANGE
            NEW_RANGE=${NEW_RANGE:-20000:40000}
            
            if [[ -n "$HOP_RANGE" ]]; then
                iptables -t nat -D PREROUTING -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$PORT" 2>/dev/null || true
                ip6tables -t nat -D PREROUTING -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$PORT" 2>/dev/null || true
            fi
            
            HOP_RANGE="$NEW_RANGE"
            CLIENT_HOP_RANGE=$(echo "$HOP_RANGE" | tr ':' '-')
            iptables -t nat -A PREROUTING -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$PORT"
            ip6tables -t nat -A PREROUTING -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$PORT" 2>/dev/null || true
            netfilter-persistent save >/dev/null 2>&1 || true

            cat << ENV_SAVE > "$ENV_FILE"
HOP_RANGE="${HOP_RANGE}"
CLIENT_HOP_RANGE="${CLIENT_HOP_RANGE}"
UP_MBPS="${UP_MBPS}"
DOWN_MBPS="${DOWN_MBPS}"
ENV_SAVE
            echo -e "${GREEN}端口跳跃规则已更新生效！${PLAIN}"
            sleep 2
            ;;
        2)
            if [[ -n "$HOP_RANGE" ]]; then
                iptables -t nat -D PREROUTING -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$PORT" 2>/dev/null || true
                ip6tables -t nat -D PREROUTING -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$PORT" 2>/dev/null || true
                netfilter-persistent save >/dev/null 2>&1 || true
                HOP_RANGE=""
                CLIENT_HOP_RANGE=""
                cat << ENV_SAVE > "$ENV_FILE"
HOP_RANGE=""
CLIENT_HOP_RANGE=""
UP_MBPS="${UP_MBPS}"
DOWN_MBPS="${DOWN_MBPS}"
ENV_SAVE
                echo -e "${GREEN}端口跳跃已关闭！${PLAIN}"
            else
                echo -e "${YELLOW}未启用端口跳跃。${PLAIN}"
            fi
            sleep 2
            ;;
        *) return ;;
    esac
}

change_config() {
    OLD_PORT=$(grep -E '^listen:' "$CONFIG_FILE" | awk '{print $2}' | tr -d ' :')
    echo -e "\n${YELLOW}--- 修改节点基础配置 ---${PLAIN}"
    read -rp "请输入新端口 (回车保持不变): " NEW_PORT
    read -rp "请输入新密码 (回车保持不变): " NEW_PASS

    if [[ -n "$NEW_PORT" && "$NEW_PORT" != "$OLD_PORT" ]]; then
        sed -i "s/^listen:.*/listen: :${NEW_PORT}/" "$CONFIG_FILE"
        if [[ -n "$HOP_RANGE" ]]; then
            iptables -t nat -D PREROUTING -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$OLD_PORT" 2>/dev/null || true
            ip6tables -t nat -D PREROUTING -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$OLD_PORT" 2>/dev/null || true
            iptables -t nat -A PREROUTING -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$NEW_PORT"
            ip6tables -t nat -A PREROUTING -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$NEW_PORT" 2>/dev/null || true
            netfilter-persistent save >/dev/null 2>&1 || true
        fi
    fi

    if [[ -n "$NEW_PASS" ]]; then
        sed -i "s/password:.*/password: \"${NEW_PASS}\"/" "$CONFIG_FILE"
    fi

    systemctl restart hysteria-server
    echo -e "${GREEN}配置更新完成并已重启服务！${PLAIN}"
    sleep 2
}

uninstall_hy2() {
    read -rp "确定要完全卸载 Hysteria 2 吗？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        PORT=$(grep -E '^listen:' "$CONFIG_FILE" 2>/dev/null | awk '{print $2}' | tr -d ' :' || true)
        if [[ -n "$HOP_RANGE" && -n "$PORT" ]]; then
            iptables -t nat -D PREROUTING -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$PORT" 2>/dev/null || true
            ip6tables -t nat -D PREROUTING -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$PORT" 2>/dev/null || true
            netfilter-persistent save >/dev/null 2>&1 || true
        fi
        systemctl stop hysteria-server
        systemctl disable hysteria-server
        rm -f /etc/systemd/system/hysteria-server.service
        systemctl daemon-reload
        rm -rf /etc/hysteria /usr/local/bin/hysteria /usr/local/bin/hyx
        echo -e "${GREEN}卸载完成！${PLAIN}"
        exit 0
    fi
}

while true; do
    show_status
    read -rp "请选择操作 [0-7]: " choice
    case "$choice" in
        1) systemctl start hysteria-server ;;
        2) systemctl stop hysteria-server ;;
        3) systemctl restart hysteria-server ;;
        4) change_config ;;
        5) manage_hopping ;;
        6) journalctl -u hysteria-server -f ;;
        7) uninstall_hy2 ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效，请重新选择${PLAIN}"; sleep 1 ;;
    esac
done
HYX_EOF

chmod +x /usr/local/bin/hyx

# 10. 安装完成立即打印客户端链接
echo -e "\n${GREEN}======================================================${PLAIN}"
echo -e "${GREEN} Hysteria 2 安装完成！${PLAIN}"
/usr/local/bin/hyx show_links 2>/dev/null || true
echo -e " 随时在终端输入 ${YELLOW}hyx${PLAIN} 即可打开控制面板。"
echo -e "${GREEN}======================================================${PLAIN}"
EOF
bash /tmp/install_hy2.sh
rm -f /tmp/install_hy2.sh