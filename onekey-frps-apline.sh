#!/usr/bin/env bash

# variable
FRP_VERSION=0.68.1
FRP_PATH=/usr/local/frp
SHELL_TYPE=1 #1 for apline, 2 for systemd

checkSystemctl() {
    echo "Checking init system..."
    if command -v systemctl &> /dev/null; then
        SHELL_TYPE=2
    else if command -v rc-service &> /dev/null; then
        SHELL_TYPE=1
    else
        echo "Neither systemctl nor rc-service command found. "
        exit 1
    fi
    echo "Detected init system: $([ $SHELL_TYPE -eq 2 ] && echo 'systemd' || echo 'OpenRC')"
}

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

createSystemdService() {
    if [ -e /etc/systemd/system/frps.service ]; then
        rm /etc/systemd/system/frps.service 
    fi
    #create systemd service file    
cat > /etc/systemd/system/frps.service <<EOL
[Unit]
Description=FRP Server
After=network.target

[Service]
Type=simple
ExecStart=${FRP_PATH}/frps -c ${FRP_PATH}/frps.toml
Restart=always

[Install]
WantedBy=multi-user.target
EOL
    systemctl enable frps.service
    systemctl daemon-reload
    echo "frps service created."
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

install() {
    checkSystemctl
    createDir
    downloadFrps
    createFrpsConfig
    if [ $SHELL_TYPE -eq 2 ]; then
        createSystemdService
        echo "frps setup completed successfully. You can start it with 'systemctl start frps'."
    else if [ $SHELL_TYPE -eq 1 ]; then
        createRcService
        echo "frps setup completed successfully. You can start it with 'rc-service frps start'."
    fi
}

uninstall() {
    if [ $SHELL_TYPE -eq 2 ]; then
        systemctl stop frps.service
        echo "Uninstalling frps..."
        systemctl disable frps.service
        rm -f /etc/systemd/system/frps.service
        rm -rf $FRP_PATH
    else if [ $SHELL_TYPE -eq 1 ]; then
        rc-service frps stop
        echo "Uninstalling frps..."
        rc-update del frps default
        rm -f /etc/init.d/frps
        rm -rf $FRP_PATH
    fi
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