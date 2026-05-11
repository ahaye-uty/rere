#!/bin/bash
# ========================================================
# cek-quota-ssh.sh
#
# Display per-user SSH bandwidth usage + quota + status, sorted by usage.
# DB-nya di-maintain oleh /usr/local/bin/quota-ssh (cron tiap 1 menit).
# Untuk akun yg baru ditambah via sshman tapi belum ke-pickup cron,
# script ini juga scan /etc/passwd (UID>=1000 + shell nologin/false)
# dan munculin user yg belum ada di DB sebagai status PENDNG.
# ========================================================

DB="/usr/local/etc/quota-ssh.db"
LOG="/var/log/quota-ssh.log"
CONF="/usr/local/etc/quota-ssh.conf"
[ -f "$CONF" ] && . "$CONF"
DEFAULT_QUOTA_MB="${DEFAULT_QUOTA_MB:-256000}"

human_size() {
  local b=$1
  [ -z "$b" ] && b=0
  if [ "$b" -ge $((1024*1024*1024)) ]; then
    awk -v x="$b" 'BEGIN{printf "%.2f GB", x/1024/1024/1024}'
  elif [ "$b" -ge $((1024*1024)) ]; then
    awk -v x="$b" 'BEGIN{printf "%.2f MB", x/1024/1024}'
  elif [ "$b" -ge 1024 ]; then
    awk -v x="$b" 'BEGIN{printf "%.2f KB", x/1024}'
  else
    echo "${b} B"
  fi
}

human_quota() {
  local mb=$1
  if [ -z "$mb" ] || [ "$mb" = "0" ]; then
    echo "∞"
    return
  fi
  if [ "$mb" -ge 1024 ]; then
    awk -v x="$mb" 'BEGIN{printf "%.2f GB", x/1024}'
  else
    echo "${mb} MB"
  fi
}

# Build combined list: union of DB users + eligible /etc/passwd users.
# Filter 'nobody' (UID 65534) — sistem user yg dipake Xray + daemon helper,
# bukan akun SSH reseller. Bahkan kalau ada baris legacy di DB ke-skip dari
# display (quota-ssh juga auto-prune-nya di tick berikutnya).
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

if [ -s "$DB" ]; then
  awk -F'|' '$1!="" && $1!~/^#/ && $1!="nobody"' "$DB" >> "$TMP"
fi

while IFS=: read -r user uid; do
  [ -z "$user" ] && continue
  if ! awk -F'|' -v u="$user" '$1==u {f=1; exit} END{exit !f}' "$TMP" 2>/dev/null; then
    echo "$user|${DEFAULT_QUOTA_MB}|0|pending|$(date -d 'next month' +%Y-%m-01 2>/dev/null || date +%Y-%m-01)" >> "$TMP"
  fi
done < <(awk -F: '($7=="/usr/sbin/nologin" || $7=="/bin/false" || $7=="/sbin/nologin") && $3>=1000 && $3<65000 && $1!="nobody" {print $1":"$3}' /etc/passwd)

if [ ! -s "$TMP" ]; then
  echo "────────────────────────────────────────"
  echo "  SSH Quota: belum ada user SSH (UID>=1000, shell nologin/false)."
  echo "────────────────────────────────────────"
  exit 0
fi

echo "─────────────────────────────────────────────────────────────────────"
printf "  %-20s %-12s %-12s %-9s %s\n" "USER" "USAGE" "QUOTA" "STATUS" "RESET"
echo "─────────────────────────────────────────────────────────────────────"

sort -t'|' -k3,3nr "$TMP" | while IFS='|' read -r user limit_mb used status rdate; do
  [ -z "$user" ] && continue
  usage_str=$(human_size "${used:-0}")
  quota_str=$(human_quota "${limit_mb:-0}")
  [ -z "$status" ] && status=active
  [ -z "$rdate" ]  && rdate="-"
  case "$status" in
    blocked)   tag="\033[31m●BLOCK \033[0m" ;;
    unlimited) tag="\033[36m○FREE  \033[0m" ;;
    pending)   tag="\033[33m○PENDNG\033[0m" ;;
    *)         tag="\033[32m●ACTIVE\033[0m" ;;
  esac
  printf "  %-20s %-12s %-12s " "$user" "$usage_str" "$quota_str"
  printf "%b " "$tag"
  printf "%s\n" "$rdate"
done

echo "─────────────────────────────────────────────────────────────────────"
total=$(awk -F'|' '$1!="" && $1!~/^#/' "$TMP" | wc -l)
echo "  Total user        : $total"
blocked_n=$(awk -F'|' '$4=="blocked"' "$TMP" | wc -l)
pending_n=$(awk -F'|' '$4=="pending"' "$TMP" | wc -l)
if [ "$blocked_n" -gt 0 ]; then
  echo "  Blocked sekarang  : $blocked_n  (auto-unblock saat reset bulanan)"
fi
if [ "$pending_n" -gt 0 ]; then
  echo "  PENDING           : $pending_n  (akun baru, akan auto-register dalam <1 menit)"
fi
echo "  DB file           : $DB"
[ -s "$LOG" ] && echo "  Recent events     :"
[ -s "$LOG" ] && tail -n 5 "$LOG" | sed 's/^/    /'
echo "─────────────────────────────────────────────────────────────────────"
