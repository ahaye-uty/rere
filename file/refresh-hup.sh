#!/bin/bash
# ========================================================
# refresh-hup.sh
#
# Untuk VPS yang sudah pernah di-install dengan rere versi
# v2ray (atau xray tapi belum sempat ke-deploy aset httpupgrade)
# dan ingin meng-aktifkan transport HTTPUpgrade tanpa harus
# install ulang dari nol (akun yang sudah ada tetap aman).
#
# Cara pakai:
#   bash <(curl -sL https://raw.githubusercontent.com/SukiSuki40/rere/main/file/refresh-hup.sh)
#
# Yang dilakukan script ini:
#   1. Backup file penting (config.json, nginx.conf, main.zip lama)
#   2. Re-download main.zip terbaru ke /usr/local/sbin (script menu, add-*, dst.)
#   3. Re-download nginx.conf terbaru, isi server_name dari /usr/local/etc/xray/domain
#   4. Inject 3 inbound HTTPUpgrade (vless port 14, vmess port 15, trojan port 16)
#      ke /usr/local/etc/xray/config.json kalau belum ada, dengan menyalin
#      seluruh client yang sudah terdaftar pada inbound vless/vmess/trojan
#      yang sudah ada (jadi semua user existing langsung kepake juga di HUP).
#   5. Restart xray + nginx
# ========================================================

set -e

HOSTING="https://raw.githubusercontent.com/SukiSuki40/rere/main/file"

echo "[refresh-hup] Mendeteksi lokasi config xray..."
XRAY_DIR="/usr/local/etc/xray"
LEGACY_DIR="/usr/local/etc/v2ray"
if [ ! -f "$XRAY_DIR/config.json" ] && [ -f "$LEGACY_DIR/config.json" ]; then
    echo "[refresh-hup] Memindahkan $LEGACY_DIR -> $XRAY_DIR (legacy v2ray layout terdeteksi)..."
    mkdir -p "$XRAY_DIR"
    cp -a "$LEGACY_DIR/." "$XRAY_DIR/"
fi

# Normalisasi nama file cert: layout v2ray-era memakai v2ray.crt / v2ray.key,
# layout baru memakai xray.crt / xray.key. nginx.conf yang baru cari nama
# xray.* — kalau cuma ada v2ray.* (atau cuma ada xray.*) buatkan duplikat /
# rename supaya kedua nama tersedia. Tidak hapus yang lama supaya rollback
# tidak bricked.
for ext in crt key; do
    if [ -f "$XRAY_DIR/v2ray.$ext" ] && [ ! -f "$XRAY_DIR/xray.$ext" ]; then
        echo "[refresh-hup] Menyalin v2ray.$ext -> xray.$ext"
        cp -a "$XRAY_DIR/v2ray.$ext" "$XRAY_DIR/xray.$ext"
    fi
    if [ -f "$XRAY_DIR/xray.$ext" ] && [ ! -f "$XRAY_DIR/v2ray.$ext" ]; then
        cp -a "$XRAY_DIR/xray.$ext" "$XRAY_DIR/v2ray.$ext" 2>/dev/null || true
    fi
done

CONFIG="$XRAY_DIR/config.json"
DOMAIN_FILE="$XRAY_DIR/domain"

if [ ! -f "$CONFIG" ]; then
    echo "[refresh-hup] ERROR: $CONFIG tidak ditemukan. Apakah rere sudah pernah di-install?"
    exit 1
fi
if [ ! -f "$DOMAIN_FILE" ]; then
    echo "[refresh-hup] ERROR: $DOMAIN_FILE tidak ditemukan, tidak bisa rebuild nginx.conf."
    exit 1
fi
if [ ! -f "$XRAY_DIR/xray.crt" ] || [ ! -f "$XRAY_DIR/xray.key" ]; then
    echo "[refresh-hup] ERROR: $XRAY_DIR/xray.crt atau xray.key tidak ditemukan."
    echo "[refresh-hup]        Cek manual isi $XRAY_DIR (mungkin nama cert beda)."
    exit 1
fi
DOMAIN=$(cat "$DOMAIN_FILE")

TS=$(date +%s)
BACKUP_DIR="/root/rere-refresh-backup-$TS"
mkdir -p "$BACKUP_DIR"
echo "[refresh-hup] Backup ke $BACKUP_DIR"
cp "$CONFIG" "$BACKUP_DIR/config.json" 2>/dev/null || true
cp /etc/nginx/nginx.conf "$BACKUP_DIR/nginx.conf" 2>/dev/null || true
cp "$XRAY_DIR/xray.crt" "$BACKUP_DIR/" 2>/dev/null || true
cp "$XRAY_DIR/xray.key" "$BACKUP_DIR/" 2>/dev/null || true

echo "[refresh-hup] Re-download main.zip ..."
TMP_ZIP=$(mktemp)
wget -q -O "$TMP_ZIP" "$HOSTING/main.zip"
mkdir -p /usr/local/sbin
cd /usr/local/sbin
unzip -oq "$TMP_ZIP"
chmod +x ./* 2>/dev/null || true
[ -d /usr/local/sbin/api ] && chmod +x /usr/local/sbin/api/* 2>/dev/null || true
rm -f "$TMP_ZIP"

# Patch port info di add-ssh / add-ssh-gege ke arsitektur edge-mux
# (sslh-public + stunnel + sslh-internal). Idempotent.
RERE_HOSTING="https://raw.githubusercontent.com/sugengagung2020-maker/rere/main/file"
TMP_PATCH=$(mktemp)
if wget -q -O "$TMP_PATCH" "${RERE_HOSTING}/patch-menu-ports.sh"; then
    bash "$TMP_PATCH" /usr/local/sbin || true
else
    echo "[refresh-hup] WARNING: gagal download patch-menu-ports.sh, skip."
fi
rm -f "$TMP_PATCH"

echo "[refresh-hup] Re-download nginx.conf ..."
wget -q -O /etc/nginx/nginx.conf "$HOSTING/nginx.conf"
sed -i "s|server_name fn.com;|server_name $DOMAIN;|" /etc/nginx/nginx.conf

echo "[refresh-hup] Memastikan log xray tersedia ..."
mkdir -p /var/log/xray
touch /var/log/xray/access.log /var/log/xray/error.log
chmod 644 /var/log/xray/access.log /var/log/xray/error.log

echo "[refresh-hup] Cek apakah inbound HUP sudah ada di config.json ..."
if grep -q '"path": "/vless-hup"' "$CONFIG" \
   && grep -q '"path": "/vmess-hup"' "$CONFIG" \
   && grep -q '"path": "/trojan-hup"' "$CONFIG"; then
    echo "[refresh-hup] Inbound HUP sudah ada, skip patch config.json."
else
    echo "[refresh-hup] Inject inbound HUP ke config.json (preserve akun)..."
    python3 - "$CONFIG" <<'PYEOF'
import re, sys, io

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    text = f.read()

def grab_clients_block(marker):
    """
    Cari salah satu inbound yang punya marker `#vless` / `#vmess` / `#trojan`
    pada baris yang ditandai (placeholder client + tanda), lalu balikkan
    isi `clients` arraynya (string mentah dari `[` sampai `]`).
    Kalau tidak ditemukan, balik None.
    """
    m = re.search(r'"clients"\s*:\s*(\[(?:[^][]|\[[^]]*\])*\])', text, re.DOTALL)
    # ^ ini terlalu permisif; ganti dengan pencarian yang dekat dengan marker.
    pat = re.compile(
        r'"clients"\s*:\s*(\[[^][]*?#' + marker + r'[^][]*?\])',
        re.DOTALL,
    )
    m = pat.search(text)
    return m.group(1) if m else None

def make_inbound(port, protocol, hup_path, clients_block, marker):
    """
    Susun blok inbound HUP. clients_block sudah string `[ ... ]`.
    Kalau clients_block None (marker tidak ketemu), pakai placeholder default
    sesuai protocol.
    """
    settings = {
        'vless':  '"decryption": "none",',
        'vmess':  '',
        'trojan': '"decryption": "none",',
    }[protocol]
    if not clients_block:
        if protocol == 'vmess':
            clients_block = (
                '[\n          {\n'
                '            "id": "1d1c1d94-6987-4658-a4dc-8821a30fe7e0",\n'
                '            "alterId": 0\n'
                '            #' + marker + '\n'
                '          }\n        ]'
            )
        elif protocol == 'trojan':
            clients_block = (
                '[\n          {\n'
                '            "password": "1d1c1d94-6987-4658-a4dc-8821a30fe7e0"\n'
                '            #' + marker + '\n'
                '          }\n        ]'
            )
        else:
            clients_block = (
                '[\n          {\n'
                '            "id": "1d1c1d94-6987-4658-a4dc-8821a30fe7e0"\n'
                '            #' + marker + '\n'
                '          }\n        ]'
            )
    return (
        '    {\n'
        '      "listen": "127.0.0.1",\n'
        f'      "port": {port},\n'
        f'      "protocol": "{protocol}",\n'
        '      "settings": {\n'
        f'        {settings}\n'
        f'        "clients": {clients_block}\n'
        '      },\n'
        '      "streamSettings": {\n'
        '        "network": "httpupgrade",\n'
        '        "httpupgradeSettings": {\n'
        f'          "path": "{hup_path}",\n'
        '          "host": ""\n'
        '        }\n'
        '      }\n'
        '    }'
    )

vless_clients  = grab_clients_block('vless')
vmess_clients  = grab_clients_block('vmess')
trojan_clients = grab_clients_block('trojan')

new_inbounds = (
    make_inbound(14, 'vless',  '/vless-hup',  vless_clients,  'vless')  + ',\n' +
    make_inbound(15, 'vmess',  '/vmess-hup',  vmess_clients,  'vmess')  + ',\n' +
    make_inbound(16, 'trojan', '/trojan-hup', trojan_clients, 'trojan')
)

# Inject sebelum penutup `]` dari `inbounds`. Cari `"inbounds": [ ... ]`
# (multiline, balanced bracket sederhana).
idx = text.find('"inbounds"')
if idx < 0:
    sys.stderr.write("ERROR: tidak menemukan key inbounds di config.json\n")
    sys.exit(2)

# Cari `[` setelah "inbounds"
bracket_open = text.find('[', idx)
depth = 0
i = bracket_open
while i < len(text):
    ch = text[i]
    if ch == '[':
        depth += 1
    elif ch == ']':
        depth -= 1
        if depth == 0:
            break
    i += 1
if depth != 0:
    sys.stderr.write("ERROR: bracket inbounds tidak balanced\n")
    sys.exit(2)

before = text[:i]
after = text[i:]
# Tambahkan koma kalau perlu (kalau before diakhiri `}` lalu whitespace, tambah `,`)
stripped = before.rstrip()
if stripped.endswith('}'):
    before = stripped + ',\n' + new_inbounds + '\n  '
else:
    before = stripped + '\n' + new_inbounds + '\n  '

with open(path, 'w', encoding='utf-8') as f:
    f.write(before + after)

print("[refresh-hup] config.json berhasil di-patch.")
PYEOF
fi

echo "[refresh-hup] Sinkronisasi log path lama -> baru di config.json (kalau masih /var/log/v2ray) ..."
sed -i 's|/var/log/v2ray/|/var/log/xray/|g' "$CONFIG" || true

echo "[refresh-hup] Memastikan xray-core terinstal sebagai service ..."
INSTALL_XRAY=0
if ! command -v xray >/dev/null 2>&1; then
    INSTALL_XRAY=1
elif ! systemctl list-unit-files xray.service 2>/dev/null | grep -q '^xray\.service'; then
    INSTALL_XRAY=1
fi

if [ "$INSTALL_XRAY" = "1" ]; then
    echo "[refresh-hup] xray binary / service belum ada, install via XTLS/Xray-install ..."
    apt-get install -y --no-install-recommends ca-certificates curl unzip >/dev/null 2>&1 || true
    if ! bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/tmp/refresh-hup-xrayinstall.log 2>&1; then
        echo "[refresh-hup] ERROR: gagal install xray-core. Lihat log:"
        tail -n 30 /tmp/refresh-hup-xrayinstall.log | sed 's/^/[refresh-hup]   /'
        exit 1
    fi
fi

# Kalau service v2ray masih hidup, matikan supaya tidak rebut port dengan xray.
for legacy in v2ray.service v2ray@v2ray.service; do
    if systemctl list-unit-files "$legacy" 2>/dev/null | grep -q "^${legacy}"; then
        echo "[refresh-hup] Disable + stop legacy $legacy ..."
        systemctl disable --now "$legacy" >/dev/null 2>&1 || true
    fi
done
systemctl enable xray >/dev/null 2>&1 || true

echo "[refresh-hup] Test config xray ..."
if ! xray run -test -c "$CONFIG" >/tmp/refresh-hup-xray.log 2>&1; then
    echo "[refresh-hup] ERROR: xray menolak config baru:"
    tail -n 30 /tmp/refresh-hup-xray.log | sed 's/^/[refresh-hup]   /'
    echo "[refresh-hup] Restore config lama dari $BACKUP_DIR/config.json"
    cp "$BACKUP_DIR/config.json" "$CONFIG"
    exit 1
fi

echo "[refresh-hup] Test config nginx ..."
if ! nginx -t >/tmp/refresh-hup-nginx.log 2>&1; then
    echo "[refresh-hup] ERROR: nginx menolak config baru:"
    sed 's/^/[refresh-hup]   /' /tmp/refresh-hup-nginx.log
    echo "[refresh-hup] Restore nginx.conf lama dari $BACKUP_DIR/nginx.conf"
    cp "$BACKUP_DIR/nginx.conf" /etc/nginx/nginx.conf
    exit 1
fi

echo "[refresh-hup] Restart service ..."
systemctl restart xray
systemctl restart nginx

echo
echo "[refresh-hup] Selesai. Backup tersimpan di $BACKUP_DIR"
echo "[refresh-hup] Sekarang jalankan 'menu' lalu add-vless / add-vmess / add-tr untuk membuat akun baru"
echo "             yang langsung dapat 5 link (WS-TLS / WS-NTLS / GRPC / HUP-TLS / HUP-NTLS)."
echo "             Untuk akun yang sudah ada, link HUP-TLS tidak otomatis ada di pesan lama;"
echo "             generate ulang lewat menu kalau perlu."
