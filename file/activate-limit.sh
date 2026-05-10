#!/bin/bash
# ============================================================
# Activate IP Limit + Account Manager CLI
# ------------------------------------------------------------
# One-shot bootstrap untuk VPS yang sudah ke-install rere tapi
# belum punya fitur IP limit (SSH only) + sshman / vmessman /
# vlessman / trojanman.
#
# Idempotent: aman dijalankan berkali-kali (skip step yang
# sudah selesai).
#
# Usage:
#   bash <(curl -sL https://raw.githubusercontent.com/ahaye-uty/rere/main/file/activate-limit.sh)
# ============================================================

set -e

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: harus dijalankan sebagai root."
    exit 1
fi

HOSTING="https://raw.githubusercontent.com/ahaye-uty/rere/main/file"

echo "[1/5] download IP limit + manager CLI scripts..."
mkdir -p /usr/local/etc/xray /usr/local/bin /usr/local/sbin

wget -q -O /usr/local/bin/limit-ip   "$HOSTING/limit-ip.sh"
wget -q -O /usr/local/sbin/cek-limit "$HOSTING/cek-limit.sh"
wget -q -O /usr/local/sbin/set-limit "$HOSTING/set-limit.sh"
wget -q -O /usr/local/bin/sshman     "$HOSTING/sshman"
wget -q -O /usr/local/sbin/vmessman  "$HOSTING/vmessman"
wget -q -O /usr/local/sbin/vlessman  "$HOSTING/vlessman"
wget -q -O /usr/local/sbin/trojanman "$HOSTING/trojanman"

chmod +x /usr/local/bin/limit-ip /usr/local/sbin/cek-limit /usr/local/sbin/set-limit \
         /usr/local/bin/sshman /usr/local/sbin/vmessman /usr/local/sbin/vlessman \
         /usr/local/sbin/trojanman

echo "[2/5] init config (default limit=2)..."
[[ -f /usr/local/etc/xray/limit-ip ]]    || echo "2" > /usr/local/etc/xray/limit-ip
[[ -f /usr/local/etc/xray/limit-ip.db ]] || touch /usr/local/etc/xray/limit-ip.db

echo "[3/5] cleanup leftover UDP-Custom limit (kalau ada dari versi lama)..."
rm -f /usr/local/etc/xray/limit-udp-enabled /usr/local/etc/xray/limit-udp-port 2>/dev/null
if iptables -L LIMIT-UDP-CUSTOM -n >/dev/null 2>&1; then
    while iptables -D INPUT -j LIMIT-UDP-CUSTOM 2>/dev/null; do :; done
    iptables -F LIMIT-UDP-CUSTOM 2>/dev/null
    iptables -X LIMIT-UDP-CUSTOM 2>/dev/null
fi

echo "[4/5] setup cron */1 (idempotent)..."
if ! grep -q '/usr/local/bin/limit-ip' /etc/crontab; then
    echo '*/1 * * * * root /usr/local/bin/limit-ip' >> /etc/crontab
fi
systemctl restart cron 2>/dev/null || service cron restart 2>/dev/null || true

echo "[5/5] patch menu (option 14/15) + add-ssh prompt (idempotent)..."
bash <(curl -sL "$HOSTING/patch-menu-limit.sh") /usr/local/sbin || true
bash <(curl -sL "$HOSTING/patch-add-limit.sh")  /usr/local/sbin || true

echo ""
echo "============================================================"
echo " IP limit + manager CLI aktif."
echo ""
echo " Files:"
ls -la /usr/local/bin/limit-ip /usr/local/sbin/cek-limit /usr/local/sbin/set-limit \
       /usr/local/bin/sshman /usr/local/sbin/vmessman /usr/local/sbin/vlessman \
       /usr/local/sbin/trojanman 2>&1 | awk '{print "   " $0}'
echo ""
echo " Cron entry:"
grep limit-ip /etc/crontab | awk '{print "   " $0}'
echo ""
echo " Test:"
echo "   sshman add testuser passw0rd 1   # buat akun limit 1 IP"
echo "   cek-limit                        # tampilkan sesi aktif"
echo "   set-limit                        # ubah limit per user"
echo "============================================================"
