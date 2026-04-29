#!/usr/bin/env bash
# ========================================================
# Credit Code By FN Project
# Mod By : Mousevpn
# License: This configuration is licensed for personal or internal use only.
#          Redistribution, resale, or reuse of this code in any form
#          without explicit written permission from the author is prohibited.
#          Selling this code or its derivatives is strictly forbidden.
# ========================================================

# Define Hosting
# Set to this fork's raw URL so the xray + httpupgrade assets bundled in this
# repo (config.json, nginx.conf, main.zip) are actually deployed onto the VPS.
# The previous upstream (mousethain/rere) still hosts the v2ray-era assets
# without httpupgrade inbounds / locations, which silently breaks the
# httpupgrade transport even though the install.sh logic has been migrated.
hosting="https://raw.githubusercontent.com/SukiSuki40/rere/main/file"

if [ -f "/usr/local/etc/xray/domain" ]; then
echo "Script Already Installed"
exit 1
fi

if [ -f "/usr/local/etc/v2ray/domain" ]; then
echo "Script Already Installed"
exit 1
fi

if [ -f "/etc/xray/domain" ]; then
echo "Script Already Installed"
exit 1
fi

if [ -f "/etc/v2ray/domain" ]; then
echo "Script Already Installed"
exit 1
fi

if [ -f "/root/domain" ]; then
echo "Script Already Installed"
exit 1
fi

clear
echo -e "\e[33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "$green          Input Domain              	$NC"
echo -e "\e[33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
read -p " Input Your SubDomain : " domain

clear

# Resolv
echo -e "nameserver 1.1.1.1" >> /etc/resolv.conf

# Memperbaiki Port Default Login SSH
cd /etc/ssh
find . -type f -name "*sshd_config*" -exec sed -i 's|#Port 22|Port 22|g' {} +
echo -e "Port 3303" >> sshd_config
echo -e "Port 109" >> sshd_config
cd
systemctl daemon-reload
systemctl restart ssh
systemctl restart sshd

# Non Interactive
export DEBIAN_FRONTEND=noninteractive
apt update

# Pakcage
apt install curl wget gnupg openssl -y
apt install jq -y
apt install perl -y
apt install sudo -y
apt install screen -y
apt install socat -y
apt install util-linux -y
apt install lsb-release -y
apt install bsdmainutils -y
apt install iptables -y
apt install iptables-persistent -y
apt install binutils -y
apt install python -y
apt install python2 -y
apt install python3 -y
apt install zip -y
apt install unzip -y
apt install bc -y

# Setup Banner SSH
sed -i '/^#\?Banner /c\Banner /etc/issue.net' /etc/ssh/sshd_config
rm -f /etc/issue.net
wget -O /etc/issue.net "${hosting}/issue.net"
chmod +x /etc/issue.net
systemctl daemon-reload
systemctl restart ssh
systemctl restart sshd

# Installasi Dropbear
apt install dropbear -y
rm /etc/default/dropbear
clear
# RSA
rm -f /etc/dropbear/dropbear_rsa_host_key
dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key

# DSS (DSA)
rm -f /etc/dropbear/dropbear_dss_host_key
dropbearkey -t dss -f /etc/dropbear/dropbear_dss_host_key

# ECDSA
rm -f /etc/dropbear/dropbear_ecdsa_host_key
dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key
cat>  /etc/default/dropbear << END
# All configuration by FN Project / Rerechan02
# Dinda Putri Cindyani
# disabled because OpenSSH is installed
# change to NO_START=0 to enable Dropbear
NO_START=0
# the TCP port that Dropbear listens on
DROPBEAR_PORT=111

# any additional arguments for Dropbear
#DROPBEAR_EXTRA_ARGS="-p 109 -p 69 "

# specify an optional banner file containing a message to be
# sent to clients before they connect, such as "/etc/issue.net"
DROPBEAR_BANNER="/etc/issue.net"

# RSA hostkey file (default: /etc/dropbear/dropbear_rsa_host_key)
DROPBEAR_RSAKEY="/etc/dropbear/dropbear_rsa_host_key"

# DSS hostkey file (default: /etc/dropbear/dropbear_dss_host_key)
#DROPBEAR_DSSKEY="/etc/dropbear/dropbear_dss_host_key"

# ECDSA hostkey file (default: /etc/dropbear/dropbear_ecdsa_host_key)
DROPBEAR_ECDSAKEY="/etc/dropbear/dropbear_ecdsa_host_key"

# Receive window size - this is a tradeoff between memory and
# network performance
DROPBEAR_RECEIVE_WINDOW=65536
END
echo "/bin/false" >> /etc/shells
echo "/usr/sbin/nologin" >> /etc/shells
clear
systemctl daemon-reload
/etc/init.d/dropbear restart
clear

# Save Data IP
curl -s http://checkip.amazonaws.com > /root/.ip

# Special SSLH + stunnel (untuk SSH SSL/TLS)
echo 'sslh   sslh/inetd_or_standalone select standalone' | sudo debconf-set-selections
apt update -y
apt install sslh -y
apt install stunnel4 -y

# Main Menu
cd /usr/local/sbin
wget -O m.zip "${hosting}/main.zip"
unzip m.zip
chmod +x *
rm -f m.zip

# Patch port info di add-ssh / add-ssh-gege supaya cocok dengan
# arsitektur edge-mux (SSH Direct + SSH SSL/TLS multiport).
RERE_HOSTING="https://raw.githubusercontent.com/sugengagung2020-maker/rere/main/file"
wget -q -O /tmp/patch-menu-ports.sh "${RERE_HOSTING}/patch-menu-ports.sh" \
    && bash /tmp/patch-menu-ports.sh /usr/local/sbin \
    || echo "[install] WARNING: gagal apply patch-menu-ports.sh (skip)"
rm -f /tmp/patch-menu-ports.sh

# Stoping HTTP
systemctl stop apache2
systemctl disable apache2

# Setup SSLH (config-file mode) + sslh-internal (post-TLS protocol dispatcher)
#
# Arsitektur (mendukung inject bug-host: SNI = bug, Host = bug, address = domain):
#
#   Public 443/80 -> iptables -> sslh-public (2443/2081) [multiplex SSH/TLS/HTTP/SOCKS5]
#                                   |
#                                   tls -> stunnel:1015 [TLS termination, cert=xray]
#                                                |
#                                                v
#                                          sslh-internal:8444 [HTTP/SSH probe]
#                                                |--- HTTP -> nginx:2080 -> xray
#                                                +--- SSH  -> OpenSSH:22
#                                   ssh -> OpenSSH:22 (SSH direct di 443/80)
#                                   http -> nginx:2080 (HUP NTLS / WS NTLS)
#                                   socks5 -> Dante:1080
#
# Note: SNI-based routing tidak dipakai (gagal untuk inject klien yang pakai
# SNI = bug-host yang sama untuk xray dan SSH SSL). Semua TLS diterminasi
# dulu oleh stunnel, baru protokolnya dideteksi (HTTP vs SSH) oleh
# sslh-internal.
mkdir -p /etc/sslh /var/run/sslh
cat > /etc/default/sslh <<'EOF'
# Managed by sugengagung2020-maker/rere installer.
# Mode: config file (sslh-select).
RUN=yes
DAEMON=/usr/sbin/sslh-select
DAEMON_OPTS="-F /etc/sslh/sslh.cfg"
EOF
chmod 644 /etc/default/sslh

# sslh-public: multiplex SSH/TLS/HTTP/SOCKS5 di port publik (via iptables)
cat > /etc/sslh/sslh.cfg <<'EOF'
verbose: false;
foreground: false;
inetd: false;
numeric: false;
transparent: false;
timeout: 2;
user: "sslh";
pidfile: "/var/run/sslh/sslh.pid";

listen:
(
    { host: "0.0.0.0"; port: "2443"; },
    { host: "0.0.0.0"; port: "2081"; }
);

protocols:
(
    { name: "ssh";    host: "127.0.0.1"; port: "22";   probe: "builtin"; },
    { name: "tls";    host: "127.0.0.1"; port: "1015"; probe: "builtin"; },
    { name: "socks5"; host: "127.0.0.1"; port: "1080"; probe: "builtin"; },
    { name: "http";   host: "127.0.0.1"; port: "2080"; probe: "builtin"; }
);
EOF
chmod 644 /etc/sslh/sslh.cfg

# sslh-internal: post-TLS dispatcher (HTTP -> nginx, SSH -> OpenSSH).
# Catatan: package sslh 1.20-1 di Ubuntu 20.04 punya bug - flag '-F file'
# diabaikan dan selalu baca /etc/sslh/sslh.cfg. Untuk hindari konflik
# dengan sslh-public, sslh-internal pakai CLI flags (bukan config file).
cat > /etc/systemd/system/sslh-internal.service <<'EOF'
[Unit]
Description=SSLH internal post-TLS protocol dispatcher (HTTP/SSH)
Documentation=https://github.com/sugengagung2020-maker/rere
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/sbin/sslh --foreground --user sslh -p 127.0.0.1:8444 --ssh 127.0.0.1:22 --http 127.0.0.1:2080 --anyprot 127.0.0.1:22 -t 2
KillMode=process
Restart=on-failure
RestartSec=5
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

# Setup Rest Api
cd /usr/local/sbin/api
chmod +x *
cd
wget -O /usr/bin/server "${hosting}/server"
chmod +x /usr/bin/server
cat> /etc/systemd/system/server.service << END
[Unit]
Description=WebAPI Server Proxy All OS By Rerechan02
Documentation=https://github.com/Rerechan-Team
After=syslog.target network-online.target

[Service]
User=root
NoNewPrivileges=true
ExecStart=/usr/bin/server
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
END
mkdir -p /etc/api

# Setup Proxy SSHWS
cd /usr/local/bin
wget -O proxy "${hosting}/proxy"
chmod +x proxy
cd
echo -e "[Unit]
Description=WebSocket
Documentation=https://github.com/DindaPutriFN
After=syslog.target network-online.target

[Service]
User=root
NoNewPrivileges=true
ExecStart=/usr/local/bin/proxy
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target" > /etc/systemd/system/proxy.service

# Setup Socks5 Proxy
sudo apt install dante-server curl -y
sudo touch /var/log/danted.log
sudo chown root:root /var/log/danted.log
primary_interface=$(ip route | grep default | awk '{print $5}')
sudo bash -c "cat <<EOF > /etc/danted.conf
logoutput: /var/log/danted.log
internal: 0.0.0.0 port = 1080
external: $primary_interface
method: username
user.privileged: root
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}
EOF"
sudo sed -i '/\[Service\]/a ReadWriteDirectories=/var/log' /usr/lib/systemd/system/danted.service
sudo systemctl daemon-reload
sudo systemctl restart danted
sudo systemctl enable danted

# Setup Nginx
apt install nginx -y
rm -f /etc/nginx/nginx.conf
wget -O /etc/nginx/nginx.conf "${hosting}/nginx.conf"
sed -i "s|server_name fn.com;|server_name $domain;|" /etc/nginx/nginx.conf

systemctl stop nginx
systemctl disable nginx

# Setup Badvpn
wget -O /usr/local/bin/badvpn "https://raw.githubusercontent.com/powermx/badvpn/master/badvpn-udpgw" &>/dev/null
chmod +x /usr/local/bin/badvpn
echo -e "[Unit]
Description=BadVPN Gaming Support Port 7300 By FN Project
Documentation=https://t.me/fn_project
After=syslog.target network-online.target

[Service]
User=root
NoNewPrivileges=true
ExecStart=/usr/local/bin/badvpn --listen-addr 127.0.0.1:7300 --max-clients 1000 --max-connections-for-client 1000 --client-socket-sndbuf 0 --udp-mtu 9000
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target" > /etc/systemd/system/badvpn.service
systemctl daemon-reload
systemctl enable badvpn
systemctl start badvpn
systemctl restart badvpn

# Setup UDP Custom
rm -rf /etc/udp
mkdir -p /etc/udp
echo downloading udp-custom
wget "${hosting}/udp-custom-linux-amd64" -O /etc/udp/udp-custom
chmod +x /etc/udp/udp-custom
echo downloading default config
wget "${hosting}/udp.json" -O /etc/udp/config.json
chmod 644 /etc/udp/config.json
cat <<EOF > /etc/systemd/system/udp-custom.service
[Unit]
Description=UDP Custom by ePro Dev. Team and modify by FN Project

[Service]
User=root
Type=simple
ExecStart=/etc/udp/udp-custom server -exclude 7300
WorkingDirectory=/etc/udp/
Restart=always
RestartSec=2s

[Install]
WantedBy=default.target
EOF
echo start service udp-custom
systemctl start udp-custom &>/dev/null
echo enable service udp-custom
systemctl enable udp-custom &>/dev/null

# Cron
apt install cron -y
echo -e "
*/15 * * * * root echo -n > /var/log/xray/access.log
*/15 * * * * root xp
0 0,1,3,5,6,9,11,12,13,15,17,18,21,23 * * * root backup
" >> /etc/crontab
systemctl daemon-reload
systemctl restart cron

# ===== Setup Xray ======
# Check if the group 'nobody' exists
if getent group nobody > /dev/null; then
    echo "Group 'nobody' already exists."
else
    echo "Group 'nobody' does not exist. Creating..."
    groupadd nobody
fi

# Check if the user 'nobody' exists
if getent passwd nobody > /dev/null; then
    echo "User 'nobody' already exists."
else
    echo "User 'nobody' does not exist. Creating..."
    useradd -g nobody -M -s /sbin/nologin nobody
fi
# Install Xray-core (XTLS) — supports vmess/vless/trojan over ws, grpc, httpupgrade
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
mkdir -p /usr/local/etc/xray
mkdir -p /var/log/xray
touch /var/log/xray/access.log /var/log/xray/error.log
chown -R nobody:nogroup /var/log/xray 2>/dev/null || chown -R nobody:nobody /var/log/xray 2>/dev/null || true
rm -f /usr/local/etc/xray/config.json
wget -O /usr/local/etc/xray/config.json "${hosting}/config.json"

# Setup NoobzVPNS
clear
mkdir -p /etc/noobzvpns
cd /etc/noobzvpns
rm -fr *
wget -O config.toml "${hosting}/config.toml"
wget -q -O /usr/bin/noobzvpns "https://github.com/noobz-id/noobzvpns/raw/master/noobzvpns.x86-64"
chmod +x /usr/bin/noobzvpns
echo -e "[Unit]
Description=NoobzVpn-Server
Wants=network-online.target
After=network.target network-online.target

[Service]
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
User=root
Type=simple
TimeoutStopSec=1
LimitNOFILE=infinity
ExecStart=/usr/bin/noobzvpns start-server

[Install]
WantedBy=multi-user.target
" > /etc/systemd/system/noobzvpns.service
chmod +x /etc/noobzvpns/*
cd

# Certificate
iptables -t nat -D PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 2080
echo -e "${domain}" > /usr/local/etc/xray/domain
    rm -rf /root/.acme.sh
    mkdir /root/.acme.sh
    curl https://acme-install.netlify.app/acme.sh -o /root/.acme.sh/acme.sh
    chmod +x /root/.acme.sh/acme.sh
    /root/.acme.sh/acme.sh --upgrade --auto-upgrade
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    /root/.acme.sh/acme.sh --issue -d $domain --standalone -k ec-256
    ~/.acme.sh/acme.sh --installcert -d $domain --fullchainpath /usr/local/etc/xray/xray.crt --keypath /usr/local/etc/xray/xray.key --ecc

# ===== Setup stunnel: TLS termination utk SEMUA traffic TLS =====
# Stunnel terima TLS di 127.0.0.1:1015 (dari sslh-public), terminasi pakai
# cert xray, lalu forward bytes plain ke sslh-internal:8444 yang akan
# deteksi protokol HTTP vs SSH dan rute ke nginx:2080 atau OpenSSH:22.
# Pendekatan ini bekerja untuk pola "inject bug-host" (SNI = bug, sama
# untuk xray dan SSH SSL).
mkdir -p /etc/stunnel /var/run
cat > /etc/stunnel/ssh-ssl.conf <<'EOF'
foreground = no
setuid = root
setgid = root
pid = /var/run/stunnel-ssh.pid
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[edge-mux]
accept = 127.0.0.1:1015
connect = 127.0.0.1:8444
cert = /usr/local/etc/xray/xray.crt
key = /usr/local/etc/xray/xray.key
client = no
EOF
chmod 644 /etc/stunnel/ssh-ssl.conf

cat > /etc/systemd/system/stunnel-ssh.service <<'EOF'
[Unit]
Description=Stunnel TLS termination -> sslh-internal (HTTP/SSH dispatch)
Documentation=https://github.com/sugengagung2020-maker/rere
After=network-online.target ssh.service sshd.service sslh-internal.service
Wants=network-online.target

[Service]
Type=forking
ExecStart=/usr/bin/stunnel4 /etc/stunnel/ssh-ssl.conf
PIDFile=/var/run/stunnel-ssh.pid
Restart=on-failure
RestartSec=5
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

# Backup Setup
curl https://rclone.org/install.sh | bash
printf "q\n" | rclone config
rm -fr /root/.config/rclone/rclone.conf
cat > /root/.config/rclone/rclone.conf <<EOL
[rerechan]
type = drive
scope = drive
use_trash = false
metadata_owner = read,write
metadata_permissions = read,write
metadata_labels = read,write
token = {"access_token":"ya29.a0AZYkNZgbRJZcQjDt_mqZ6fyNmTfWkQYc8mzf6SyfR0Wk16YR3RUCuQf4hMol3izLaj43Q1R85EqCKNO0yrY2igEuactxcaZPhscBz1UJM8HhO5VT05Om4wG96mdVT4iyPQJ91vnIjr6tGMFGc6Ieh1-N4aYKOc-4dqY4xp0JaCgYKARcSARESFQHGX2MikSBSmHt3K5WTimMhqcm8jQ0175","token_type":"Bearer","refresh_token":"1//0gy_QhkW2lmAaCgYIARAAGBASNwF-L9Ircw-lb7lBdaev_Pq_ml4hZcnSJ1r4mHs3jnj4HFZ7e6a2RQPLAsJa1DBuHesE4MkVRbg","expiry":"2025-04-13T02:20:19.628115625Z"}


EOL
cd /root

# Service NoobzVPN
systemctl daemon-reload
systemctl enable noobzvpns
systemctl start noobzvpns

# Enable & Start Service
systemctl daemon-reload
pkill sslh 2>/dev/null || true
# Force-purge any legacy v2ray service
systemctl disable --now v2ray 2>/dev/null || true
systemctl enable xray
systemctl enable nginx
systemctl enable sslh
systemctl enable sslh-internal
systemctl enable stunnel-ssh
systemctl restart xray
systemctl restart nginx
systemctl restart sslh-internal
systemctl restart sslh
systemctl restart stunnel-ssh
systemctl enable proxy
systemctl start proxy
systemctl restart proxy

# ===== IP Tables Main Port

# Redirect TCP 443 ke TCP 2443
iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 2443

# Redirect UDP 443 ke UDP 36712
iptables -t nat -A PREROUTING -p udp --dport 443 -j REDIRECT --to-port 36712

# Redirect TCP 80 ke TCP 2081 (sslh listener kedua: SSH direct/SSL + HTTP -> nginx)
iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 2081

# Redirect UDP 80 ke UDP 26712
iptables -t nat -A PREROUTING -p udp --dport 80 -j REDIRECT --to-port 36712

iptables-save > /etc/iptables/rules.v4

clear
rm -f /root/*

# ===== Auto-run refresh-hup =====
# Pastikan inbound HTTPUpgrade (/vless-hup, /vmess-hup, /trojan-hup) sudah
# terpasang dan service xray + nginx sudah disinkronkan. Untuk fresh install
# dari fork ini, config.json dan nginx.conf sudah membawa HUP, sehingga
# refresh-hup akan mendeteksi state tersebut dan tidak memodifikasi config
# lagi (idempotent). Tujuan utamanya: user tidak perlu lagi menjalankan
# `bash <(curl -sL ...refresh-hup.sh)` secara manual setelah install.
echo "[install] Memverifikasi HTTPUpgrade inbound (auto refresh-hup)..."
if ! bash <(curl -fsSL "${hosting}/refresh-hup.sh"); then
    echo "[install] WARNING: refresh-hup gagal dijalankan otomatis."
    echo "[install] Install tetap dianggap selesai. Jika diperlukan, jalankan manual:"
    echo "[install]   bash <(curl -sL ${hosting}/refresh-hup.sh)"
fi

echo "v0.0" > /etc/current_version
echo "   ✓ Versi lokal ditetapkan ke v0.0. Sistem siap untuk update berikutnya."
echo -e "menu" >> /root/.profile
clear
echo -e "Success Install"
exit 1
