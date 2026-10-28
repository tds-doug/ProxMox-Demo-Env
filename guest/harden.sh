#!/usr/bin/env bash
# guest/harden.sh - runs INSIDE the container as root. Practical hardening for an
# internal demo host. Idempotent. Never creates, resets, prints or logs passwords.
#
# Deliberately NOT done (see docs/security.md): sysctl tuning (kernel-owned, read-only
# or host-wide in LXC), UFW (duplicates the Proxmox firewall), fail2ban (ban actions
# need netfilter that unprivileged LXC lacks), auditd, ModSecurity/CRS.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8

: "${ADMIN_USER:?}"
: "${SSH_ALLOW_USERS:=$ADMIN_USER}"
: "${UNATTENDED_UPGRADES:=1}"

log() { printf '[guest/harden] %s\n' "$*"; }

# ---- SSH ----------------------------------------------------------------------
# Ubuntu 24.04's sshd_config begins with `Include /etc/ssh/sshd_config.d/*.conf`
# and sshd uses the FIRST value it sees, so a 00- drop-in beats cloud-init's 50-.
log "configuring sshd drop-in"
cat >/etc/ssh/sshd_config.d/00-demo-factory.conf <<CONF
# Managed by proxmox-demo-factory
PermitRootLogin no
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
MaxAuthTries 4
LoginGraceTime 30
MaxSessions 6
X11Forwarding no
AllowAgentForwarding no
AllowUsers ${SSH_ALLOW_USERS}
ClientAliveInterval 300
ClientAliveCountMax 2
CONF
chmod 644 /etc/ssh/sshd_config.d/00-demo-factory.conf
install -d -m 0755 /run/sshd   # sshd -t needs it even before the unit has started
sshd -t
systemctl enable ssh >/dev/null 2>&1
systemctl restart ssh   # restart (not reload) so ssh.socket-activated setups also pick it up

# ---- sudo: password required --------------------------------------------------
if grep -rqs 'NOPASSWD' /etc/sudoers /etc/sudoers.d 2>/dev/null; then
  echo "WARNING: NOPASSWD sudo rules exist; review /etc/sudoers.d" >&2
fi
usermod -aG sudo "$ADMIN_USER"

# ---- Apache ---------------------------------------------------------------------
log "hardening Apache"
a2dismod -f -q autoindex >/dev/null 2>&1 || true   # no directory listings, ever
# Named zz-* so it loads AFTER Ubuntu's security.conf (last ServerTokens wins).
cat >/etc/apache2/conf-available/zz-demo-hardening.conf <<'CONF'
# Managed by proxmox-demo-factory
ServerTokens Prod
ServerSignature Off
TraceEnable Off
FileETag MTime Size
<Directory /var/www/>
    Options -Indexes -Includes -ExecCGI
    AllowOverride None
</Directory>
<IfModule mod_headers.c>
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set Referrer-Policy "same-origin"
</IfModule>
CONF
a2enconf -q zz-demo-hardening >/dev/null
# PHP: don't advertise version, don't expose errors to clients.
for ini in /etc/php/*/apache2/conf.d; do
  [[ -d $ini ]] || continue
  printf 'expose_php=Off\ndisplay_errors=Off\n' >"$ini/99-demo-factory.ini"
done
apachectl configtest
systemctl restart apache2

# ---- MariaDB ----------------------------------------------------------------------
log "hardening MariaDB accounts"
mariadb --batch <<'SQL'
DROP DATABASE IF EXISTS test;
DROP USER IF EXISTS ''@'localhost';
DROP USER IF EXISTS 'root'@'%';
FLUSH PRIVILEGES;
SQL
# Anonymous users on other hosts (e.g. ''@hostname) and non-local roots.
mapfile -t extra < <(mariadb --batch --skip-column-names -e \
  "SELECT CONCAT(QUOTE(User),'@',QUOTE(Host)) FROM mysql.user WHERE User='' OR (User='root' AND Host NOT IN ('localhost','127.0.0.1','::1'))")
for acct in "${extra[@]}"; do
  [[ -n $acct ]] && mariadb -e "DROP USER IF EXISTS $acct"
done

# ---- Updates ------------------------------------------------------------------------
if [[ $UNATTENDED_UPGRADES == 1 ]]; then
  log "enabling unattended security upgrades"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends unattended-upgrades >/dev/null
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF
  cat >/etc/apt/apt.conf.d/52demo-factory-upgrades <<'CONF'
// Security pocket only (Ubuntu default origins), never reboot automatically.
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
CONF
  systemctl enable unattended-upgrades >/dev/null 2>&1 || true
fi

# ---- Permissions & file hygiene ------------------------------------------------------
chmod 0750 /etc/demo-factory
[[ -f /etc/demo-factory/db.cnf ]] && chmod 0640 /etc/demo-factory/db.cnf
home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
chmod 0750 "$home"
[[ -d $home/.ssh ]] && chmod 0700 "$home/.ssh"
[[ -f $home/.ssh/authorized_keys ]] && chmod 0600 "$home/.ssh/authorized_keys"
# Make sure no password material lingers in the factory working directory.
find /opt/demo-factory -maxdepth 1 -type f ! -name '*.sh' -delete 2>/dev/null || true

# ---- Listening sockets sanity check -----------------------------------------------------
log "listening TCP sockets:"
ss -ltnH | awk '{print "  " $4}'
log "hardening complete"
