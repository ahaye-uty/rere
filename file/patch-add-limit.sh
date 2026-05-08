#!/bin/bash
# ========================================================
# patch-add-limit.sh
#
# Patch add-ssh, add-vmess, add-vless, add-tr (dan -gege variants)
# untuk menambah pilihan Limit IP (1 atau 2) saat buat akun.
# Data disimpan di /usr/local/etc/xray/limit-ip.db
#
# Format DB: username limit_value
# Contoh:    john 1
#            jane 2
#
# Idempotent: aman di-run berkali-kali.
#
# Argumen: $1 = path direktori scripts (default /usr/local/sbin)
# ========================================================

set -e

DIR="${1:-/usr/local/sbin}"
DB_FILE="/usr/local/etc/xray/limit-ip.db"

if [ ! -d "$DIR" ]; then
    echo "[patch-add-limit] ERROR: dir $DIR tidak ada."
    exit 1
fi

# Buat DB file kalau belum ada
touch "$DB_FILE" 2>/dev/null || true

# ---- Helper: snippet yang akan di-inject ----
# Untuk SSH (setelah "read -p Expired")
SSH_SNIPPET='read -p "Limit IP (1/2) [default 2]: " iplimit\n[[ "$iplimit" != "1" ]] \&\& iplimit=2\necho "$username $iplimit" >> /usr/local/etc/xray/limit-ip.db'

# Untuk Xray (setelah "read -p Expired")
XRAY_SNIPPET='read -p "Limit IP (1/2) [default 2]: " iplimit\n[[ "$iplimit" != "1" ]] \&\& iplimit=2\necho "$user $iplimit" >> /usr/local/etc/xray/limit-ip.db'

patched=0

# ---- Patch add-ssh & add-ssh-gege ----
for script in add-ssh add-ssh-gege; do
    FILE="$DIR/$script"
    [ ! -f "$FILE" ] && continue
    if grep -q "Limit IP" "$FILE"; then
        echo "[patch-add-limit] $script: sudah ter-patch, skip."
        continue
    fi
    # Insert after: read -p "Expired ( Days ): " masa
    if grep -q 'read -p "Expired ( Days ): " masa' "$FILE"; then
        sed -i '/read -p "Expired ( Days ): " masa/a '"$SSH_SNIPPET" "$FILE"
        echo "[patch-add-limit] $script: patched."
        patched=$((patched + 1))
    else
        echo "[patch-add-limit] WARNING: $script: pattern 'Expired' tidak ditemukan, skip."
    fi
done

# ---- Patch add-vmess, add-vmess-gege, add-vless, add-vless-gege ----
for script in add-vmess add-vmess-gege add-vless add-vless-gege; do
    FILE="$DIR/$script"
    [ ! -f "$FILE" ] && continue
    if grep -q "Limit IP" "$FILE"; then
        echo "[patch-add-limit] $script: sudah ter-patch, skip."
        continue
    fi
    if grep -q 'read -p "Expired (days): " masaaktif' "$FILE"; then
        sed -i '/read -p "Expired (days): " masaaktif/a '"$XRAY_SNIPPET" "$FILE"
        echo "[patch-add-limit] $script: patched."
        patched=$((patched + 1))
    else
        echo "[patch-add-limit] WARNING: $script: pattern 'Expired' tidak ditemukan, skip."
    fi
done

# ---- Patch add-tr & add-trojan-gege ----
for script in add-tr add-trojan-gege; do
    FILE="$DIR/$script"
    [ ! -f "$FILE" ] && continue
    if grep -q "Limit IP" "$FILE"; then
        echo "[patch-add-limit] $script: sudah ter-patch, skip."
        continue
    fi
    if grep -q 'read -p "Expired (days): " masaaktif' "$FILE"; then
        sed -i '/read -p "Expired (days): " masaaktif/a '"$XRAY_SNIPPET" "$FILE"
        echo "[patch-add-limit] $script: patched."
        patched=$((patched + 1))
    else
        echo "[patch-add-limit] WARNING: $script: pattern 'Expired' tidak ditemukan, skip."
    fi
done

echo "[patch-add-limit] Total patched: $patched scripts."
