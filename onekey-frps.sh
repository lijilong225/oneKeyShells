#!/usr/bin/env bash

# variable
FRP_VERSION=0.70.0
FRP_PATH=/usr/local/frp
FRP_Token=token123
# 1: openRc, 2: systemd
SHELL_TYPE=1

fetchLatestFrpVersion() {
    # Fetch the latest frp version from GitHub API
    local latest_version=$(curl -s https://api.github.com/repos/fatedier/frp/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")')
    if [ -n "$latest_version" ]; then
        FRP_VERSION=${latest_version#v}
        echo "Latest frp version detected: $FRP_VERSION"
    else
        echo "Failed to fetch the latest frp version. Using default version: $FRP_VERSION"
    fi
}

checkShellType() {
    if [ -d "/run/openrc" ]; then
        SHELL_TYPE=1
    elif [ -d "/run/systemd" ]; then
        SHELL_TYPE=2
    else
        echo "Unable to detect init system. Please select manually."
        # selectShell
    fi
    echo "Detected init system: $([ $SHELL_TYPE -eq 1 ] && echo "OpenRC" || echo "Systemd")"
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
    echo "Installing frps ..."
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

#vhostHTTPPort = 80
vhostHTTPSPort = 443

auth.method = "token"
auth.token = "${FRP_Token}"
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
    echo "to start frps service, run: rc-service frps start."
}

createSystemdService() {
    if [ -e /etc/systemd/system/frps.service ]; then
        echo "frps service already exists. Skipping creation."
        rm /etc/systemd/system/frps.service
    fi
    #create systemd service file
    cat > /etc/systemd/system/frps.service <<EOL
[Unit]
Description=FRP Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=${FRP_PATH}/frps -c ${FRP_PATH}/frps.toml
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL
    systemctl daemon-reload
    systemctl enable frps.service
    echo "frps service created and enabled."
    echo "to start frps service, run: systemctl start frps.service."
}

initFrpsVars() {
    read -p "Enter frps auth token (default: ${FRP_Token}): " input_token
    FRP_Token=${input_token:-$FRP_Token}
    echo "Auth Token: $FRP_Token"
}

install() {
    createDir
    downloadFrps
    initFrpsVars
    createFrpsConfig
    if [ $SHELL_TYPE -eq 1 ]; then
        createRcService
    elif [ $SHELL_TYPE -eq 2 ]; then
        createSystemdService
    fi
}

uninstall() {
    if [ $SHELL_TYPE -eq 1 ]; then
        rc-service frps stop
        rc-update del frps default
        rm /etc/init.d/frps
    elif [ $SHELL_TYPE -eq 2 ]; then
        systemctl stop frps.service
        systemctl disable frps.service
        rm /etc/systemd/system/frps.service
        systemctl daemon-reload
    fi
    rm -rf $FRP_PATH
    echo "frps uninstalled successfully."
}

# Main menu
fetchLatestFrpVersion
checkShellType
echo "choose install frps or uninstall."
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