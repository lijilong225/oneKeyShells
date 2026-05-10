echo "Installing frps for Alpine Linux..."
# Download and install frps
wget -qO frps.tar.gz https://github.com/fatedier/frp/releases/download/v0.68.1/frp_0.68.1_linux_amd64.tar.gz
tar -zxvf frps.tar.gz
if [ -e "/usr/local/frps" ]; then
    echo "..."
else
    mkdir -p /usr/local/frps
cp frps /usr/local/frps
chmod +x /usr/local/frps/frps
# Clean up
rm frps.tar.gz
# init frps.toml
cat > /usr/local/frps/frps.toml <<EOL
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
echo "frps installation completed. Configuration file created at /usr/local/frps/frps.toml"
#create systemd service file
cat > /etc/init.d/frps <<EOL
#!/sbin/openrc-run

name="frps"
command="/usr/local/frp/frps"
command_args="-c /usr/local/frp/frps.toml"
pidfile="/run/$RC_SVCNAME.pid"
command_background=true

depend() {
after sshd
}
EOL
chmod +x /etc/init.d/frps
rc-update add frps default
echo "frps service created and added to default runlevel. You can start it with 'rc-service frps start'."
