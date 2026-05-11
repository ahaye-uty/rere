#!/bin/bash
# ========================================================
# quota-xray.sh
#
# Per-user Xray bandwidth quota tracker + auto-enforcer.
# Dipanggil cron tiap 1 menit: pakai `xray api statsquery -reset` untuk
# ambil delta bytes (uplink + downlink) per-user, akumulasi ke
# /usr/local/etc/xray/quota-xray.db. Kalau user melebihi quota bulanannya,
# UUID/password di config.json diganti sentinel sehingga koneksi putus dan
# tidak bisa reconnect sampai di-reset (manual atau awal bulan).
#
# DB format (pipe-separated, satu baris per user):
#   USER|LIMIT_MB|USED_BYTES|STATUS|RESET_DATE
#   STATUS in: active | blocked | unlimited
#   LIMIT_MB 0 = no quota check (kalau STATUS=unlimited)
#
# Default kuota baru: 250 GiB (256000 MB), override via env DEFAULT_QUOTA_MB.
#
# Mode:
#   quota-xray                 -> akumulasi & enforce (default, dipanggil cron)
#   quota-xray --reset         -> reset USED_BYTES + auto-unblock semua user
#   quota-xray --reset USER    -> reset USED_BYTES untuk USER + unblock kalau blocked
#   quota-xray --monthly-reset -> alias --reset (dipanggil cron awal bulan)
#   quota-xray --block USER    -> manual block USER sekarang
#   quota-xray --unblock USER  -> manual unblock USER sekarang
# ========================================================

set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

DB="/usr/local/etc/xray/quota-xray.db"
CFG="/usr/local/etc/xray/config.json"
LOG="/var/log/quota-xray.log"
BLOCKED_DIR="/usr/local/etc/xray/quota-blocked"
API_ADDR="127.0.0.1:10085"
SENTINEL_UUID="00000000-0000-0000-0000-000000000000"
SENTINEL_PASSWORD="quota-blocked-no-access"
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

LOCK="/var/lock/quota-xray.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
  exit 0
fi

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

extract_user_creds_from_cfg() {
  local user="$1"
  awk -v u="$user" '
    BEGIN { proto = "" }
    /#vmess$/  { proto = "vmess" }
    /#vless$/  { proto = "vless" }
    /#trojan$/ { proto = "trojan" }
    {
      if (index($0, "\"email\"") > 0 && index($0, "\"" u "\"") > 0) {
        if (proto == "vmess" || proto == "vless") {
          if (match($0, /"id"[ \t]*:[ \t]*"[^"]+"/)) {
            s = substr($0, RSTART, RLENGTH)
            sub(/.*"id"[ \t]*:[ \t]*"/, "", s)
            sub(/".*/, "", s)
            if (!(proto in seen)) {
              print proto ":" s
              seen[proto] = 1
            }
          }
        } else if (proto == "trojan") {
          if (match($0, /"password"[ \t]*:[ \t]*"[^"]+"/)) {
            s = substr($0, RSTART, RLENGTH)
            sub(/.*"password"[ \t]*:[ \t]*"/, "", s)
            sub(/".*/, "", s)
            if (!("trojan" in seen)) {
              print "trojan:" s
              seen["trojan"] = 1
            }
          }
        }
      }
    }
  ' "$CFG"
}

block_user() {
  local user="$1"
  local f="$BLOCKED_DIR/$user"
  extract_user_creds_from_cfg "$user" > "$f"
  if [ ! -s "$f" ]; then
    rm -f "$f"
    return 1
  fi
  sed -i -E '/"email"[[:space:]]*:[[:space:]]*"'"$user"'"/{
    s/("id"[[:space:]]*:[[:space:]]*")[^"]+(")/\1'"$SENTINEL_UUID"'\2/g
    s/("password"[[:space:]]*:[[:space:]]*")[^"]+(")/\1'"$SENTINEL_PASSWORD"'\2/g
  }' "$CFG"
  return 0
}

unblock_user() {
  local user="$1"
  local f="$BLOCKED_DIR/$user"
  [ -f "$f" ] || return 0
  local tmp
  tmp=$(mktemp)
  awk -v u="$user" -v saved="$f" '
    BEGIN {
      proto = ""
      while ((getline line < saved) > 0) {
        idx = index(line, ":")
        if (idx > 0) {
          k = substr(line, 1, idx-1)
          v = substr(line, idx+1)
          val[k] = v
        }
      }
      close(saved)
    }
    /#vmess$/  { proto = "vmess" }
    /#vless$/  { proto = "vless" }
    /#trojan$/ { proto = "trojan" }
    {
      if (index($0, "\"email\"") > 0 && index($0, "\"" u "\"") > 0) {
        if ((proto == "vmess" || proto == "vless") && (proto in val)) {
          gsub(/"id"[ \t]*:[ \t]*"[^"]+"/, "\"id\": \"" val[proto] "\"")
        } else if (proto == "trojan" && ("trojan" in val)) {
          gsub(/"password"[ \t]*:[ \t]*"[^"]+"/, "\"password\": \"" val["trojan"] "\"")
        }
      }
      print
    }
  ' "$CFG" > "$tmp" && mv "$tmp" "$CFG"
  rm -f "$f"
}

reload_xray() {
  if /usr/local/bin/xray run -test -c "$CFG" >/dev/null 2>&1; then
    systemctl restart xray >/dev/null 2>&1 || true
  else
    log "ERROR: xray rejects config after edit. Restart skipped."
  fi
}

# === Mode: --reset / --monthly-reset / --reset USER ===
if [ "${1:-}" = "--reset" ] || [ "${1:-}" = "--monthly-reset" ]; then
  target="${2:-}"
  reload_needed=0
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
      reload_needed=1
      log "RESET+UNBLOCK: user=$user"
    else
      log "RESET: user=$user prev_used=$used"
    fi
    echo "$user|$limit_mb|0|$status|$new_rdate" >> "$tmp"
  done < "$DB"
  mv "$tmp" "$DB"
  [ "$reload_needed" -eq 1 ] && reload_xray
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
    echo "User $user tidak ditemukan di config.json."
    exit 1
  fi
  reload_xray
  limit=$(db_get_field "$user" 2); [ -z "$limit" ] && limit=0
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
  reload_xray
  limit=$(db_get_field "$user" 2); [ -z "$limit" ] && limit=0
  used=$(db_get_field "$user" 3);  [ -z "$used"  ] && used=0
  rdate=$(db_get_field "$user" 5); [ -z "$rdate" ] && rdate=$(next_reset_date)
  db_upsert "$user" "$limit" "$used" "active" "$rdate"
  log "MANUAL UNBLOCK: user=$user"
  echo "User $user di-unblock."
  exit 0
fi

# === Default: poll stats, accumulate, enforce ===
[ -x /usr/local/bin/xray ] || { log "ERROR: /usr/local/bin/xray not found"; exit 0; }
systemctl is-active --quiet xray || { log "INFO: xray not active, skip tick"; exit 0; }
command -v jq >/dev/null 2>&1 || { log "ERROR: jq not installed"; exit 0; }

STATS_JSON=$(/usr/local/bin/xray api statsquery --server="$API_ADDR" -pattern "user>>>" -reset 2>/dev/null || true)
if [ -z "$STATS_JSON" ]; then
  exit 0
fi

declare -A DELTA
while read -r name value; do
  [ -z "$name" ] && continue
  user=$(echo "$name" | sed -nE 's|^user>>>([^>]+)>>>traffic>>>.*|\1|p')
  [ -z "$user" ] && continue
  case "$value" in ''|*[!0-9]*) value=0 ;; esac
  DELTA["$user"]=$(( ${DELTA["$user"]:-0} + value ))
done < <(echo "$STATS_JSON" | jq -r '.stat[]? | "\(.name) \(.value // 0)"' 2>/dev/null)

declare -A SEEN
TMP=$(mktemp)
new_block=0
RDATE_NEXT="$(next_reset_date)"
TODAY="$(date +%Y-%m-%d)"
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
[ "$new_block" -eq 1 ] && reload_xray
exit 0
