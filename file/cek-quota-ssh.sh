#!/bin/bash
# ========================================================
# cek-quota-ssh.sh
#
# Display per-user SSH bandwidth usage + quota + status, sorted by usage.
# DB-nya di-maintain oleh /usr/local/bin/quota-ssh (cron tiap 1 menit).
# ========================================================

DB="/usr/local/etc/quota-ssh.db"
LOG="/var/log/quota-ssh.log"

if [ ! -f "$DB" ] || [ ! -s "$DB" ]; then
  echo "────────────────────────────────────────"
  echo "  SSH Quota: belum ada user ter-tracking."
  echo "  Pastikan quota-ssh cron sudah jalan + ada user SSH yang aktif."
  echo "────────────────────────────────────────"
  exit 0
fi

human_size() {
  local b=$1
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

echo "─────────────────────────────────────────────────────────────────────"
printf "  %-20s %-12s %-12s %-9s %s\n" "USER" "USAGE" "QUOTA" "STATUS" "RESET"
echo "─────────────────────────────────────────────────────────────────────"

awk -F'|' '$1!="" && $1!~/^#/' "$DB" | sort -t'|' -k3,3nr | while IFS='|' read -r user limit_mb used status rdate; do
  [ -z "$user" ] && continue
  usage_str=$(human_size "${used:-0}")
  quota_str=$(human_quota "${limit_mb:-0}")
  [ -z "$status" ] && status=active
  [ -z "$rdate" ]  && rdate="-"
  case "$status" in
    blocked)   tag="\033[31m●BLOCK\033[0m " ;;
    unlimited) tag="\033[36m○FREE \033[0m " ;;
    *)         tag="\033[32m●ACTIVE\033[0m" ;;
  esac
  printf "  %-20s %-12s %-12s " "$user" "$usage_str" "$quota_str"
  printf "%b " "$tag"
  printf "%s\n" "$rdate"
done

echo "─────────────────────────────────────────────────────────────────────"
echo "  Total user tracked: $(awk -F'|' '$1!="" && $1!~/^#/' "$DB" | wc -l)"
blocked_n=$(awk -F'|' '$4=="blocked"' "$DB" | wc -l)
if [ "$blocked_n" -gt 0 ]; then
  echo "  Blocked sekarang  : $blocked_n  (auto-unblock saat reset bulanan)"
fi
echo "  DB file           : $DB"
[ -s "$LOG" ] && echo "  Recent events     :"
[ -s "$LOG" ] && tail -n 5 "$LOG" | sed 's/^/    /'
echo "─────────────────────────────────────────────────────────────────────"
