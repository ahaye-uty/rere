#!/bin/bash
# ========================================================
# activate-quota.sh
#
# Bootstrap Xray bandwidth quota di VPS yang sudah ke-install rere tapi
# belum punya quota-xray. Idempotent — boleh dipanggil ulang.
#
# Cara pakai (1 baris dari fork main):
#   bash <(curl -sL https://raw.githubusercontent.com/ahaye-uty/rere/main/file/activate-quota.sh)
#
# Yang dilakukan:
#   1. Pastikan tooling ada (jq, xray binary, xray.service aktif)
#   2. Download + install quota-xray (/usr/local/bin), cek-quota + set-quota
#      (/usr/local/sbin)
#   3. Bikin direktori state + DB + log file
#   4. Tambah cron entry: tiap 1 menit + reset bulanan tanggal 1 jam 00:01
# ========================================================

set -e

HOSTING="${HOSTING:-https://raw.githubusercontent.com/ahaye-uty/rere/main/file}"

say() { echo "[activate-quota] $*"; }

say "Verifikasi tooling ..."
if ! command -v jq >/dev/null 2>&1; then
  say "jq belum ada, install ..."
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y jq >/dev/null 2>&1 || { say "ERROR: gagal install jq"; exit 1; }
fi

if ! command -v /usr/local/bin/xray >/dev/null 2>&1; then
  say "ERROR: /usr/local/bin/xray tidak ditemukan. Install xray dulu (mis. via install.sh / refresh-hup.sh)."
  exit 1
fi

if ! systemctl list-unit-files xray.service 2>/dev/null | grep -q '^xray\.service'; then
  say "ERROR: xray.service tidak ke-install."
  exit 1
fi

say "Verifikasi stats API xray aktif di config.json ..."
CFG="/usr/local/etc/xray/config.json"
if [ ! -f "$CFG" ]; then
  say "ERROR: $CFG tidak ada."
  exit 1
fi
if ! grep -q '"stats"' "$CFG" || ! grep -q "StatsService" "$CFG"; then
  say "WARNING: stats API belum lengkap di $CFG."
  say "         Quota tracking butuh 'stats: {}' + 'StatsService' di api.services."
  say "         Coba refresh-hup.sh atau update config.json dari repo terbaru."
fi
if ! grep -q "statsUserUplink" "$CFG"; then
  say "WARNING: 'statsUserUplink' / 'statsUserDownlink' belum aktif di policy."
fi

say "Download scripts dari $HOSTING ..."
wget -q -O /usr/local/bin/quota-xray  "${HOSTING}/quota-xray.sh"   || { say "ERROR: download quota-xray gagal"; exit 1; }
wget -q -O /usr/local/sbin/cek-quota  "${HOSTING}/cek-quota.sh"    || { say "ERROR: download cek-quota gagal"; exit 1; }
wget -q -O /usr/local/sbin/set-quota  "${HOSTING}/set-quota.sh"    || { say "ERROR: download set-quota gagal"; exit 1; }

chmod +x /usr/local/bin/quota-xray /usr/local/sbin/cek-quota /usr/local/sbin/set-quota

say "Patch main menu (tambah entry 16. Cek Xray Quota + 17. Set Xray Quota) ..."
wget -q -O /tmp/patch-menu-quota.sh "${HOSTING}/patch-menu-quota.sh" \
    && bash /tmp/patch-menu-quota.sh /usr/local/sbin \
    || say "WARNING: patch-menu-quota.sh gagal (skip)"
rm -f /tmp/patch-menu-quota.sh

say "Setup direktori state + DB + log ..."
mkdir -p /usr/local/etc/xray/quota-blocked
[ -f /usr/local/etc/xray/quota-xray.db ] || : > /usr/local/etc/xray/quota-xray.db
[ -f /var/log/quota-xray.log ]           || : > /var/log/quota-xray.log
chmod 644 /usr/local/etc/xray/quota-xray.db /var/log/quota-xray.log

CONF="/usr/local/etc/quota-xray.conf"
# Prompt default quota Xray (skip kalau DEFAULT_QUOTA_MB udah di-set via env
# atau kalau conf udah ada — assume admin udah pilih sebelumnya).
if [ -z "${DEFAULT_QUOTA_MB:-}" ] && [ ! -f "$CONF" ]; then
  echo
  echo "─────────────────────────────────────────────"
  echo "  Default Quota Xray (per akun)"
  echo "─────────────────────────────────────────────"
  echo "  Nilai default quota bulanan tiap akun baru, dalam GB."
  echo "  Saran:"
  echo "    -  50  : HP customer (pemakaian normal)"
  echo "    - 250  : STB OpenWRT (bandwidth besar, default)"
  echo "    -   0  : Unlimited (track only, no auto-block)"
  if [ -r /dev/tty ]; then
    read -rp " Default quota Xray (GB) [250]: " QUOTA_GB_INPUT </dev/tty
  else
    QUOTA_GB_INPUT=""
  fi
  QUOTA_GB="${QUOTA_GB_INPUT:-250}"
  case "$QUOTA_GB" in ''|*[!0-9]*) QUOTA_GB=250 ;; esac
  DEFAULT_QUOTA_MB=$(( QUOTA_GB * 1024 ))
  echo "DEFAULT_QUOTA_MB=${DEFAULT_QUOTA_MB}" > "$CONF"
  chmod 644 "$CONF"
  say "Xray default quota = ${QUOTA_GB} GB (${DEFAULT_QUOTA_MB} MB) -> $CONF"
elif [ -f "$CONF" ]; then
  . "$CONF"
  say "Pakai default quota dari $CONF: DEFAULT_QUOTA_MB=${DEFAULT_QUOTA_MB}"
fi
DEFAULT_QUOTA_MB="${DEFAULT_QUOTA_MB:-256000}"
say "Pre-populate user xray dari $CFG dengan default quota ${DEFAULT_QUOTA_MB} MB ..."
DB="/usr/local/etc/xray/quota-xray.db"
RDATE="$(date -d 'next month' +%Y-%m-01 2>/dev/null || date +%Y-%m-01)"
ADDED=0
while IFS= read -r email; do
  [ -z "$email" ] && continue
  if awk -F'|' -v u="$email" '$1==u {found=1; exit} END{exit !found}' "$DB"; then
    continue
  fi
  echo "$email|${DEFAULT_QUOTA_MB}|0|active|$RDATE" >> "$DB"
  ADDED=$(( ADDED + 1 ))
done < <(grep -oE '"email"[[:space:]]*:[[:space:]]*"[^"]+"' "$CFG" \
           | sed -E 's/.*"([^"]+)"$/\1/' \
           | sort -u)
say "Pre-populate: $ADDED user baru ditambahkan ke DB (existing rows tidak diubah)."

say "Setup cron entries ..."
# 1) tiap menit: akumulasi + enforce
if ! grep -q "quota-xray$" /etc/crontab; then
  echo '* * * * * root /usr/local/bin/quota-xray' >> /etc/crontab
  say "Cron tiap menit ditambahkan."
fi
# 2) tanggal 1 tiap bulan jam 00:01: reset bulanan
if ! grep -q 'quota-xray --monthly-reset' /etc/crontab; then
  echo '1 0 1 * * root /usr/local/bin/quota-xray --monthly-reset' >> /etc/crontab
  say "Cron monthly-reset ditambahkan."
fi
systemctl restart cron >/dev/null 2>&1 || service cron restart >/dev/null 2>&1 || true

say "Selesai. Cara pakai:"
say "  - cek-quota             : lihat usage + status semua user xray"
say "  - set-quota             : menu untuk set quota / reset / block / unblock"
say "  - quota-xray --reset    : reset usage semua user + auto-unblock"
say "  - quota-xray --reset U  : reset 1 user"
say "  - quota-xray --block U  : block manual"
say "  - quota-xray --unblock U: unblock manual"
say
say "Tracking jalan tiap menit lewat cron. Pertama kali, user baru muncul"
say "di cek-quota begitu mulai pakai bandwidth. Default-nya STATUS=unlimited"
say "(no auto-block). Set quota lewat 'set-quota' biar auto-block aktif."
