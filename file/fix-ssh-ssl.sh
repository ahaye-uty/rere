#!/bin/bash
# ========================================================
# fix-ssh-ssl.sh
#
# Fix VPS yang sudah pernah install rere fork ini sebelum stream-mode
# benar-benar bekerja. Script ini idempotent — aman dijalankan
# berkali-kali.
#
# Cara pakai (di VPS, sebagai root):
#   bash <(curl -sL https://raw.githubusercontent.com/sugengagung2020-maker/rere/main/file/fix-ssh-ssl.sh)
#
# Yang dilakukan:
#   1. Install libnginx-mod-stream kalau belum ada.
#   2. Pastikan load_module ngx_stream_module.so ada di nginx.conf
#      (upstream nginx.conf tidak include modules-enabled/, jadi
#      directive 'stream' tidak dikenali tanpa load_module eksplisit).
#   3. Re-generate /etc/sslh/sslh.cfg supaya semua TLS diteruskan ke
#      127.0.0.1:8443 (nginx-stream) — bukan SNI matching di sslh.
#   4. Tambah/replace stream block di nginx.conf:
#        SNI = ${domain}  -> 127.0.0.1:1013 (nginx http TLS, xray)
#        default          -> 127.0.0.1:1015 (stunnel -> OpenSSH:22)
#   5. nginx -t. Kalau gagal -> auto-revert nginx.conf dari backup.
#   6. Restart sslh dan nginx.
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
[ -f /etc/sslh/sslh.cfg ]   && cp /etc/sslh/sslh.cfg   "$BACKUP_DIR/sslh.cfg"
[ -f /etc/default/sslh ]    && cp /etc/default/sslh    "$BACKUP_DIR/sslh.default"
[ -f "$NGINX_CONF" ]        && cp "$NGINX_CONF"        "$BACKUP_DIR/nginx.conf"
echo "[fix-ssh-ssl] Backup config lama -> $BACKUP_DIR"

# 1. Install libnginx-mod-stream
if ! dpkg -s libnginx-mod-stream >/dev/null 2>&1; then
    echo "[fix-ssh-ssl] Installing libnginx-mod-stream ..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y libnginx-mod-stream
else
    echo "[fix-ssh-ssl] libnginx-mod-stream sudah terpasang."
fi

# 2. Cari path module stream
NGX_STREAM_MOD="$(ls /usr/lib/nginx/modules/ngx_stream_module.so /usr/share/nginx/modules/ngx_stream_module.so 2>/dev/null | head -n1)"
if [ -z "$NGX_STREAM_MOD" ]; then
    echo "[fix-ssh-ssl] ERROR: ngx_stream_module.so tidak ditemukan setelah install. Abort."
    exit 1
fi
echo "[fix-ssh-ssl] Stream module path: $NGX_STREAM_MOD"

# 3. Bersihkan stream block & load_module lama (kalau ada) supaya idempotent
if [ -f "$NGINX_CONF" ]; then
    # Hapus baris load_module ngx_stream_module.so yang lama
    sed -i '/^load_module .*ngx_stream_module\.so;\?$/d' "$NGINX_CONF"
    # Hapus blok stream { ... } yang ditandai dengan rerechan_tls_upstream (di-append oleh script ini sebelumnya)
    # Pakai awk untuk hapus dari komentar marker sampai closing brace pertama dengan brace counting
    awk '
        BEGIN { skip=0; depth=0 }
        /^# ===== Stream block \(SNI router/ { skip=1; depth=0; next }
        skip==1 {
            if (match($0, /\{/)) depth += gsub(/\{/, "{")
            if (match($0, /\}/)) depth -= gsub(/\}/, "}")
            if (depth <= 0 && /\}/) { skip=0; next }
            next
        }
        { print }
    ' "$NGINX_CONF" > "${NGINX_CONF}.tmp" && mv "${NGINX_CONF}.tmp" "$NGINX_CONF"
fi

# 4. Prepend load_module di baris paling atas
sed -i "1i load_module ${NGX_STREAM_MOD};\n" "$NGINX_CONF"

# 5. Append stream block baru
cat >> "$NGINX_CONF" <<EOF

# ===== Stream block (SNI router) =====
# Ditambahkan oleh fix-ssh-ssl.sh.
# SNI = ${DOMAIN}        -> 127.0.0.1:1013 (nginx http TLS, xray)
# SNI lain / kosong      -> 127.0.0.1:1015 (stunnel -> OpenSSH:22)
stream {
    map \$ssl_preread_server_name \$rerechan_tls_upstream {
        ${DOMAIN}    127.0.0.1:1013;
        default     127.0.0.1:1015;
    }

    server {
        listen 127.0.0.1:8443;
        ssl_preread on;
        proxy_pass \$rerechan_tls_upstream;
        proxy_connect_timeout 10s;
    }
}
EOF
echo "[fix-ssh-ssl] Stream block + load_module ditambahkan ke $NGINX_CONF."

# 6. Re-generate /etc/sslh/sslh.cfg
mkdir -p /etc/sslh /var/run/sslh

cat > /etc/default/sslh <<'EOF'
# Managed by sugengagung2020-maker/rere fix-ssh-ssl.sh
# Mode: config file (sslh-select)
RUN=yes
DAEMON=/usr/sbin/sslh-select
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
echo "[fix-ssh-ssl] /etc/sslh/sslh.cfg di-regenerate."

# 7. Test config + restart, auto-revert nginx kalau gagal
echo "[fix-ssh-ssl] Test nginx config ..."
if ! nginx -t 2>&1; then
    echo "[fix-ssh-ssl] ERROR: nginx -t gagal. Auto-revert nginx.conf dari backup."
    cp "$BACKUP_DIR/nginx.conf" "$NGINX_CONF"
    systemctl restart nginx || true
    echo "[fix-ssh-ssl] nginx.conf di-revert. Cek detail error di atas."
    exit 1
fi

echo "[fix-ssh-ssl] Restart sslh + nginx ..."
systemctl daemon-reload
systemctl restart nginx
systemctl restart sslh

# Sanity check
sleep 1
ALL_GOOD=1
if ss -tlnp 2>/dev/null | grep -q "127.0.0.1:8443"; then
    echo "[fix-ssh-ssl] OK: nginx-stream listen di 127.0.0.1:8443."
else
    echo "[fix-ssh-ssl] FAIL: 127.0.0.1:8443 tidak listen."
    ALL_GOOD=0
fi
if ss -tlnp 2>/dev/null | grep -q "0.0.0.0:2443"; then
    echo "[fix-ssh-ssl] OK: sslh listen di 0.0.0.0:2443."
else
    echo "[fix-ssh-ssl] FAIL: 0.0.0.0:2443 tidak listen."
    ALL_GOOD=0
fi
if ss -tlnp 2>/dev/null | grep -q "127.0.0.1:1015"; then
    echo "[fix-ssh-ssl] OK: stunnel listen di 127.0.0.1:1015."
else
    echo "[fix-ssh-ssl] WARN: 127.0.0.1:1015 tidak listen (stunnel-ssh mati?). SSH SSL kemungkinan tidak konek."
fi

echo
if [ "$ALL_GOOD" = "1" ]; then
    echo "[fix-ssh-ssl] Selesai. Test:"
    echo "  - Xray HUP TLS via klien existing dengan SNI = $DOMAIN  -> harus konek."
    echo "  - HTTP Custom 'SSL only' + SNI bug bebas (mis. live.iflix.com) port 443 -> harus konek SSH."
else
    echo "[fix-ssh-ssl] Selesai dengan WARNING. Cek 'systemctl status nginx sslh stunnel-ssh' dan log."
fi
