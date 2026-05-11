#!/bin/bash
# ========================================================
# uninstall.sh
#
# Hapus tuntas autoscript Rere dari VPS. Stop+disable semua
# service, apt purge package proxy-spesifik, hapus config dir
# + binary + systemd unit + cron entry + iptables rules, dan
# (opsional) hapus akun VPN.
#
# DESTRUCTIVE. Idempotent (aman di-run berkali-kali).
#
# Cara pakai:
#   bash <(curl -sL https://raw.githubusercontent.com/ahaye-uty/rere/main/file/uninstall.sh)
#
# Flag:
#   --yes           Skip confirmation prompt (untuk pemakaian otomatis).
#   --keep-packages Jangan apt-purge package (cuma hapus config + service).
#   --keep-users    Jangan hapus akun VPN (UID>=1000 + shell nologin/false).
#
# Yang DI-HAPUS:
#   - Service: xray, nginx, sslh, sslh-internal, stunnel-ssh, dropbear,
#     udp-custom, noobzvpns, badvpn, proxy, server (REST API), danted,
#     fail2ban.
#   - Package (apt purge): sslh, stunnel4, dante-server, libnginx-mod-stream,
#     nginx, fail2ban, dropbear. (curl/wget/jq/iptables/perl/dll TIDAK
#     di-purge karena umum dipakai paket lain.)
#   - Xray-core (lewat installer XTLS standar atau manual rm).
#   - Cron entries: limit-ip, quota-xray, quota-ssh, xp, backup, access.log.
#   - iptables: chain QUOTA-SSH, QUOTA-SSH-IN, LIMIT-UDP-CUSTOM, LIMIT-IP
#     (kalau ada) + NAT redirect 443/80 yang dipasang installer.
#   - File: /usr/local/etc/{xray,quota-*}, /etc/{udp,noobzvpns,sslh,stunnel,
#     api,issue.net,xray}, /var/log/{xray,quota-*}, /root/{.acme.sh,.config/rclone,
#     domain,.ip}, /etc/current_version.
#   - Binary CLI: menu, add-*, del-*, cek-*, set-*, sshman, vmessman, vlessman,
#     trojanman, quota-*, limit-ip, proxy, badvpn, /usr/bin/{server,noobzvpns}.
#   - Modifikasi: line "Port 109"/"Port 3303"/"Banner" di sshd_config,
#     "nameserver 1.1.1.1" di /etc/resolv.conf, "menu" di /root/.profile.
#   - (Opsional, default ya) Akun VPN: semua user UID>=1000 dengan shell
#     /usr/sbin/nologin /bin/false /sbin/nologin.
#
# Yang TIDAK DI-HAPUS:
#   - Akun admin (shell login normal) + root.
#   - SSH host keys.
#   - Hostname, networking dasar OS.
#   - Package umum (curl, wget, jq, iptables, dll).
# ========================================================

set -u

YES=0
KEEP_PACKAGES=0
KEEP_USERS=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y)         YES=1 ;;
        --keep-packages)  KEEP_PACKAGES=1 ;;
        --keep-users)     KEEP_USERS=1 ;;
        -h|--help)
            grep -E '^#( |!)' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "[uninstall] ERROR: harus dijalankan sebagai root." >&2
    exit 1
fi

log() { echo -e "[uninstall] $*"; }

# ---------- Confirmation gate ----------
if [ "$YES" -ne 1 ]; then
    cat <<'WARN'
========================================================
 PERINGATAN: Script ini akan menghapus TOTAL autoscript Rere dari VPS.
 - Semua service VPN (xray, nginx, sslh, dropbear, udp-custom, dll) di-stop & purge.
 - Semua config + cert + DB + log di-hapus.
 - Semua akun VPN (UID>=1000 + shell nologin) di-hapus
   (kecuali pak pakai --keep-users).
 - SSH admin akun + root TIDAK disentuh.
 OPERASI INI TIDAK BISA DI-UNDO. Backup dulu kalau ada data penting.
========================================================
WARN
    printf "Ketik 'UNINSTALL' (huruf besar) untuk konfirmasi: "
    read -r CONFIRM
    if [ "$CONFIRM" != "UNINSTALL" ]; then
        echo "[uninstall] Batal. Tidak ada perubahan."
        exit 0
    fi
fi

# ---------- 1. Stop & disable services ----------
SERVICES=(
    xray
    nginx
    sslh sslh-internal stunnel-ssh
    dropbear
    udp-custom noobzvpns badvpn
    proxy server
    danted
    fail2ban
    v2ray
)
log "Stop + disable services..."
for svc in "${SERVICES[@]}"; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
done

# ---------- 2. Hapus systemd unit files yg dibikin installer ----------
log "Hapus systemd unit files custom..."
rm -f \
    /etc/systemd/system/server.service \
    /etc/systemd/system/proxy.service \
    /etc/systemd/system/badvpn.service \
    /etc/systemd/system/udp-custom.service \
    /etc/systemd/system/noobzvpns.service \
    /etc/systemd/system/sslh-internal.service \
    /etc/systemd/system/stunnel-ssh.service
# Bersihkan drop-in ReadWriteDirectories=/var/log di danted.service
if [ -f /usr/lib/systemd/system/danted.service ]; then
    sed -i '\|^ReadWriteDirectories=/var/log$|d' /usr/lib/systemd/system/danted.service 2>/dev/null || true
fi
systemctl daemon-reload 2>/dev/null || true

# ---------- 3. Uninstall Xray-core ----------
log "Uninstall Xray-core..."
if [ -x /usr/local/bin/xray ] || [ -d /usr/local/etc/xray ]; then
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge 2>/dev/null \
        || true
fi
rm -rf /usr/local/etc/xray /etc/xray /var/log/xray
rm -f /usr/local/bin/xray

# ---------- 4. Apt purge package proxy-spesifik ----------
if [ "$KEEP_PACKAGES" -eq 0 ]; then
    log "Apt purge package proxy-spesifik..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get purge -y \
        sslh stunnel4 dante-server \
        libnginx-mod-stream nginx nginx-common nginx-core \
        fail2ban dropbear 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
else
    log "(skip) --keep-packages, tidak apt-purge."
fi

# ---------- 5. Hapus config dir + cert + log ----------
log "Hapus config + cert + log dir..."
rm -rf \
    /etc/sslh /var/run/sslh \
    /etc/stunnel /var/run/stunnel-ssh.pid \
    /etc/udp \
    /etc/noobzvpns \
    /etc/danted.conf /var/log/danted.log \
    /etc/api \
    /etc/nginx \
    /etc/fail2ban \
    /usr/local/etc/quota-xray.conf /usr/local/etc/quota-ssh.conf \
    /usr/local/etc/quota-ssh-blocked \
    /var/log/quota-xray.log /var/log/quota-ssh.log /var/log/limit-ip.log \
    /root/.acme.sh \
    /root/.config/rclone \
    /etc/current_version \
    /etc/issue.net \
    /etc/default/sslh
rm -f /root/domain /root/.ip

# ---------- 6. Hapus binary CLI di /usr/local/{bin,sbin} ----------
log "Hapus binary + CLI scripts..."
rm -f \
    /usr/local/bin/limit-ip \
    /usr/local/bin/sshman \
    /usr/local/bin/badvpn \
    /usr/local/bin/quota-xray \
    /usr/local/bin/quota-ssh \
    /usr/local/bin/proxy \
    /usr/local/bin/rclone \
    /usr/bin/server \
    /usr/bin/noobzvpns
# Menu utama + semua wrapper di /usr/local/sbin (di-unzip dari main.zip + patch)
for f in \
    menu add-ssh add-ssh-gege add-vmess add-vmess-gege add-vless add-vless-gege \
    add-tr add-trojan-gege add-host add-domain add-noobz \
    del-ssh del-vmess del-vless del-tr del-noobz \
    cek-ssh cek-vmess cek-vless cek-tr cek-noobz cek-limit cek-quota cek-quota-ssh \
    set-limit set-quota set-quota-ssh \
    renew-ssh renew-vmess renew-vless renew-tr \
    backup restart-all xp dom \
    sshman vmessman vlessman trojanman ; do
    rm -f "/usr/local/sbin/$f" "/usr/local/bin/$f"
done
rm -rf /usr/local/sbin/api

# ---------- 7. Hapus cron entries ----------
log "Bersihkan /etc/crontab dari entry autoscript..."
if [ -f /etc/crontab ]; then
    sed -i \
        -e '\|/var/log/xray/access.log|d' \
        -e '\|root xp$|d' \
        -e '\|root backup$|d' \
        -e '\|limit-ip|d' \
        -e '\|quota-xray|d' \
        -e '\|quota-ssh|d' \
        /etc/crontab
    systemctl restart cron 2>/dev/null || service cron restart 2>/dev/null || true
fi

# ---------- 8. Iptables: hapus chain custom + NAT redirect installer ----------
log "Flush iptables custom chain + NAT redirect installer..."
# Custom chains
for chain in QUOTA-SSH QUOTA-SSH-IN LIMIT-UDP-CUSTOM LIMIT-IP ; do
    if iptables -L "$chain" -n >/dev/null 2>&1; then
        # Detach dari semua hook
        while iptables -D OUTPUT -j "$chain" 2>/dev/null; do :; done
        while iptables -D INPUT  -j "$chain" 2>/dev/null; do :; done
        while iptables -D FORWARD -j "$chain" 2>/dev/null; do :; done
        iptables -F "$chain" 2>/dev/null || true
        iptables -X "$chain" 2>/dev/null || true
    fi
done
# NAT redirect yang dipasang install.sh
iptables -t nat -D PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 2443  2>/dev/null || true
iptables -t nat -D PREROUTING -p udp --dport 443 -j REDIRECT --to-port 36712 2>/dev/null || true
iptables -t nat -D PREROUTING -p tcp --dport 80  -j REDIRECT --to-port 2081  2>/dev/null || true
iptables -t nat -D PREROUTING -p udp --dport 80  -j REDIRECT --to-port 36712 2>/dev/null || true
iptables -t nat -D PREROUTING -p tcp --dport 80  -j REDIRECT --to-port 2080  2>/dev/null || true
# Persist
if [ -d /etc/iptables ]; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi

# ---------- 9. Revert sshd_config / resolv.conf / .profile ----------
log "Revert sshd_config (Port 109/3303, Banner)..."
SSHD=/etc/ssh/sshd_config
if [ -f "$SSHD" ]; then
    sed -i '/^Port 109$/d'      "$SSHD"
    sed -i '/^Port 3303$/d'     "$SSHD"
    sed -i '\|^Banner /etc/issue.net$|d' "$SSHD"
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
fi

log "Revert /etc/resolv.conf (hapus nameserver 1.1.1.1 yg di-append installer)..."
if [ -f /etc/resolv.conf ] && ! [ -L /etc/resolv.conf ]; then
    sed -i '/^nameserver 1.1.1.1$/d' /etc/resolv.conf
fi

log "Revert /root/.profile (hapus auto-run 'menu')..."
if [ -f /root/.profile ]; then
    sed -i '/^menu$/d' /root/.profile
fi

# Hapus dropbear leftover (file config kalo apt purge gagal)
rm -rf /etc/default/dropbear /etc/dropbear /etc/init.d/dropbear

# ---------- 10. Hapus akun VPN ----------
if [ "$KEEP_USERS" -eq 0 ]; then
    log "Hapus akun VPN (UID>=1000 + shell nologin/false)..."
    VPN_USERS=$(awk -F: '($7=="/usr/sbin/nologin" || $7=="/bin/false" || $7=="/sbin/nologin") && $3>=1000 {print $1}' /etc/passwd)
    if [ -n "$VPN_USERS" ]; then
        for u in $VPN_USERS; do
            log "  userdel $u"
            pkill -KILL -u "$u" 2>/dev/null || true
            userdel -r "$u" 2>/dev/null || userdel "$u" 2>/dev/null || true
        done
    else
        log "  (tidak ada akun VPN ke-detect)"
    fi
else
    log "(skip) --keep-users, akun VPN tidak dihapus."
fi

# ---------- 11. Bersihkan /etc/shells dari entry installer ----------
if [ -f /etc/shells ]; then
    # /bin/false biasanya bawaan; cuma hapus duplikat hasil append installer.
    # Hanya hapus jika muncul lebih dari sekali.
    if [ "$(grep -c '^/bin/false$' /etc/shells)" -gt 1 ]; then
        sed -i '0,/^\/bin\/false$/!{/^\/bin\/false$/d}' /etc/shells
    fi
    if [ "$(grep -c '^/usr/sbin/nologin$' /etc/shells)" -gt 1 ]; then
        sed -i '0,/^\/usr\/sbin\/nologin$/!{/^\/usr\/sbin\/nologin$/d}' /etc/shells
    fi
fi

# ---------- 12. Selesai ----------
echo
log "Selesai. Ringkasan verifikasi:"
echo "  systemctl status xray nginx sslh sslh-internal stunnel-ssh udp-custom noobzvpns 2>&1 | grep -E 'Active|loaded'"
echo "  ls /usr/local/etc/xray /etc/udp /etc/noobzvpns /etc/sslh /etc/stunnel 2>&1"
echo "  grep -E 'quota|limit-ip|xray|backup' /etc/crontab || echo '(no cron entry)'"
echo "  iptables -L QUOTA-SSH 2>&1 | head -3"
echo "  awk -F: '\$3>=1000 && (\$7~/nologin|false/) {print \$1}' /etc/passwd  # harus kosong"
echo
echo "Disarankan reboot VPS supaya port 443/80 ke-release total dan service residual ke-clean."
echo "  reboot"
