#!/bin/bash
# ========================================================
# patch-menu-misc.sh
#
# Patch lain-lain di main.zip:
#   1. backup        : hapus baris legacy yg copy xray dir ke v2ray dir name
#                      (sekarang murni xray, tidak ada lagi 'v2ray' di output zip).
#   2. menu  case 10 : restart-all-service diperluas dgn service edge-mux v2
#                      (sslh-internal, stunnel-ssh, dropbear, noobzvpns, fail2ban).
#                      Pakai for-loop supaya service yg belum terpasang tidak
#                      bikin command gagal (skip, lanjut yg lain).
#
# Idempotent: aman di-run berkali-kali.
#
# Argumen: $1 = path direktori menu (default /usr/local/sbin)
# ========================================================

set -e

DIR="${1:-/usr/local/sbin}"

if [ ! -d "$DIR" ]; then
    echo "[patch-menu-misc] ERROR: dir $DIR tidak ada."
    exit 1
fi

# ---- 1. backup: hilangkan legacy v2ray dir ----
BK="$DIR/backup"
if [ -f "$BK" ]; then
    if grep -qE 'cp -r /usr/local/etc/xray/ /root/backup/v2ray' "$BK"; then
        # Hapus baris dan komentar di atasnya (yg menyebut 'legacy: also keep v2ray').
        sed -i '/^# legacy: also keep v2ray dir name/d' "$BK"
        sed -i '\|^cp -r /usr/local/etc/xray/ /root/backup/v2ray|d' "$BK"
        echo "[patch-menu-misc] $BK: baris legacy v2ray dihapus."
    else
        echo "[patch-menu-misc] $BK: tidak ada legacy v2ray dir, skip."
    fi
fi

# ---- 2. menu: update case 10 (restart all service) ----
MENU="$DIR/menu"
if [ -f "$MENU" ]; then
    # Idempotent: skip kalau case 10 sudah punya 'sslh-internal' (tanda sudah patched).
    if grep -q 'sslh-internal' "$MENU"; then
        echo "[patch-menu-misc] $MENU: case 10 sudah ter-patch, skip."
    else
        # Replace seluruh baris case 10. Pakai delimiter '|' supaya '/' di path
        # tidak mengganggu.
        NEW_LINE='10) clear ; systemctl daemon-reload ; pkill sslh ; for svc in xray proxy danted badvpn udp-custom nginx sslh sslh-internal stunnel-ssh dropbear noobzvpns fail2ban; do systemctl restart "$svc" 2>/dev/null || true; done ; clear ; echo -e "success restart all service" ; sleep 5 ; menu ;;'
        # Cari baris yg dimulai dengan '10) clear ; systemctl daemon-reload'
        # dan ganti seluruhnya. Pakai awk biar aman terhadap karakter spesial.
        awk -v new="$NEW_LINE" '
            /^10\) clear ; systemctl daemon-reload/ { print new; next }
            { print }
        ' "$MENU" > "${MENU}.tmp" && mv "${MENU}.tmp" "$MENU"
        chmod +x "$MENU"
        echo "[patch-menu-misc] $MENU: case 10 (restart all service) ter-update."
    fi
fi
