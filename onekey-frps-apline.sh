#!/usr/bin/env bash

# variable
FRP_VERSION=0.68.1
FRP_PATH=/usr/local/frp
FRP_Admin_User=admin
FRP_Admin_Password=admin123
FRP_Token=token123

createDir() {
    if [ -e "$FRP_PATH" ]; then
        rm -rf "$FRP_PATH"
    fi
    mkdir -p "$FRP_PATH"
    echo "Created directory: $FRP_PATH"
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
    rm frps.tar.gz
    rm -rf frp_${FRP_VERSION}_linux_amd64
}

createFrpsConfig() {
    # init frps.toml
    cat > ./frps.toml <<EOL
# frps.toml - FRP Server Configuration
bindAddr = "0.0.0.0"
bindPort = 7000
#kcpBindPort = 7000
quicBindPort = 7000

vhostHTTPPort = 80
vhostHTTPSPort = 443
#subDomainHost = 'xxx.com'

transport.maxPoolCount = 2000
transport.tcpMux = true
transport.tcpMuxKeepaliveInterval = 60
transport.tcpKeepalive = 7200
transport.tls.force = false

webServer.addr = "0.0.0.0"
webServer.port = 7500
webServer.user = "admin"
webServer.password = "admin123"
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
    echo "frps service created and added to default runlevel."
}

initFrpsVars() {
    read -p "Enter frps admin username (default: ${FRP_Admin_User}): " input_user
    read -p "Enter frps admin password (default: ${FRP_Admin_Password}): " input_password
    read -p "Enter frps auth token (default: ${FRP_Token}): " input_token

    FRP_Admin_User=${input_user:-$FRP_Admin_User}
    FRP_Admin_Password=${input_password:-$FRP_Admin_Password}
    FRP_Token=${input_token:-$FRP_Token}

    echo "Admin Username: $FRP_Admin_User"
    echo "Admin Password: $FRP_Admin_Password"
    echo "Auth Token: $FRP_Token"
}

install() {
    createDir
    downloadFrps
    initFrpsVars
    createFrpsConfig
    createRcService
}

uninstall() {
    rc-service frps stop
    echo "Uninstalling frps..."
    rc-update del frps default
    rm -f /etc/init.d/frps
    rm -rf $FRP_PATH
    echo "frps uninstalled successfully."
}

# Main menu
echo "choose install frps for Alpine Linux or uninstall."
echo "1) Install frps"
echo "2) Uninstall frps"
read -p "Enter your choice (1/2): " choice
case $choice in
    1)
        install
        ;;
    2)
        uninstall
        ;;
    *)
        echo "Invalid choice."
        ;;
esac