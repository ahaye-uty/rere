#!/bin/bash
# ========================================================
# quota-ssh.sh
#
# Per-user SSH bandwidth quota tracker + auto-enforcer.
# Pakai iptables -m owner --uid-owner di chain QUOTA-SSH untuk count
# bytes per user. Akumulasi ke /usr/local/etc/quota-ssh.db, kalau user
# lewat quota bulanannya: account di-lock (usermod -L) + semua session
# SSH user di-kill. Reversible via --unblock atau reset bulanan otomatis.
#
# DB format (pipe-separated, satu baris per user):
#   USER|LIMIT_MB|USED_BYTES|STATUS|RESET_DATE
#   STATUS in: active | blocked | unlimited
#   LIMIT_MB 0 = no quota check (kalau STATUS=unlimited)
#
# Default kuota baru: 250 GiB (256000 MB), override via env DEFAULT_QUOTA_MB.
#
# Mode:
#   quota-ssh                  -> akumulasi & enforce (default, dipanggil cron)
#   quota-ssh --reset          -> reset USED_BYTES + auto-unblock semua user
#   quota-ssh --reset USER     -> reset USED_BYTES untuk USER + unblock kalau blocked
#   quota-ssh --monthly-reset  -> alias --reset (dipanggil cron awal bulan)
#   quota-ssh --block USER     -> manual block USER sekarang
#   quota-ssh --unblock USER   -> manual unblock USER sekarang
# ========================================================

set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

DB="/usr/local/etc/quota-ssh.db"
LOG="/var/log/quota-ssh.log"
BLOCKED_DIR="/usr/local/etc/quota-ssh-blocked"
CHAIN="QUOTA-SSH"
DEFAULT_QUOTA_MB="${DEFAULT_QUOTA_MB:-256000}"

mkdir -p "$BLOCKED_DIR"
[ -f "$DB" ]  || : > "$DB"
[ -f "$LOG" ] || : > "$LOG"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

LOCK="/var/lock/quota-ssh.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
  exit 0
fi

eligible_users() {
  awk -F: '($7=="/usr/sbin/nologin" || $7=="/bin/false" || $7=="/sbin/nologin") && $3>=1000 {print $1":"$3}' /etc/passwd
}

db_get_field() {
  local user="$1" idx="$2"
  awk -F'|' -v u="$user" -v i="$idx" '$1==u {print $i; exit}' "$DB"
}

db_upsert() {
  local tmp
  tmp=$(mktemp)
  awk -F'|' -v u="$1" 'BEGIN{OFS="|"} $1!=u {print}' "$DB" > "$tmp"
  echo "$1|$2|$3|$4|$5" >> "$tmp"
  mv "$tmp" "$DB"
}

ensure_chain() {
  iptables -L "$CHAIN" -n -w 5 >/dev/null 2>&1 || iptables -N "$CHAIN" -w 5 2>/dev/null
  iptables -C OUTPUT -j "$CHAIN" -w 5 2>/dev/null || iptables -I OUTPUT 1 -j "$CHAIN" -w 5 2>/dev/null
}

ensure_user_rule() {
  local user="$1" uid="$2"
  iptables -C "$CHAIN" -m owner --uid-owner "$uid" -m comment --comment "QUOTASSH:$user" -j RETURN -w 5 2>/dev/null \
    || iptables -A "$CHAIN" -m owner --uid-owner "$uid" -m comment --comment "QUOTASSH:$user" -j RETURN -w 5 2>/dev/null
}

remove_user_rule() {
  local user="$1" uid="$2"
  while iptables -C "$CHAIN" -m owner --uid-owner "$uid" -m comment --comment "QUOTASSH:$user" -j RETURN -w 5 2>/dev/null; do
    iptables -D "$CHAIN" -m owner --uid-owner "$uid" -m comment --comment "QUOTASSH:$user" -j RETURN -w 5 2>/dev/null || break
  done
}

block_user() {
  local user="$1"
  if ! getent passwd "$user" >/dev/null 2>&1; then
    return 1
  fi
  local shadow_line
  shadow_line=$(grep "^${user}:" /etc/shadow 2>/dev/null)
  if [ -z "$shadow_line" ]; then
    return 1
  fi
  echo "$shadow_line" > "$BLOCKED_DIR/$user"
  chmod 600 "$BLOCKED_DIR/$user"
  usermod -L "$user" >/dev/null 2>&1 || true
  pkill -KILL -u "$user" >/dev/null 2>&1 || true
  return 0
}

unblock_user() {
  local user="$1"
  local f="$BLOCKED_DIR/$user"
  if [ -s "$f" ]; then
    local saved
    saved=$(cat "$f")
    local tmp
    tmp=$(mktemp)
    if awk -F: -v u="$user" -v new="$saved" '$1==u {print new; found=1; next} {print} END{exit !found}' /etc/shadow > "$tmp"; then
      cat "$tmp" > /etc/shadow
      chmod 640 /etc/shadow
      chown root:shadow /etc/shadow 2>/dev/null || chown root:root /etc/shadow
    fi
    rm -f "$tmp" "$f"
  else
    usermod -U "$user" >/dev/null 2>&1 || true
  fi
}

# === Mode: --reset / --monthly-reset / --reset USER ===
if [ "${1:-}" = "--reset" ] || [ "${1:-}" = "--monthly-reset" ]; then
  target="${2:-}"
  tmp=$(mktemp)
  while IFS='|' read -r user limit_mb used status rdate; do
    [ -z "$user" ] && continue
    case "$user" in \#*) echo "$user|$limit_mb|$used|$status|$rdate" >> "$tmp"; continue ;; esac
    if [ -n "$target" ] && [ "$user" != "$target" ]; then
      echo "$user|$limit_mb|$used|$status|$rdate" >> "$tmp"
      continue
    fi
    new_rdate=$(date -d 'next month' +%Y-%m-01 2>/dev/null || date +%Y-%m-01)
    if [ "$status" = "blocked" ]; then
      unblock_user "$user"
      status=active
      log "RESET+UNBLOCK: user=$user"
    else
      log "RESET: user=$user prev_used=$used"
    fi
    echo "$user|$limit_mb|0|$status|$new_rdate" >> "$tmp"
  done < "$DB"
  mv "$tmp" "$DB"
  # Zero iptables counter for the chain (only for resetted users; simplest: zero all)
  if [ -z "$target" ]; then
    iptables -Z "$CHAIN" -w 5 2>/dev/null || true
  fi
  exit 0
fi

# === Mode: --block USER ===
if [ "${1:-}" = "--block" ] && [ -n "${2:-}" ]; then
  user="$2"
  status=$(db_get_field "$user" 4)
  if [ "$status" = "blocked" ]; then
    echo "User $user sudah blocked."
    exit 0
  fi
  if ! block_user "$user"; then
    echo "User $user tidak ditemukan / shadow line kosong."
    exit 1
  fi
  limit=$(db_get_field "$user" 2); [ -z "$limit" ] && limit="$DEFAULT_QUOTA_MB"
  used=$(db_get_field "$user" 3);  [ -z "$used"  ] && used=0
  rdate=$(db_get_field "$user" 5); [ -z "$rdate" ] && rdate=$(date +%Y-%m-01)
  db_upsert "$user" "$limit" "$used" "blocked" "$rdate"
  log "MANUAL BLOCK: user=$user"
  echo "User $user di-block."
  exit 0
fi

# === Mode: --unblock USER ===
if [ "${1:-}" = "--unblock" ] && [ -n "${2:-}" ]; then
  user="$2"
  status=$(db_get_field "$user" 4)
  if [ "$status" != "blocked" ]; then
    echo "User $user tidak dalam status blocked."
    exit 0
  fi
  unblock_user "$user"
  limit=$(db_get_field "$user" 2); [ -z "$limit" ] && limit="$DEFAULT_QUOTA_MB"
  used=$(db_get_field "$user" 3);  [ -z "$used"  ] && used=0
  rdate=$(db_get_field "$user" 5); [ -z "$rdate" ] && rdate=$(date +%Y-%m-01)
  db_upsert "$user" "$limit" "$used" "active" "$rdate"
  log "MANUAL UNBLOCK: user=$user"
  echo "User $user di-unblock."
  exit 0
fi

# === Default: ensure chain + rules, read counters, accumulate, enforce ===
ensure_chain

declare -A UID_OF
while IFS=: read -r user uid; do
  UID_OF["$user"]=$uid
  ensure_user_rule "$user" "$uid"
done < <(eligible_users)

RDATE_NOW="$(date +%Y-%m-01)"
for user in "${!UID_OF[@]}"; do
  if ! awk -F'|' -v u="$user" '$1==u {f=1; exit} END{exit !f}' "$DB"; then
    echo "$user|${DEFAULT_QUOTA_MB}|0|active|$RDATE_NOW" >> "$DB"
    log "AUTO-REGISTER: user=$user quota=${DEFAULT_QUOTA_MB}MB status=active"
  fi
done

SAVE=$(iptables-save -c 2>/dev/null | grep -E "^\[[0-9]+:[0-9]+\] -A $CHAIN .*QUOTASSH:" || true)
iptables -Z "$CHAIN" -w 5 2>/dev/null || true

declare -A DELTA
while IFS= read -r line; do
  [ -z "$line" ] && continue
  bytes=$(echo "$line" | sed -nE 's/^\[[0-9]+:([0-9]+)\] .*/\1/p')
  user=$(echo "$line" | sed -nE 's/.*--comment "?QUOTASSH:([^" ]+).*/\1/p')
  [ -z "$user" ] && continue
  case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
  DELTA["$user"]=$bytes
done <<< "$SAVE"

declare -A SEEN
TMP=$(mktemp)
new_block=0
while IFS='|' read -r user limit_mb used status rdate; do
  [ -z "$user" ] && continue
  case "$user" in \#*) echo "$user|$limit_mb|$used|$status|$rdate" >> "$TMP"; continue ;; esac
  SEEN["$user"]=1
  delta=${DELTA["$user"]:-0}
  case "$used"  in ''|*[!0-9]*) used=0  ;; esac
  case "$delta" in ''|*[!0-9]*) delta=0 ;; esac
  new_used=$(( used + delta ))
  [ -z "$rdate" ] && rdate=$(date +%Y-%m-01)
  if [ "$status" = "active" ] && [ -n "$limit_mb" ] && [ "$limit_mb" != "0" ]; then
    limit_bytes=$(( limit_mb * 1024 * 1024 ))
    if [ "$new_used" -ge "$limit_bytes" ]; then
      if block_user "$user"; then
        status=blocked
        new_block=1
        log "QUOTA EXCEEDED: user=$user used=$new_used bytes limit=${limit_mb}MB -> BLOCK"
      fi
    fi
  fi
  echo "$user|$limit_mb|$new_used|$status|$rdate" >> "$TMP"
done < "$DB"

for user in "${!DELTA[@]}"; do
  [ -n "${SEEN[$user]:-}" ] && continue
  delta=${DELTA[$user]}
  rdate=$(date +%Y-%m-01)
  limit_mb="$DEFAULT_QUOTA_MB"
  status=active
  if [ "$limit_mb" = "0" ]; then
    status=unlimited
  else
    limit_bytes=$(( limit_mb * 1024 * 1024 ))
    if [ "$delta" -ge "$limit_bytes" ]; then
      if block_user "$user"; then
        status=blocked
        new_block=1
        log "AUTO-TRACK+QUOTA EXCEEDED: user=$user used=$delta bytes limit=${limit_mb}MB -> BLOCK"
      fi
    fi
  fi
  echo "$user|$limit_mb|$delta|$status|$rdate" >> "$TMP"
  log "AUTO-TRACK: user=$user quota=${limit_mb}MB status=$status"
done

mv "$TMP" "$DB"
exit 0
