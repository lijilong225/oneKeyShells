#!/bin/ash
# ------------------------------------------------------------
#  Alpine Linux 一键安装 OpenList（含国内镜像可选）
#  保存后执行：ash alpine-openlist.sh
# ------------------------------------------------------------
set -e

# 颜色点缀
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

# 1. 确认 root
[ "$(id -u)" -ne 0 ] && { echo -e "${RED}请用 root 运行本脚本${NC}"; exit 1; }

# 2. 选镜像
echo -e "${YELLOW}下载源选择：${NC}"
echo " 1) 国内镜像（hub.fastgit.org）"
echo " 2) 官方 GitHub（可能需代理）"
printf "请输入序号 [1/2]："; read -r SRC
case "$SRC" in
  1) MIRROR="https://hub.fastgit.org" ;;
  2) MIRROR="https://github.com" ;;
  *) echo -e "${RED}无效输入，默认使用国内镜像${NC}"; MIRROR="https://hub.fastgit.org" ;;
esac

# 3. 判断架构
case "$(uname -m)" in
  x86_64) ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  *) echo -e "${RED}暂不支持该架构：$(uname -m)${NC}"; exit 2 ;;
esac

# 4. 装最小依赖
echo -e "${GREEN}>>> 安装依赖...${NC}"
apk add -q wget tar tzdata

# 5. 下载并解压
DL_URL="$MIRROR/OpenListTeam/OpenList/releases/latest/download/openlist-linux-musl-${ARCH}.tar.gz"
INSTALL_DIR="/opt/openlist"
mkdir -p "$INSTALL_DIR"
echo -e "${GREEN}>>> 下载 $DL_URL ${NC}"
wget --progress=bar:force -O- "$DL_URL" | tar -xz -C "$INSTALL_DIR"
chmod +x "$INSTALL_DIR/openlist"

# 6. 首次运行抓初始密码
# -------------------------------------------------
#  首次启动：留日志，成功则自动删，失败保留
# -------------------------------------------------
echo -e "${GREEN}>>> 首次启动（10 秒后自动结束），请留意日志中的密码...${NC}"

TMPLOG=$(mktemp)
# 正常结束（EXIT）时删除临时文件；如果后面触发 ERR 就保留
trap "rm -f '$TMPLOG'" EXIT

timeout 12 "$INSTALL_DIR/openlist" server --data "$INSTALL_DIR/data" >"$TMPLOG" 2>&1
# 立即抓密码
INIT_PWD=$(awk -F'initial password is: ' 'NF>1{print $2; exit}' "$TMPLOG" | awk '{print $1}')

# -------------------------------------------------
#  没抓到密码时的双选菜单（官方命令版）
# -------------------------------------------------
if [ -n "$INIT_PWD" ]; then
    echo -e "${GREEN}已成功获取初始密码${NC}"
else
    echo -e "${RED}未抓到密码${NC}"
    while :; do
        echo "1) 展示日志，自己找密码"
        echo "2) 直接修改密码"
        printf "请选择 [1/2]："; read -r opt
        case "$opt" in
            1) echo -e "${YELLOW}--- 日志开始 ---${NC}"
               cat "$TMPLOG"
               echo -e "${YELLOW}--- 日志结束 ---${NC}"
               break
               ;;
            2) while :; do
                   printf "${YELLOW}请输入新密码（≥8位，输入不显示）：${NC}"
                   read -s NP; echo
                   [ ${#NP} -ge 8 ] && break
                   echo -e "${RED}密码太短，重试${NC}"
               done
               # 官方唯一写法
               if ./openlist admin set "$NP" >/dev/null 2>&1; then
                   INIT_PWD="$NP"
                   echo -e "${GREEN}密码已更新！${NC}"
               else
                   echo -e "${RED}修改失败，请稍后到 Web 端手动修改${NC}"
               fi
               break
               ;;
            *) echo -e "${RED}无效选择，重试${NC}" ;;
        esac
    done
    rm -f "$TMPLOG"
fi





# 7. 写 OpenRC 服务
cat >/etc/init.d/openlist <<'EOF'
#!/sbin/openrc-run
name="OpenList"
command="/opt/openlist/openlist"
command_args="server --data /opt/openlist/data"
directory="/opt/openlist"
command_background="yes"
pidfile="/run/${name}.pid"
depend() { need net; after net; }
EOF
chmod +x /etc/init.d/openlist

# 8. 启停 & 自启
rc-service openlist start
rc-update add openlist default >/dev/null 2>&1

# 9. 结果
echo -e "------------------------------------------------"
echo -e "${GREEN}OpenList 安装完成！${NC}"
# Alpine 的 hostname 没有 -I，用 ip 命令
IP=$(ip -4 route get 1 | head -1 | awk '{print $7}')
LAN_IP=$(ip -4 route get 1 | head -1 | awk '{print $7}')
echo -e "内网访问：http://${LAN_IP}:5244"
echo -e "若需外网访问，请在路由器/NAT上把 5244 端口映射到 ${LAN_IP}:5244"

echo -e "用户名：admin"
echo -e "初始密码：${YELLOW}$INIT_PWD${NC}"
echo -e "------------------------------------------------"
# -------------------------------------------------
# -------------------------------------------------
