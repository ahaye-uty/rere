#!/usr/bin/env bash
# ============================================================================
# setup-fail2ban.sh
# Pasang & konfigurasi fail2ban untuk VPS rere (OpenSSH multi-port + Dropbear).
# Idempotent: aman dijalankan ulang. Tidak mengganggu konfigurasi service lain.
#
# Jail yang aktif:
#   - sshd      port 22, 109, 3303 (sesuai install.sh)
#   - dropbear  port 111
#   - recidive  ban panjang utk attacker yg sudah pernah di-ban
#
# Jalankan di VPS lama (yang belum punya fail2ban):
#   bash <(curl -sL https://raw.githubusercontent.com/sugengagung2020-maker/rere/main/file/setup-fail2ban.sh)
# ============================================================================

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "[setup-fail2ban] Harus dijalankan sebagai root." >&2
    exit 1
fi

echo "[setup-fail2ban] Installing fail2ban..."
DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban >/dev/null

mkdir -p /etc/fail2ban/jail.d

# Tulis jail.local (override aman terhadap upgrade package).
cat > /etc/fail2ban/jail.local <<'EOF'
# Managed by sugengagung2020-maker/rere installer.
# Edit di sini, jangan di /etc/fail2ban/jail.conf (akan ditimpa upgrade package).

[DEFAULT]
# Whitelist localhost. sslh-internal forward koneksi SSH dari 127.0.0.1,
# jadi gagal-login dari localhost JANGAN sampai bikin VPS ke-ban diri sendiri.
ignoreip = 127.0.0.1/8 ::1

# Default: 5x gagal dalam 10 menit -> ban 1 jam.
bantime  = 1h
findtime = 10m
maxretry = 5

# Pakai iptables-multiport. Cocok dengan aturan iptables existing di repo ini.
banaction = iptables-multiport

[sshd]
enabled  = true
port     = 22,109,3303
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 5

[dropbear]
enabled  = true
port     = 111
filter   = dropbear
logpath  = /var/log/auth.log
maxretry = 5

[recidive]
# Untuk attacker yg sudah pernah ke-ban -> ban 1 minggu.
enabled  = true
bantime  = 1w
findtime = 1d
maxretry = 3
EOF

# Pastikan filter dropbear tersedia. Di Ubuntu 20.04 (fail2ban 0.11.x) sudah ada.
if [ ! -f /etc/fail2ban/filter.d/dropbear.conf ]; then
    cat > /etc/fail2ban/filter.d/dropbear.conf <<'EOF'
[INCLUDES]
before = common.conf

[Definition]
_daemon = dropbear

failregex = ^%(__prefix_line)sbad password attempt for .* from <HOST>:\d+\s*$
            ^%(__prefix_line)sLogin attempt for nonexistent user (\'.*\' )?from <HOST>:\d+\s*$
            ^%(__prefix_line)sexit before auth.*\(user '.+', \d+ fails\): Max auth tries reached - user '.+' from <HOST>:\d+\s*$

ignoreregex =
EOF
fi

systemctl enable fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban

# Verifikasi service jalan & jail aktif.
sleep 1
if systemctl is-active --quiet fail2ban; then
    echo "[setup-fail2ban] OK: fail2ban service running."
else
    echo "[setup-fail2ban] FAIL: fail2ban tidak running. Cek 'journalctl -u fail2ban -n 50'." >&2
    exit 1
fi

if command -v fail2ban-client >/dev/null 2>&1; then
    echo "[setup-fail2ban] Status jail:"
    fail2ban-client status | sed 's/^/    /' || true
fi

echo "[setup-fail2ban] SELESAI. Untuk lihat ban list: fail2ban-client status sshd"
