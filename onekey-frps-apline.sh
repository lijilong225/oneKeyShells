#!/usr/bin/env bash

# variable
FRP_VERSION=0.68.1
FRP_PATH=/usr/local/frp

createDir() {
    if [ ! -d "$FRP_PATH" ]; then
        mkdir -p "$FRP_PATH"
        echo "Created directory: $FRP_PATH"
    else
        rm -rf "$FRP_PATH"
        echo "Directory already exists, cleared: $FRP_PATH"
    fi
    #切换到frp目录
    cd $FRP_PATH
}

downloadFrps() {
    echo "Installing frps for Alpine Linux..."
    # Download and install frps
    wget -qO frps.tar.gz https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_amd64.tar.gz
    if [ -e frps.tar.gz ]; then
        echo "Downloaded frps version ${FRP_VERSION} successfully."
    else
        echo "Failed to download frps version ${FRP_VERSION}."
        exit 1
    fi
    tar -zxvf frps.tar.gz
    cp frp_${FRP_VERSION}_linux_amd64/frps ${FRP_PATH}
    chmod +x ${FRP_PATH}/frps
    # Clean up
    #rm frps.tar.gz
    #rm -rf frp_${FRP_VERSION}_linux_amd64
}

createFrpsConfig() {
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
}

createRcService() {
    if [ -e /etc/init.d/frps ]; then
        echo "frps service already exists. Skipping creation."
        rm /etc/init.d/frps 
    fi
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
}

createDir
downloadFrps
createFrpsConfig
createRcService
echo "frps installation completed. Configuration file created at ${FRP_PATH}/frps.toml"
cd /root

