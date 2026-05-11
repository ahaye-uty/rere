#!/bin/bash
# ========================================================
# activate-quota-ssh.sh
#
# Bootstrap SSH bandwidth quota di VPS yang sudah ke-install rere tapi
# belum punya quota-ssh. Idempotent — boleh dipanggil ulang.
#
# Cara pakai (1 baris dari fork main):
#   bash <(curl -sL https://raw.githubusercontent.com/ahaye-uty/rere/main/file/activate-quota-ssh.sh)
#
# Yang dilakukan:
#   1. Pastikan tooling ada (iptables, awk)
#   2. Download + install quota-ssh (/usr/local/bin), cek-quota-ssh +
#      set-quota-ssh (/usr/local/sbin)
#   3. Bikin direktori state + DB + log file
#   4. Pre-populate DB dgn semua user SSH eligible (default 250 GiB)
#   5. Tambah cron entry: tiap 1 menit + reset bulanan tanggal 1 jam 00:02
# ========================================================

set -e

HOSTING="${HOSTING:-https://raw.githubusercontent.com/ahaye-uty/rere/main/file}"

say() { echo "[activate-quota-ssh] $*"; }

say "Verifikasi tooling ..."
if ! command -v iptables >/dev/null 2>&1; then
  say "ERROR: iptables tidak ditemukan. Install dulu (apt-get install iptables)."
  exit 1
fi
if ! command -v usermod >/dev/null 2>&1; then
  say "ERROR: usermod tidak ditemukan (paket passwd / shadow-utils)."
  exit 1
fi

say "Download scripts dari $HOSTING ..."
wget -q -O /usr/local/bin/quota-ssh       "${HOSTING}/quota-ssh.sh"        || { say "ERROR: download quota-ssh gagal"; exit 1; }
wget -q -O /usr/local/sbin/cek-quota-ssh  "${HOSTING}/cek-quota-ssh.sh"    || { say "ERROR: download cek-quota-ssh gagal"; exit 1; }
wget -q -O /usr/local/sbin/set-quota-ssh  "${HOSTING}/set-quota-ssh.sh"    || { say "ERROR: download set-quota-ssh gagal"; exit 1; }

chmod +x /usr/local/bin/quota-ssh /usr/local/sbin/cek-quota-ssh /usr/local/sbin/set-quota-ssh

say "Patch main menu (tambah entry 18. Cek SSH Quota + 19. Set SSH Quota) ..."
wget -q -O /tmp/patch-menu-quota-ssh.sh "${HOSTING}/patch-menu-quota-ssh.sh" \
    && bash /tmp/patch-menu-quota-ssh.sh /usr/local/sbin \
    || say "WARNING: patch-menu-quota-ssh.sh gagal (skip)"
rm -f /tmp/patch-menu-quota-ssh.sh

say "Setup direktori state + DB + log ..."
mkdir -p /usr/local/etc/quota-ssh-blocked
chmod 700 /usr/local/etc/quota-ssh-blocked
[ -f /usr/local/etc/quota-ssh.db ] || : > /usr/local/etc/quota-ssh.db
[ -f /var/log/quota-ssh.log ]      || : > /var/log/quota-ssh.log
chmod 644 /usr/local/etc/quota-ssh.db /var/log/quota-ssh.log

DEFAULT_QUOTA_MB="${DEFAULT_QUOTA_MB:-256000}"
say "Pre-populate user SSH (UID>=1000, shell nologin/false) dgn default quota ${DEFAULT_QUOTA_MB} MB (~250 GiB) ..."
DB="/usr/local/etc/quota-ssh.db"
RDATE="$(date -d 'next month' +%Y-%m-01 2>/dev/null || date +%Y-%m-01)"
ADDED=0
while IFS=: read -r user uid; do
  [ -z "$user" ] && continue
  if awk -F'|' -v u="$user" '$1==u {found=1; exit} END{exit !found}' "$DB"; then
    continue
  fi
  echo "$user|${DEFAULT_QUOTA_MB}|0|active|$RDATE" >> "$DB"
  ADDED=$(( ADDED + 1 ))
done < <(awk -F: '($7=="/usr/sbin/nologin" || $7=="/bin/false" || $7=="/sbin/nologin") && $3>=1000 {print $1":"$3}' /etc/passwd)
say "Pre-populate: $ADDED user baru ditambahkan ke DB (existing rows tidak diubah)."

say "Bootstrap iptables chain QUOTA-SSH + rule per user ..."
/usr/local/bin/quota-ssh >/dev/null 2>&1 || true

say "Setup cron entries ..."
if ! grep -qE 'quota-ssh($| )' /etc/crontab; then
  echo '* * * * * root /usr/local/bin/quota-ssh' >> /etc/crontab
  say "Cron tiap menit ditambahkan."
fi
if ! grep -q 'quota-ssh --monthly-reset' /etc/crontab; then
  echo '2 0 1 * * root /usr/local/bin/quota-ssh --monthly-reset' >> /etc/crontab
  say "Cron monthly-reset ditambahkan."
fi
systemctl restart cron >/dev/null 2>&1 || service cron restart >/dev/null 2>&1 || true

say "Selesai. Cara pakai:"
say "  - cek-quota-ssh           : lihat usage + status semua user SSH"
say "  - set-quota-ssh           : menu untuk set quota / reset / block / unblock"
say "  - quota-ssh --reset       : reset usage semua user + auto-unblock"
say "  - quota-ssh --reset U     : reset 1 user"
say "  - quota-ssh --block U     : block manual (usermod -L + kill session)"
say "  - quota-ssh --unblock U   : unblock manual"
say
say "Tracking jalan tiap menit lewat cron pakai iptables -m owner --uid-owner."
say "Block mechanism: usermod -L + pkill -KILL -u <user>. Reversible."
