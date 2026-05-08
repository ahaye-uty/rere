#!/bin/bash
# ========================================================
# uninstall-limit.sh
#
# Hapus tuntas fitur IP limit dari server:
#   1. Flush iptables LIMIT-IP chain (unblock semua IP)
#   2. Hapus cron entry limit-ip
#   3. Hapus file limit-ip / cek-limit / set-limit
#   4. Hapus DB & config limit-ip
#   5. Hapus entry "Cek IP Limit" / "Set IP Limit" dari menu
#   6. Hapus prompt "Limit IP" dari add-ssh / add-vmess / add-vless / add-tr
#   7. Re-download sshman / vmessman / vlessman / trojanman versi tanpa limit
#
# Idempotent: aman di-run berkali-kali.
#
# Cara pakai:
#   bash <(curl -sL https://raw.githubusercontent.com/ahaye-uty/rere/main/file/uninstall-limit.sh)
# ========================================================

set -e

# Branch sumber file pengganti sshman/vmessman/dst (tanpa fitur limit)
HOSTING="${HOSTING:-https://raw.githubusercontent.com/ahaye-uty/rere/main/file}"

echo "[uninstall-limit] Mulai cleanup IP limit..."

# 1. Flush iptables LIMIT-IP chain
echo "[uninstall-limit] Flush iptables LIMIT-IP chain..."
iptables -D INPUT -j LIMIT-IP 2>/dev/null || true
iptables -F LIMIT-IP 2>/dev/null || true
iptables -X LIMIT-IP 2>/dev/null || true

# 2. Hapus cron entry limit-ip
echo "[uninstall-limit] Hapus cron entry limit-ip..."
if [ -f /etc/crontab ] && grep -q "limit-ip" /etc/crontab; then
    sed -i '/limit-ip/d' /etc/crontab
    systemctl restart cron 2>/dev/null || service cron restart 2>/dev/null || true
fi

# 3. Hapus file scripts
echo "[uninstall-limit] Hapus file scripts limit..."
rm -f /usr/local/bin/limit-ip
rm -f /usr/local/sbin/cek-limit
rm -f /usr/local/sbin/set-limit
rm -f /var/log/limit-ip.log

# 4. Hapus DB & config
echo "[uninstall-limit] Hapus DB & config limit..."
rm -f /usr/local/etc/xray/limit-ip
rm -f /usr/local/etc/xray/limit-ip.db

# 5. Patch menu: buang entry 14 & 15
MENU_PATHS=(/usr/local/sbin/menu /usr/local/bin/menu)
for MENU in "${MENU_PATHS[@]}"; do
    [ ! -f "$MENU" ] && continue
    if grep -q "Cek IP Limit\|Set IP Limit\|14) cek-limit\|15) set-limit" "$MENU"; then
        echo "[uninstall-limit] Bersihkan entry IP Limit di $MENU..."
        sed -i '/Cek IP Limit/d' "$MENU"
        sed -i '/Set IP Limit/d' "$MENU"
        sed -i '/14) cek-limit ;;/d' "$MENU"
        sed -i '/15) set-limit ;;/d' "$MENU"
    fi
done

# 6. Patch add-* scripts: buang prompt "Limit IP"
for DIR in /usr/local/sbin /usr/local/bin; do
    for script in add-ssh add-ssh-gege add-vmess add-vmess-gege add-vless add-vless-gege add-tr add-trojan-gege; do
        FILE="$DIR/$script"
        [ ! -f "$FILE" ] && continue
        if grep -q "Limit IP\|limit-ip.db" "$FILE"; then
            echo "[uninstall-limit] Bersihkan prompt Limit IP di $FILE..."
            # Hapus 3 baris snippet yang di-inject patch-add-limit.sh
            sed -i '/Limit IP (1\/2)/d' "$FILE"
            sed -i '/iplimit=2/d' "$FILE"
            sed -i '/limit-ip.db/d' "$FILE"
        fi
    done
done

# 7. Re-download sshman / vmessman / vlessman / trojanman versi tanpa limit
echo "[uninstall-limit] Re-download sshman/vmessman/vlessman/trojanman..."
wget -q -O /usr/local/bin/sshman      "${HOSTING}/sshman"      && chmod +x /usr/local/bin/sshman
wget -q -O /usr/local/sbin/vmessman   "${HOSTING}/vmessman"    && chmod +x /usr/local/sbin/vmessman
wget -q -O /usr/local/sbin/vlessman   "${HOSTING}/vlessman"    && chmod +x /usr/local/sbin/vlessman
wget -q -O /usr/local/sbin/trojanman  "${HOSTING}/trojanman"   && chmod +x /usr/local/sbin/trojanman

echo "[uninstall-limit] Selesai. Verifikasi:"
echo "  - iptables -L LIMIT-IP -n 2>&1 | head -3"
echo "  - grep limit-ip /etc/crontab || echo '(no cron entry)'"
echo "  - sshman / vmessman tanpa flag iplimit"
