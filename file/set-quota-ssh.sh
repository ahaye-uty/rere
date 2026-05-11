#!/bin/bash
# ========================================================
# set-quota-ssh.sh
#
# Menu interaktif untuk manage SSH bandwidth quota per-user.
# Daftar user diambil dari /etc/passwd (UID>=1000 + shell nologin/false)
# plus user yang sudah ada di DB.
# ========================================================

DB="/usr/local/etc/quota-ssh.db"
QUOTA_BIN="/usr/local/bin/quota-ssh"

clear
RED='\033[1;31m'
GRN='\033[1;32m'
YLW='\033[1;33m'
CYN='\033[1;36m'
NC='\033[0m'

[ ! -f "$DB" ] && touch "$DB"

collect_users() {
  {
    awk -F: '($7=="/usr/sbin/nologin" || $7=="/bin/false" || $7=="/sbin/nologin") && $3>=1000 {print $1}' /etc/passwd
    awk -F'|' '$1!="" && $1!~/^#/ {print $1}' "$DB" 2>/dev/null
  } | sort -u
}

db_get_field() {
  local user="$1" idx="$2"
  awk -F'|' -v u="$user" -v i="$idx" '$1==u {print $i; exit}' "$DB"
}

human_size() {
  local b=$1
  [ -z "$b" ] && b=0
  if [ "$b" -ge $((1024*1024*1024)) ]; then
    awk -v x="$b" 'BEGIN{printf "%.2f GB", x/1024/1024/1024}'
  elif [ "$b" -ge $((1024*1024)) ]; then
    awk -v x="$b" 'BEGIN{printf "%.2f MB", x/1024/1024}'
  else
    awk -v x="$b" 'BEGIN{printf "%.2f KB", x/1024}'
  fi
}

human_quota() {
  local mb=$1
  if [ -z "$mb" ] || [ "$mb" = "0" ]; then echo "∞ (unlimited)"; return; fi
  if [ "$mb" -ge 1024 ]; then
    awk -v x="$mb" 'BEGIN{printf "%.2f GB", x/1024}'
  else
    echo "${mb} MB"
  fi
}

pick_user() {
  local prompt="${1:-Pilih user}"
  mapfile -t USERS < <(collect_users)
  if [ "${#USERS[@]}" -eq 0 ]; then
    echo -e "${YLW}Belum ada user SSH (UID>=1000 + shell nologin/false).${NC}"
    return 1
  fi
  echo -e "${CYN}─────────────────────────────────────────────${NC}"
  echo -e "${CYN}  $prompt${NC}"
  echo -e "${CYN}─────────────────────────────────────────────${NC}"
  local i=1
  for u in "${USERS[@]}"; do
    local status; status=$(db_get_field "$u" 4); [ -z "$status" ] && status=untracked
    local limit;  limit=$(db_get_field "$u" 2)
    local used;   used=$(db_get_field "$u" 3); [ -z "$used" ] && used=0
    local q;      q=$(human_quota "$limit")
    local us;     us=$(human_size "$used")
    printf "  %2d) %-20s  used=%-12s quota=%-15s [%s]\n" "$i" "$u" "$us" "$q" "$status"
    i=$((i+1))
  done
  echo
  read -rp "Pilihan (nomor, 0 = batal): " idx
  if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "${#USERS[@]}" ]; then
    echo "Dibatalkan."
    return 1
  fi
  PICKED="${USERS[$((idx-1))]}"
  return 0
}

pause() {
  echo; read -rp "Tekan ENTER untuk lanjut..." _ ;
}

menu_set_quota() {
  pick_user "Set Quota - pilih user" || { pause; return; }
  local user="$PICKED"
  echo
  echo -e "${CYN}Set quota untuk user: $user${NC}"
  echo "  Masukkan quota dalam GB (mis. 10 = 10GB)."
  echo "  Ketik 0 = unlimited (no limit, tetap di-track)."
  echo
  read -rp "Quota (GB): " qg
  if ! [[ "$qg" =~ ^[0-9]+$ ]]; then
    echo "Format invalid. Dibatalkan."; pause; return
  fi
  local limit_mb=$(( qg * 1024 ))
  local status=active
  [ "$qg" = "0" ] && status=unlimited
  local used=$(db_get_field "$user" 3); [ -z "$used" ] && used=0
  local rdate=$(db_get_field "$user" 5); [ -z "$rdate" ] && rdate=$(date +%Y-%m-01)
  local cur_status=$(db_get_field "$user" 4)
  [ "$cur_status" = "blocked" ] && status=blocked
  local tmp; tmp=$(mktemp)
  awk -F'|' -v u="$user" 'BEGIN{OFS="|"} $1!=u {print}' "$DB" > "$tmp"
  echo "$user|$limit_mb|$used|$status|$rdate" >> "$tmp"
  mv "$tmp" "$DB"
  echo -e "${GRN}OK. Quota $user di-set ke $(human_quota "$limit_mb").${NC}"
  pause
}

menu_reset() {
  echo
  echo "  Reset target:"
  echo "    1) Reset 1 user (pilih dari list)"
  echo "    2) Reset SEMUA user"
  echo "    0) Batal"
  read -rp "Pilihan: " sub
  case "$sub" in
    1)
      pick_user "Reset usage - pilih user" || { pause; return; }
      "$QUOTA_BIN" --reset "$PICKED"
      echo -e "${GRN}Reset selesai untuk $PICKED.${NC}"
      ;;
    2)
      read -rp "Yakin reset SEMUA user (y/n)? " yn
      [ "$yn" != "y" ] && { echo "Dibatalkan."; pause; return; }
      "$QUOTA_BIN" --reset
      echo -e "${GRN}Reset selesai untuk semua user.${NC}"
      ;;
    *) ;;
  esac
  pause
}

menu_block() {
  pick_user "Block manual - pilih user" || { pause; return; }
  "$QUOTA_BIN" --block "$PICKED"
  pause
}

menu_unblock() {
  pick_user "Unblock manual - pilih user" || { pause; return; }
  "$QUOTA_BIN" --unblock "$PICKED"
  pause
}

main_menu() {
  while :; do
    clear
    echo -e "${CYN}─────────────────────────────────────────────${NC}"
    echo -e "${CYN}        SSH Bandwidth Quota Manager${NC}"
    echo -e "${CYN}─────────────────────────────────────────────${NC}"
    echo
    echo "  1) Set / ubah quota per-user"
    echo "  2) Reset usage (zero-out + auto-unblock kalau blocked)"
    echo "  3) Block manual"
    echo "  4) Unblock manual"
    echo "  5) Lihat status semua user (cek-quota-ssh)"
    echo "  0) Keluar"
    echo
    read -rp "Pilihan: " opt
    case "$opt" in
      1) menu_set_quota ;;
      2) menu_reset ;;
      3) menu_block ;;
      4) menu_unblock ;;
      5) /usr/local/sbin/cek-quota-ssh 2>/dev/null || cek-quota-ssh; pause ;;
      0) exit 0 ;;
      *) ;;
    esac
  done
}

main_menu
