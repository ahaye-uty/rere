#!/bin/bash
# ========================================================
# quota-ssh.sh
#
# Per-user SSH bandwidth quota tracker + auto-enforcer.
#
# Bidirectional counting (out + in) via dua chain iptables:
#   QUOTA-SSH    (attached ke OUTPUT)
#                CONNMARK --set-mark UID per user (tag setiap koneksi
#                yang dibuka oleh user-owned process). Plus rule RETURN
#                per user dengan -m owner --uid-owner sebagai counter
#                untuk bytes outgoing.
#   QUOTA-SSH-IN (attached ke INPUT)
#                RETURN per user dengan -m connmark --mark UID sebagai
#                counter untuk bytes incoming dari koneksi yg sudah
#                ke-tag CONNMARK.
#
# Total bytes per user per tick = sum(OUT counter) + sum(IN counter).
# Akumulasi ke /usr/local/etc/quota-ssh.db. Kalau user lewat quota:
# account di-lock (usermod -L) + semua session SSH user di-kill.
# Reversible via --unblock atau reset bulanan otomatis.
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
CHAIN_OUT="QUOTA-SSH"
CHAIN_IN="QUOTA-SSH-IN"
DEFAULT_QUOTA_MB="${DEFAULT_QUOTA_MB:-256000}"

mkdir -p "$BLOCKED_DIR"
[ -f "$DB" ]  || : > "$DB"
[ -f "$LOG" ] || : > "$LOG"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# RESET_DATE = tanggal reset BERIKUTNYA (= tanggal 1 bulan depan).
# Pakai `date -d 'next month'` (GNU date). Fallback ke awk kalo gak ada.
next_reset_date() {
  date -d 'next month' +%Y-%m-01 2>/dev/null && return
  awk -v y="$(date +%Y)" -v m="$(date +%m)" 'BEGIN{
    m=m+1; if (m>12){m=1; y=y+1}
    printf "%04d-%02d-01\n", y, m
  }'
}

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
  iptables -L "$CHAIN_OUT" -n -w 5 >/dev/null 2>&1 || iptables -N "$CHAIN_OUT" -w 5 2>/dev/null
  iptables -C OUTPUT -j "$CHAIN_OUT" -w 5 2>/dev/null || iptables -I OUTPUT 1 -j "$CHAIN_OUT" -w 5 2>/dev/null
  iptables -L "$CHAIN_IN" -n -w 5 >/dev/null 2>&1 || iptables -N "$CHAIN_IN" -w 5 2>/dev/null
  iptables -C INPUT -j "$CHAIN_IN" -w 5 2>/dev/null || iptables -I INPUT 1 -j "$CHAIN_IN" -w 5 2>/dev/null
}

ensure_user_rule() {
  local user="$1" uid="$2"
  # CONNMARK --set-mark di OUTPUT (NON-TERMINATING) harus di posisi atas
  # supaya fire sebelum rule RETURN per user. Idempotent via -C check.
  if ! iptables -C "$CHAIN_OUT" -m owner --uid-owner "$uid" -j CONNMARK --set-mark "$uid" -w 5 2>/dev/null; then
    iptables -I "$CHAIN_OUT" 1 -m owner --uid-owner "$uid" -j CONNMARK --set-mark "$uid" -w 5 2>/dev/null \
      || log "WARNING: CONNMARK target not available, bidirectional counting disabled for $user"
  fi
  # OUT counter (append at bottom)
  iptables -C "$CHAIN_OUT" -m owner --uid-owner "$uid" -m comment --comment "QUOTASSH:$user" -j RETURN -w 5 2>/dev/null \
    || iptables -A "$CHAIN_OUT" -m owner --uid-owner "$uid" -m comment --comment "QUOTASSH:$user" -j RETURN -w 5 2>/dev/null
  # IN counter via connmark
  if ! iptables -C "$CHAIN_IN" -m connmark --mark "$uid" -m comment --comment "QUOTASSH:$user" -j RETURN -w 5 2>/dev/null; then
    iptables -A "$CHAIN_IN" -m connmark --mark "$uid" -m comment --comment "QUOTASSH:$user" -j RETURN -w 5 2>/dev/null \
      || log "WARNING: connmark match not available, INPUT counting disabled for $user"
  fi
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
    new_rdate=$(next_reset_date)
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
  if [ -z "$target" ]; then
    iptables -Z "$CHAIN_OUT" -w 5 2>/dev/null || true
    iptables -Z "$CHAIN_IN"  -w 5 2>/dev/null || true
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
  rdate=$(db_get_field "$user" 5); [ -z "$rdate" ] && rdate=$(next_reset_date)
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
  rdate=$(db_get_field "$user" 5); [ -z "$rdate" ] && rdate=$(next_reset_date)
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

RDATE_NEXT="$(next_reset_date)"
TODAY="$(date +%Y-%m-%d)"
for user in "${!UID_OF[@]}"; do
  if ! awk -F'|' -v u="$user" '$1==u {f=1; exit} END{exit !f}' "$DB"; then
    echo "$user|${DEFAULT_QUOTA_MB}|0|active|$RDATE_NEXT" >> "$DB"
    log "AUTO-REGISTER: user=$user quota=${DEFAULT_QUOTA_MB}MB status=active"
  fi
done

SAVE=$(iptables-save -c 2>/dev/null | grep -E "^\[[0-9]+:[0-9]+\] -A ($CHAIN_OUT|$CHAIN_IN) .*QUOTASSH:" || true)
iptables -Z "$CHAIN_OUT" -w 5 2>/dev/null || true
iptables -Z "$CHAIN_IN"  -w 5 2>/dev/null || true

declare -A DELTA
while IFS= read -r line; do
  [ -z "$line" ] && continue
  bytes=$(echo "$line" | sed -nE 's/^\[[0-9]+:([0-9]+)\] .*/\1/p')
  user=$(echo "$line" | sed -nE 's/.*--comment "?QUOTASSH:([^" ]+).*/\1/p')
  [ -z "$user" ] && continue
  case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
  prev=${DELTA["$user"]:-0}
  DELTA["$user"]=$(( prev + bytes ))
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
  # Migrasi: kalau RESET_DATE udah lewat (lex compare YYYY-MM-DD), advance ke
  # tanggal 1 bulan depan. Cover row lama yg pernah di-set ke awal bulan ini.
  if [ -z "$rdate" ] || [[ "$rdate" < "$TODAY" ]]; then
    rdate="$RDATE_NEXT"
  fi
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
  rdate="$RDATE_NEXT"
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
