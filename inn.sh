#!/bin/bash

# 检查是否为root用户
if [ "$(id -u)" != "0" ]; then
    echo "此脚本必须以root权限运行" 1>&2
    exit 1
fi

STATUS_FILE="/tmp/install_status.txt"
rm -f $STATUS_FILE

echo "###########################################"
echo "# 配置两个x-ui与Caddy自动证书续签      #"
echo "###########################################"

while true; do
    read -p "准备好安装请按y，否则按q退出: " choice
    case $choice in
        [Yy]* ) break;;
        [Qq]* ) exit;;
        * ) echo "请输入y或q。";;
    esac
done

error_exit() {
    echo "错误发生，但脚本将继续执行..."
}

check_step_done() {
    grep -q "$1" $STATUS_FILE
}

mark_step_done() {
    echo "$1" >> $STATUS_FILE
}

if ! check_step_done "update_and_install"; then
    apt update -y || error_exit
    apt install -y curl wget socat || error_exit
    mark_step_done "update_and_install"
fi

if ! check_step_done "setup_bbr"; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf || error_exit
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf || error_exit
    sysctl -p || error_exit
    lsmod | grep bbr || error_exit
    mark_step_done "setup_bbr"
fi

if ! check_step_done "install_xui"; then
    bash <(curl -Ls https://raw.githubusercontent.com/vaxilu/x-ui/master/install.sh) || error_exit
    mark_step_done "install_xui"
fi

if ! check_step_done "install_caddy"; then
    apt install -y vim curl debian-keyring debian-archive-keyring apt-transport-https || error_exit
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg || error_exit
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list || error_exit
    apt update -y || error_exit
    apt install -y caddy || error_exit
    mark_step_done "install_caddy"
fi

if ! check_step_done "install_go"; then
    apt install -y golang-go || error_exit
    apt remove -y golang-go || error_exit
    if [ "$(uname -m)" == "x86_64" ]; then
        wget https://go.dev/dl/go1.22.5.linux-amd64.tar.gz || error_exit
        rm -rf /usr/local/go && tar -C /usr/local -xzf go1.22.5.linux-amd64.tar.gz || error_exit
    else
        wget https://go.dev/dl/go1.22.5.linux-arm64.tar.gz || error_exit
        rm -rf /usr/local/go && tar -C /usr/local -xzf go1.22.5.linux-arm64.tar.gz || error_exit
    fi
    echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
    source ~/.bashrc
    go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest || error_exit
    ~/go/bin/xcaddy build --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive || error_exit
    mv caddy /usr/bin/ || error_exit
    mark_step_done "install_go"
fi

rm -f $STATUS_FILE

# 获取用户输入
read -p "请输入第一个域名: " domain1
read -p "请输入第一个x-ui实例的用户名: " username1
read -s -p "请输入第一个x-ui实例的密码: " password1
echo
read -p "请输入第二个域名: " domain2
read -p "请输入第二个x-ui实例的用户名: " username2
read -s -p "请输入第二个x-ui实例的密码: " password2
echo

# 配置第一个 x-ui 实例
mkdir -p /opt/x-ui1
cd /opt/x-ui1
wget https://github.com/sunfsh/x-ui/releases/download/v0.0.9/x-ui-linux-amd64.tar.gz
tar -zxvf x-ui-linux-amd64.tar.gz
./x-ui install
echo -e "listen: ':8400'\nadmin: { listen: ':8401', username: '$username1', password: '$password1' }" > config.json
./x-ui restart

# 配置第二个 x-ui 实例
mkdir -p /opt/x-ui2
cd /opt/x-ui2
wget https://github.com/sunfsh/x-ui/releases/download/v0.0.9/x-ui-linux-amd64.tar.gz
tar -zxvf x-ui-linux-amd64.tar.gz
./x-ui install
echo -e "listen: ':8500'\nadmin: { listen: ':8501', username: '$username2', password: '$password2' }" > config.json
./x-ui restart

# 更新 Caddyfile
cat <<EOF > /etc/caddy/Caddyfile
# 第一个 x-ui 实例
$domain1 {
    tls me@gmail.com
    reverse_proxy / http://localhost:8400
}

# 第二个 x-ui 实例
$domain2 {
    tls me@gmail.com
    reverse_proxy / http://localhost:8500
}
EOF

# 重新加载 Caddy 配置
systemctl restart caddy
