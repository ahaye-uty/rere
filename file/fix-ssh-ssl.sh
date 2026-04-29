#!/bin/bash
# ========================================================
# fix-ssh-ssl.sh
#
# Migrasi VPS rere ke arsitektur edge-mux v2 (ALPN-aware, support gRPC):
#
#   Public 443/80 -> iptables -> sslh-public (2443/2081)
#                                   |
#                                   tls -> nginx-stream:8443 [ssl_preread alpn]
#                                            |
#                                            +-- ALPN h2 -> nginx:1013 (TLS+h2 / xray gRPC)
#                                            +-- ALPN h1 -> stunnel:1015 [terminate TLS]
#                                                                |
#                                                                v
#                                                          sslh-internal:8444
#                                                          |-- HTTP -> nginx:2080
#                                                          +-- SSH  -> OpenSSH:22
#                                   ssh -> OpenSSH:22 (SSH direct, raw)
#                                   http -> nginx:2080
#                                   socks5 -> Dante:1080
#
# Dibanding versi sebelumnya (PR #5/#6), ditambah ALPN-based split di nginx-stream
# supaya gRPC (h2) tidak ikut diterminasi oleh stunnel (yang bikin h2 pecah).
# h2 langsung diteruskan ke nginx:1013 untuk TLS+h2 termination.
# Klien inject (SNI=bug-host) tetap jalan karena routing berdasarkan ALPN, bukan SNI.
#
# Cara pakai (di VPS, sebagai root):
#   bash <(curl -sL https://raw.githubusercontent.com/sugengagung2020-maker/rere/main/file/fix-ssh-ssl.sh)
#
# Script idempotent — aman dijalankan berkali-kali.
# ========================================================

set -e

if [ "$(id -u)" != "0" ]; then
    echo "[fix-ssh-ssl] Harus dijalankan sebagai root."
    exit 1
fi

XRAY_DOMAIN_FILE="/usr/local/etc/xray/domain"
if [ ! -f "$XRAY_DOMAIN_FILE" ]; then
    echo "[fix-ssh-ssl] ERROR: $XRAY_DOMAIN_FILE tidak ada. Belum install rere?"
    exit 1
fi
DOMAIN=$(tr -d '[:space:]' < "$XRAY_DOMAIN_FILE")
if [ -z "$DOMAIN" ]; then
    echo "[fix-ssh-ssl] ERROR: domain di $XRAY_DOMAIN_FILE kosong."
    exit 1
fi
echo "[fix-ssh-ssl] Domain terdeteksi: $DOMAIN"

NGINX_CONF=/etc/nginx/nginx.conf
TS=$(date +%s)
BACKUP_DIR="/root/rere-fix-ssh-ssl-backup-$TS"
mkdir -p "$BACKUP_DIR"
[ -f /etc/sslh/sslh.cfg ]              && cp /etc/sslh/sslh.cfg              "$BACKUP_DIR/sslh.cfg"
[ -f /etc/default/sslh ]               && cp /etc/default/sslh               "$BACKUP_DIR/sslh.default"
[ -f /etc/stunnel/ssh-ssl.conf ]       && cp /etc/stunnel/ssh-ssl.conf       "$BACKUP_DIR/stunnel-ssh.conf"
[ -f "$NGINX_CONF" ]                   && cp "$NGINX_CONF"                   "$BACKUP_DIR/nginx.conf"
echo "[fix-ssh-ssl] Backup config lama -> $BACKUP_DIR"

# 1. Pastikan stunnel4 + nginx stream module terpasang
NEED_INSTALL=()
command -v stunnel4 >/dev/null 2>&1 || NEED_INSTALL+=(stunnel4)
dpkg -s libnginx-mod-stream >/dev/null 2>&1 || NEED_INSTALL+=(libnginx-mod-stream)
if [ "${#NEED_INSTALL[@]}" -gt 0 ]; then
    echo "[fix-ssh-ssl] Installing: ${NEED_INSTALL[*]} ..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${NEED_INSTALL[@]}"
fi

NGX_STREAM_MOD="$(ls /usr/lib/nginx/modules/ngx_stream_module.so /usr/share/nginx/modules/ngx_stream_module.so 2>/dev/null | head -n1)"
if [ -z "$NGX_STREAM_MOD" ]; then
    echo "[fix-ssh-ssl] ERROR: ngx_stream_module.so tidak ditemukan setelah install."
    exit 1
fi

# 2. Cleanup nginx.conf: hapus stream/load_module bekas versi lama,
# lalu inject load_module + stream block ALPN-router yang baru.
if [ -f "$NGINX_CONF" ]; then
    # Hapus baris load_module ngx_stream_module.so yang lama
    sed -i '/^load_module .*ngx_stream_module\.so;\?$/d' "$NGINX_CONF"
    # Hapus blok stream { ... } bekas (apapun marker komentarnya: SNI router / ALPN router)
    awk '
        BEGIN { skip=0; depth=0 }
        /^# ===== Stream block \(/  { skip=1; depth=0; next }
        skip==1 {
            if (match($0, /\{/)) depth += gsub(/\{/, "{")
            if (match($0, /\}/)) depth -= gsub(/\}/, "}")
            if (depth <= 0 && /\}/) { skip=0; next }
            next
        }
        { print }
    ' "$NGINX_CONF" > "${NGINX_CONF}.tmp" && mv "${NGINX_CONF}.tmp" "$NGINX_CONF"
fi

# Inject load_module di awal nginx.conf
sed -i "1i load_module ${NGX_STREAM_MOD};\n" "$NGINX_CONF"

# Append stream block ALPN router
cat >> "$NGINX_CONF" <<'EOF'

# ===== Stream block (ALPN router) =====
# h2 (gRPC)         -> nginx:1013 (TLS+h2 termination, xray gRPC)
# h1 / lainnya      -> stunnel:1015 -> sslh-internal -> HTTP/SSH
stream {
    map $ssl_preread_alpn_protocols $rerechan_alpn_upstream {
        ~\bh2\b   127.0.0.1:1013;
        default   127.0.0.1:1015;
    }

    server {
        listen 127.0.0.1:8443;
        ssl_preread on;
        proxy_pass $rerechan_alpn_upstream;
        proxy_connect_timeout 10s;
    }
}
EOF

# 3. Test nginx -t setelah cleanup; auto-revert kalau gagal
echo "[fix-ssh-ssl] Test nginx config setelah cleanup ..."
if ! nginx -t 2>&1; then
    echo "[fix-ssh-ssl] ERROR: nginx -t gagal setelah cleanup. Auto-revert nginx.conf."
    cp "$BACKUP_DIR/nginx.conf" "$NGINX_CONF"
    exit 1
fi

# 4. Re-generate sslh-public config (tls -> stunnel:1015)
mkdir -p /etc/sslh /var/run/sslh

cat > /etc/default/sslh <<'EOF'
# Managed by sugengagung2020-maker/rere fix-ssh-ssl.sh
RUN=yes
DAEMON=/usr/sbin/sslh
DAEMON_OPTS="-F /etc/sslh/sslh.cfg"
EOF
chmod 644 /etc/default/sslh

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
    { name: "tls";    host: "127.0.0.1"; port: "8443"; probe: "builtin"; },
    { name: "socks5"; host: "127.0.0.1"; port: "1080"; probe: "builtin"; },
    { name: "http";   host: "127.0.0.1"; port: "2080"; probe: "builtin"; }
);
EOF
chmod 644 /etc/sslh/sslh.cfg
echo "[fix-ssh-ssl] sslh-public config OK."

# 5. Hapus sslh-internal.cfg yang lama (dari versi sebelumnya yg pakai -F file).
# sslh 1.20-1 di Ubuntu 20.04 mengabaikan flag -F dan selalu baca /etc/sslh/sslh.cfg,
# jadi sslh-internal pakai CLI flags murni.
rm -f /etc/sslh/sslh-internal.cfg

# 6. Generate sslh-internal systemd service (CLI flags, bukan config file)
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
echo "[fix-ssh-ssl] sslh-internal service OK (CLI flags mode)."

# 7. Update stunnel: forward ke sslh-internal (8444), bukan langsung OpenSSH:22
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

# Pastikan systemd unit stunnel-ssh ada
if [ ! -f /etc/systemd/system/stunnel-ssh.service ]; then
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
fi
echo "[fix-ssh-ssl] stunnel config OK (forward ke 8444)."

# 8. Reload + restart semua service terkait
echo "[fix-ssh-ssl] Reload + restart services ..."
systemctl daemon-reload
systemctl enable sslh-internal stunnel-ssh sslh nginx >/dev/null 2>&1 || true

systemctl restart nginx
systemctl restart sslh-internal
systemctl restart stunnel-ssh
systemctl restart sslh

# 9. Sanity check
sleep 2
ALL_GOOD=1
check_listen() {
    local port="$1" label="$2"
    # Cek apakah ada proses listen di port (bind di IP manapun)
    if ss -tlnp 2>/dev/null | grep -qE ":${port}\b"; then
        echo "[fix-ssh-ssl] OK: $label listen di port $port."
    else
        echo "[fix-ssh-ssl] FAIL: $label tidak listen di port $port."
        ALL_GOOD=0
    fi
}
check_listen "2443"  "sslh-public"
check_listen "2081"  "sslh-public"
check_listen "8443"  "nginx-stream (ALPN router)"
check_listen "1013"  "nginx https (TLS+h2)"
check_listen "1015"  "stunnel"
check_listen "8444"  "sslh-internal"
check_listen "2080"  "nginx http (HUP NTLS)"
check_listen "22"    "OpenSSH"

echo
if [ "$ALL_GOOD" = "1" ]; then
    cat <<EOM
[fix-ssh-ssl] SELESAI. Test:

  Xray (semua mode TLS) — di klien (v2rayng/netmod/dll):
      Address : <domain VPS>
      Host    : live.iflix.com   (atau bug-host pilihan)
      SNI     : live.iflix.com
      Path    : /vless-hup atau /vmess-hup atau /trojan-hup (HUP)
                /vless atau /vmess atau /trojan (WS)
      Port    : 443

  SSH SSL via APK inject (HTTP Custom dll) — "SSL only":
      SNI     : live.iflix.com (bebas)
      Address : <domain VPS>:443

  SSH direct: port 443 atau 80, langsung tanpa TLS.

Backup config lama: $BACKUP_DIR
EOM
else
    cat <<EOM
[fix-ssh-ssl] SELESAI dengan WARNING. Cek detail:
    systemctl status sslh sslh-internal stunnel-ssh nginx --no-pager | head -50
    journalctl -u sslh-internal --no-pager -n 30
    journalctl -u stunnel-ssh --no-pager -n 30

Restore manual kalau perlu:
    cp $BACKUP_DIR/nginx.conf /etc/nginx/nginx.conf
    cp $BACKUP_DIR/sslh.cfg /etc/sslh/sslh.cfg
    cp $BACKUP_DIR/stunnel-ssh.conf /etc/stunnel/ssh-ssl.conf
    systemctl restart nginx sslh stunnel-ssh
EOM
fi
