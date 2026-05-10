#!/usr/bin/env bash

# variable
FRP_VERSION=0.68.1
FRP_PATH=/usr/local/frp
#create frps directory if it doesn't exist
if [ -e ${FRP_PATH} ]; then
    rm -rf ${FRP_PATH}
else
    mkdir -p ${FRP_PATH}
fi
echo "Installing frps for Alpine Linux..."
# Download and install frps
wget -qO ${FRP_PATH}/frps.tar.gz https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_amd64.tar.gz
tar -zxvf ${FRP_PATH}/frps.tar.gz
cp ${FRP_PATH}/frp_${FRP_VERSION}_linux_amd64/frps ${FRP_PATH}
chmod +x ${FRP_PATH}/frps
# Clean up
rm ${FRP_PATH}/frps.tar.gz
rm -rf ${FRP_PATH}/frp_${FRP_VERSION}_linux_amd64
# init frps.toml
cat > ${FRP_PATH}/frps.toml <<EOL
# frps.toml - FRP 服务端配置文件
bindAddr = "0.0.0.0"
bindPort = 7000
#UDP 弱网环境下传输效率提升明显
#kcpBindPort = 7000
# QUIC 绑定的是 UDP 端口，可以和 bindPort 一样
quicBindPort = 7000

vhostHTTPPort = 80
#vhostHTTPSPort = 443
#subDomainHost = 'xxx'

transport.maxPoolCount = 2000
transport.tcpMux = true
transport.tcpMuxKeepaliveInterval = 60
transport.tcpKeepalive = 7200
transport.tls.force = false

webServer.addr = "0.0.0.0"
webServer.port = 7500
webServer.user = "longfen"
webServer.password = "123456"
webServer.pprofEnable = false

log.to = "./frps.log"
log.level = "info"
log.maxDays = 3
log.disablePrintColor = false

auth.method = "token"
auth.token = "token123"

allowPorts = [
  { start = 10001, end = 50000 }
]

maxPortsPerClient = 8
udpPacketSize = 1500
natholeAnalysisDataReserveHours = 168
EOL
echo "frps installation completed. Configuration file created at ${FRP_PATH}/frps.toml"
#create systemd service file
cat > /etc/init.d/frps <<EOL
#!/sbin/openrc-run

name="frps"
command="${FRP_PATH}/frps"
command_args="-c ${FRP_PATH}/frps.toml"
pidfile="/run/$RC_SVCNAME.pid"
command_background=true

depend() {
after sshd
}
EOL
chmod +x /etc/init.d/frps
rc-update add frps default
echo "frps service created and added to default runlevel. You can start it with 'rc-service frps start'."
