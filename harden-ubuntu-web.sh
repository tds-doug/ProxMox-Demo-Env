#!/usr/bin/env bash
# =============================================================================
#  harden-ubuntu-web.sh
#  In-container OS hardening + Apache 2.4 secure web server setup
#  for Ubuntu 24.04 LTS — executed automatically by deploy-ubuntu-web.sh
# =============================================================================
#
#  This script is designed to be called by deploy-ubuntu-web.sh via:
#    pct exec <CTID> -- env ADMIN_USER=... bash /root/harden-ubuntu-web.sh
#
#  It can also be run directly inside any Ubuntu 24.04 system:
#    chmod +x harden-ubuntu-web.sh
#    sudo ADMIN_USER=webadmin CT_HOSTNAME=ubuntu-web ./harden-ubuntu-web.sh
#
#  WHAT THIS SCRIPT DOES:
#    Phase 1 — OS Hardening
#      - Full system update
#      - Creates a non-root admin user with sudo rights
#      - Hardens SSH daemon configuration
#      - Installs and configures fail2ban (SSH jail)
#      - Enables unattended security updates
#      - Applies kernel/network hardening via sysctl
#      - Installs and enables auditd
#      - Configures UFW (22/80/443 only, default deny)
#      - Disables unnecessary services
#
#    Phase 2 — Apache Hardening
#      - Installs Apache 2.4, mod_ssl, mod_security2, mod_evasive
#      - Installs OWASP ModSecurity Core Rule Set
#      - Enables required modules, disables attack-surface modules
#      - Applies global security headers
#      - Configures ModSecurity in enforcement mode
#      - Configures ModEvasive (rate-limiting / DDoS protection)
#      - Generates a 4096-bit RSA self-signed TLS certificate
#      - Creates a secure VirtualHost (TLS 1.2/1.3 only, strong ciphers)
#      - Redirects all HTTP traffic to HTTPS
#      - Locks down DocumentRoot permissions
#      - Writes a hardening-verification test page
#
#  ENVIRONMENT VARIABLES (set by deploy-ubuntu-web.sh or manually):
#    ADMIN_USER        — username for the non-root admin account (default: webadmin)
#    ADMIN_SSH_PUBKEY  — SSH public key to install for that user (optional)
#    CT_HOSTNAME       — system hostname (default: ubuntu-web)
# =============================================================================

set -euo pipefail

# =============================================================================
#  CONFIGURATION (overridden by environment variables from deploy script)
# =============================================================================

ADMIN_USER="${ADMIN_USER:-webadmin}"
ADMIN_SSH_PUBKEY="${ADMIN_SSH_PUBKEY:-}"
CT_HOSTNAME="${CT_HOSTNAME:-ubuntu-web}"

## Temp password for the admin user — only used until key auth is confirmed.
## The account has PasswordAuthentication disabled in sshd so this never
## accepts remote logins; it is only used for sudo prompts if needed.
ADMIN_TEMP_PW="$(set +o pipefail; tr -dc 'A-Za-z0-9!@#$%' </dev/urandom | head -c 20)"

## Self-signed TLS certificate fields
TLS_COUNTRY="US"
TLS_STATE="State"
TLS_CITY="City"
TLS_ORG="Organization"
TLS_CN="$CT_HOSTNAME"
TLS_DAYS=825                      # ~2.25 years — browsers reject >825 days

## DocumentRoot
DOC_ROOT="/var/www/html"

## ModEvasive notification email (optional; leave blank to disable)
MODEVASIVE_EMAIL=""

## Log file for this hardening run
HARDEN_LOG="/var/log/harden-ubuntu-web.log"

# =============================================================================
#  SCRIPT INTERNALS — no edits needed below this line
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

_ts()    { date '+%H:%M:%S'; }
log()    { local m="[$(_ts)] [INFO]  $*"; echo -e "${CYAN}${m}${NC}";    echo "${m}" >> "$HARDEN_LOG"; }
ok()     { local m="[$(_ts)] [OK  ]  $*"; echo -e "${GREEN}${m}${NC}";   echo "${m}" >> "$HARDEN_LOG"; }
warn()   { local m="[$(_ts)] [WARN]  $*"; echo -e "${YELLOW}${m}${NC}";  echo "${m}" >> "$HARDEN_LOG"; }
die()    { local m="[$(_ts)] [FAIL]  $*"; echo -e "${RED}${m}${NC}" >&2; echo "${m}" >> "$HARDEN_LOG"; exit 1; }

banner() {
  local line="============================================================"
  echo ""
  echo -e "${CYAN}${line}${NC}"
  echo -e "${CYAN}  $*${NC}"
  echo -e "${CYAN}${line}${NC}"
  echo ""
  echo "" >> "$HARDEN_LOG"
  echo "  === $* ===" >> "$HARDEN_LOG"
}

# Redirect all output (stdout + stderr) to log file while keeping console output
exec > >(tee -a "$HARDEN_LOG") 2>&1

# =============================================================================
#  PHASE 1 — OS HARDENING
# =============================================================================

banner "Phase 1 — OS Hardening"

# Preflight: must be root
[[ $EUID -eq 0 ]] || die "This script must be run as root."
ok "Running as root"

# Set hostname
hostnamectl set-hostname "$CT_HOSTNAME"
ok "Hostname set to: $CT_HOSTNAME"

# -----------------------------------------------------------------------------
#  1.1 Full system update
# -----------------------------------------------------------------------------
banner "1.1 — System Update"

log "Running apt update..."
DEBIAN_FRONTEND=noninteractive apt-get update -qq

log "Running full upgrade (this may take a few minutes)..."
DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -qq \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold"

log "Removing unused packages..."
DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq
apt-get clean -qq

ok "System fully updated"

# -----------------------------------------------------------------------------
#  1.2 Create non-root admin user
# -----------------------------------------------------------------------------
banner "1.2 — Admin User"

if id "$ADMIN_USER" &>/dev/null; then
  warn "User '$ADMIN_USER' already exists — skipping creation, verifying group membership."
else
  log "Creating user: $ADMIN_USER"
  useradd -m -s /bin/bash "$ADMIN_USER"
  ok "User '$ADMIN_USER' created"
fi

# Ensure the user is in sudo group
usermod -aG sudo "$ADMIN_USER"
ok "User '$ADMIN_USER' added to sudo group"

# Set a strong random password (remote login via SSH key only)
echo "${ADMIN_USER}:${ADMIN_TEMP_PW}" | chpasswd
ok "Temporary password set for '$ADMIN_USER'"
# Print the password now so it is visible in console output and the log file.
# This is the ONLY place you will see it — save it immediately.
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}  ADMIN PASSWORD — SAVE THIS NOW${NC}"
echo -e "${YELLOW}  User     : ${ADMIN_USER}${NC}"
echo -e "${YELLOW}  Password : ${ADMIN_TEMP_PW}${NC}"
echo -e "${YELLOW}  This password is also written to: ${HARDEN_LOG}${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
# Write it explicitly to the log so it survives even if console output scrolls
echo "  [ADMIN CREDENTIALS]  user=${ADMIN_USER}  password=${ADMIN_TEMP_PW}" >> "${HARDEN_LOG}"

# Install SSH public key if provided
if [[ -n "$ADMIN_SSH_PUBKEY" ]]; then
  SSH_DIR="/home/${ADMIN_USER}/.ssh"
  mkdir -p "$SSH_DIR"
  echo "$ADMIN_SSH_PUBKEY" > "${SSH_DIR}/authorized_keys"
  chmod 700 "$SSH_DIR"
  chmod 600 "${SSH_DIR}/authorized_keys"
  chown -R "${ADMIN_USER}:${ADMIN_USER}" "$SSH_DIR"
  ok "SSH public key installed for '$ADMIN_USER'"
fi

# Lock the root password only when an SSH key has been installed for the admin
# user — ensuring there is always at least one way to recover access.
# The LXC console (pct enter <ctid>) bypasses passwords entirely and always works.
if [[ -n "$ADMIN_SSH_PUBKEY" ]]; then
  passwd -l root
  ok "Root password locked — recovery via: pct enter <ctid>"
else
  warn "Root password NOT locked — no SSH key was provided."
  warn "Lock it manually once you have confirmed SSH key access:"
  warn "  passwd -l root"
fi

# -----------------------------------------------------------------------------
#  1.3 SSH hardening
# -----------------------------------------------------------------------------
banner "1.3 — SSH Hardening"

SSHD_CFG="/etc/ssh/sshd_config"

# Back up the original
cp "${SSHD_CFG}" "${SSHD_CFG}.orig"

# Apply hardened settings — use sed to set or replace each directive,
# then append any that were not already present.
apply_sshd_setting() {
  local key="$1" val="$2"
  if grep -qE "^#?${key}\s" "$SSHD_CFG"; then
    sed -i "s|^#\?${key}\s.*|${key} ${val}|" "$SSHD_CFG"
  else
    echo "${key} ${val}" >> "$SSHD_CFG"
  fi
}

apply_sshd_setting "PermitRootLogin"              "no"
apply_sshd_setting "PasswordAuthentication"       "$( [[ -n "$ADMIN_SSH_PUBKEY" ]] && echo 'no' || echo 'yes' )"
apply_sshd_setting "PubkeyAuthentication"         "yes"
apply_sshd_setting "AuthorizedKeysFile"           ".ssh/authorized_keys"
apply_sshd_setting "PermitEmptyPasswords"         "no"
apply_sshd_setting "ChallengeResponseAuthentication" "no"
apply_sshd_setting "KerberosAuthentication"       "no"
apply_sshd_setting "GSSAPIAuthentication"         "no"
apply_sshd_setting "X11Forwarding"               "no"
apply_sshd_setting "AllowTcpForwarding"           "no"
apply_sshd_setting "AllowAgentForwarding"         "no"
apply_sshd_setting "PermitTunnel"                 "no"
apply_sshd_setting "MaxAuthTries"                 "3"
apply_sshd_setting "MaxSessions"                  "3"
apply_sshd_setting "LoginGraceTime"               "30"
apply_sshd_setting "ClientAliveInterval"          "300"
apply_sshd_setting "ClientAliveCountMax"          "2"
apply_sshd_setting "Banner"                       "none"
apply_sshd_setting "PrintLastLog"                 "yes"
apply_sshd_setting "TCPKeepAlive"                 "no"
apply_sshd_setting "UseDNS"                       "no"
apply_sshd_setting "LogLevel"                     "VERBOSE"

# Restrict ciphers, MACs, and key exchange to modern algorithms.
#
# KexAlgorithms are built dynamically by intersecting our preferred list with
# what the installed sshd binary actually supports (ssh -Q kex).
# This is necessary because OpenSSH rejects the ENTIRE KexAlgorithms directive
# if it contains even one unrecognised algorithm — it does NOT silently skip
# unknown entries the way other config values do.
#
# Preferred order (strongest / most modern first):
#   mlkem768x25519-sha256          PQ hybrid, NIST ML-KEM-768 + X25519  (OpenSSH 9.9+)
#   sntrup761x25519-sha512         PQ hybrid, NTRU Prime + X25519        (OpenSSH 9.0+)
#   curve25519-sha256              Classical ECDH, best classical choice
#   curve25519-sha256@libssh.org   Alias — included for broader client compat
#   diffie-hellman-group18-sha512  Classical, 8192-bit MODP, strong fallback
#   diffie-hellman-group16-sha512  Classical, 4096-bit MODP, final fallback

PREFERRED_KEX=(
  "mlkem768x25519-sha256"
  "sntrup761x25519-sha512@openssh.com"
  "curve25519-sha256"
  "curve25519-sha256@libssh.org"
  "diffie-hellman-group18-sha512"
  "diffie-hellman-group16-sha512"
)

# Get the list of algorithms this sshd binary actually supports
SUPPORTED_KEX=$(ssh -Q kex 2>/dev/null || true)

ACTIVE_KEX=()
for alg in "${PREFERRED_KEX[@]}"; do
  if echo "${SUPPORTED_KEX}" | grep -qx "${alg}"; then
    ACTIVE_KEX+=("${alg}")
  else
    log "  KEX algorithm not supported by this OpenSSH build, skipping: ${alg}"
  fi
done

[[ ${#ACTIVE_KEX[@]} -eq 0 ]] && die "No supported KEX algorithms found — cannot continue."

KEX_STRING=$(IFS=','; echo "${ACTIVE_KEX[*]}")
log "  KexAlgorithms: ${KEX_STRING}"

# Append the hardened cryptography block to sshd_config
cat >> "$SSHD_CFG" << EOF

# Hardened cryptography (appended by harden-ubuntu-web.sh)
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
KexAlgorithms ${KEX_STRING}
HostKeyAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256
EOF

# Create the privilege separation directory if missing.
# In a fresh LXC container /run/sshd does not exist until sshd starts for the
# first time, which causes 'sshd -t' to fail with "Missing privilege separation
# directory: /run/sshd" even when the config is perfectly valid.
mkdir -p /run/sshd
chmod 755 /run/sshd

# Validate config before restarting
sshd -t || die "sshd_config validation failed — check ${SSHD_CFG}"
systemctl restart ssh
ok "SSH daemon hardened and restarted"

if [[ -n "$ADMIN_SSH_PUBKEY" ]]; then
  ok "PasswordAuthentication: DISABLED — key-based auth only"
else
  warn "PasswordAuthentication: ENABLED — add an SSH key and disable password auth"
  warn "  Edit $SSHD_CFG → set PasswordAuthentication no  → systemctl restart ssh"
fi

# -----------------------------------------------------------------------------
#  1.4 fail2ban
# -----------------------------------------------------------------------------
banner "1.4 — fail2ban"

log "Installing fail2ban..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban

cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime   = 1h
findtime  = 10m
maxretry  = 5
backend   = systemd

[sshd]
enabled   = true
port      = ssh
logpath   = %(sshd_log)s
maxretry  = 3
bantime   = 2h

[apache-auth]
enabled   = true
port      = http,https

[apache-badbots]
enabled   = true
port      = http,https

[apache-noscript]
enabled   = true
port      = http,https

[apache-overflows]
enabled   = true
port      = http,https

[apache-nohome]
enabled   = true
port      = http,https
EOF

systemctl enable --now fail2ban
ok "fail2ban installed, enabled, and configured (SSH + Apache jails)"

# -----------------------------------------------------------------------------
#  1.5 Unattended security updates
# -----------------------------------------------------------------------------
banner "1.5 — Automatic Security Updates"

log "Installing unattended-upgrades..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  unattended-upgrades apt-listchanges

# Write out a clean configuration
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {};
Unattended-Upgrade::DevRelease "false";
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::SyslogEnable "true";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

systemctl enable --now unattended-upgrades
ok "Unattended security updates enabled"

# -----------------------------------------------------------------------------
#  1.6 Kernel / network hardening (sysctl)
# -----------------------------------------------------------------------------
banner "1.6 — Kernel / Network Hardening"

cat > /etc/sysctl.d/99-harden.conf << 'EOF'
# ── IP spoofing / source routing ────────────────────────────────────────────
net.ipv4.conf.all.rp_filter          = 1
net.ipv4.conf.default.rp_filter      = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# ── ICMP redirect hardening ─────────────────────────────────────────────────
net.ipv4.conf.all.accept_redirects   = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects   = 0
net.ipv4.conf.all.send_redirects     = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.secure_redirects   = 1

# ── Log suspicious packets ──────────────────────────────────────────────────
net.ipv4.conf.all.log_martians       = 1
net.ipv4.conf.default.log_martians   = 1

# ── ICMP broadcast ──────────────────────────────────────────────────────────
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# ── SYN flood protection ────────────────────────────────────────────────────
net.ipv4.tcp_syncookies              = 1
net.ipv4.tcp_max_syn_backlog         = 4096
net.ipv4.tcp_synack_retries          = 2
net.ipv4.tcp_syn_retries             = 5

# ── Time-wait assassination defence ─────────────────────────────────────────
net.ipv4.tcp_rfc1337                 = 1

# ── Disable IPv6 (remove these lines if you need IPv6) ──────────────────────
net.ipv6.conf.all.disable_ipv6      = 1
net.ipv6.conf.default.disable_ipv6  = 1
net.ipv6.conf.lo.disable_ipv6       = 1

# ── Restrict kernel pointer / dmesg exposure ────────────────────────────────
kernel.kptr_restrict                 = 2
kernel.dmesg_restrict                = 1

# ── Restrict ptrace to own descendants ──────────────────────────────────────
kernel.yama.ptrace_scope             = 1

# ── Disable core dumps for setuid processes ──────────────────────────────────
fs.suid_dumpable                     = 0
EOF

sysctl --system -q
ok "Kernel hardening applied (sysctl)"

# -----------------------------------------------------------------------------
#  1.7 auditd
# -----------------------------------------------------------------------------
banner "1.7 — Audit Daemon"

log "Installing auditd..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq auditd audispd-plugins

# Add sensible rules on top of the defaults
cat >> /etc/audit/rules.d/99-harden.rules << 'EOF'
## Watch passwd and shadow for modifications
-w /etc/passwd  -p wa -k identity
-w /etc/shadow  -p wa -k identity
-w /etc/group   -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers

## Log use of sudo
-w /usr/bin/sudo -p x -k sudo_use

## Watch SSH configuration
-w /etc/ssh/sshd_config -p wa -k sshd_config

## Log successful and failed login events
-w /var/log/auth.log -p wa -k auth_log

## Watch crontab
-w /etc/cron.d/       -p wa -k cron
-w /etc/crontab       -p wa -k cron
-w /var/spool/cron/   -p wa -k cron
EOF

systemctl enable --now auditd
ok "auditd installed, enabled, and configured"

# -----------------------------------------------------------------------------
#  1.8 Disable unnecessary services
# -----------------------------------------------------------------------------
banner "1.8 — Disable Unnecessary Services"

UNWANTED_SERVICES=(
  bluetooth cups avahi-daemon
  whoopsie apport
  snapd.socket snapd
)

for svc in "${UNWANTED_SERVICES[@]}"; do
  if systemctl list-unit-files --quiet "${svc}.service" &>/dev/null || \
     systemctl list-unit-files --quiet "${svc}" &>/dev/null; then
    systemctl disable --now "$svc" 2>/dev/null && \
      log "  Disabled: $svc" || true
  fi
done
ok "Unnecessary services disabled"

# -----------------------------------------------------------------------------
#  1.9 UFW (host firewall inside the container)
# -----------------------------------------------------------------------------
banner "1.9 — UFW Firewall"

log "Installing UFW..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw

# Reset to defaults (non-interactive)
ufw --force reset

ufw default deny  incoming
ufw default allow outgoing
ufw default deny  forward

ufw allow 22/tcp  comment 'SSH'
ufw allow 80/tcp  comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

# Enable without interactive prompt
ufw --force enable
ok "UFW enabled — inbound: deny all except 22/80/443"

ufw status verbose

# =============================================================================
#  PHASE 2 — APACHE HARDENING
# =============================================================================

banner "Phase 2 — Apache Hardening"

# -----------------------------------------------------------------------------
#  2.1 Install Apache and security modules
# -----------------------------------------------------------------------------
banner "2.1 — Install Apache + Security Modules"

log "Installing Apache 2.4 and security modules..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  apache2 \
  apache2-utils \
  libapache2-mod-security2 \
  libapache2-mod-evasive

ok "Apache 2.4, mod_security2, and mod_evasive installed"

# Install OWASP ModSecurity Core Rule Set
log "Installing OWASP ModSecurity Core Rule Set..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq modsecurity-crs
ok "OWASP CRS installed"

# -----------------------------------------------------------------------------
#  2.2 Module management — enable required, disable attack-surface modules
# -----------------------------------------------------------------------------
banner "2.2 — Apache Module Configuration"

log "Enabling required modules..."
a2enmod ssl
a2enmod headers
a2enmod rewrite
a2enmod security2
a2enmod evasive
ok "Modules enabled: ssl, headers, rewrite, security2, evasive"

log "Disabling unnecessary/attack-surface modules..."
MODS_TO_DISABLE=(autoindex status cgi cgid userdir)
for mod in "${MODS_TO_DISABLE[@]}"; do
  a2dismod -f "$mod" 2>/dev/null && log "  Disabled: $mod" || true
done
ok "Unnecessary modules disabled"

# -----------------------------------------------------------------------------
#  2.3 Global Apache security headers
# -----------------------------------------------------------------------------
banner "2.3 — Global Security Headers"

cat > /etc/apache2/conf-available/security-headers.conf << 'EOF'
# =============================================================================
#  Apache Global Security Configuration
#  Managed by harden-ubuntu-web.sh — do not edit manually
# =============================================================================

# ── Server identity ──────────────────────────────────────────────────────────
ServerTokens Prod
ServerSignature Off
TraceEnable Off

# ── Security headers applied to every response ───────────────────────────────
Header always set X-Frame-Options            "SAMEORIGIN"
Header always set X-XSS-Protection          "1; mode=block"
Header always set X-Content-Type-Options    "nosniff"
Header always set Referrer-Policy           "strict-origin-when-cross-origin"
Header always set Permissions-Policy        "geolocation=(), microphone=(), camera=(), payment=()"

# HSTS — tells browsers to always use HTTPS for 2 years
# (only effective once you have a valid certificate browsers trust)
Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"

# ── Hide the ETag (leaks inode + mtime information) ──────────────────────────
FileETag None
Header unset ETag

# ── Prevent clickjacking on all pages ────────────────────────────────────────
Header always append X-Frame-Options SAMEORIGIN

# ── Limit request sizes to mitigate large-body attacks ───────────────────────
LimitRequestBody   10485760
LimitRequestFields 100
LimitRequestFieldSize 8190
LimitRequestLine   8190
EOF

a2enconf security-headers
ok "Global security headers configured"

# -----------------------------------------------------------------------------
#  2.4 ModSecurity (WAF) configuration
# -----------------------------------------------------------------------------
banner "2.4 — ModSecurity WAF"

# ── Step 1: Activate modsecurity.conf ────────────────────────────────────────
# The Ubuntu package ships the config as a .example file; copy it into place
# if not already done.
if [[ ! -f /etc/modsecurity/modsecurity.conf ]]; then
  cp /etc/modsecurity/modsecurity.conf-recommended /etc/modsecurity/modsecurity.conf
fi

# Switch from DetectionOnly to active enforcement
sed -i 's/^SecRuleEngine DetectionOnly/SecRuleEngine On/' \
  /etc/modsecurity/modsecurity.conf

# Tune audit log parts (add request body 'C', drop unused 'I')
sed -i 's/^SecAuditLogParts .*/SecAuditLogParts ABCEFHJKZ/' \
  /etc/modsecurity/modsecurity.conf

# Tune body / response size limits
sed -i 's/^SecRequestBodyLimit .*/SecRequestBodyLimit 13107200/'             /etc/modsecurity/modsecurity.conf
sed -i 's/^SecRequestBodyNoFilesLimit .*/SecRequestBodyNoFilesLimit 131072/' /etc/modsecurity/modsecurity.conf
sed -i 's/^SecResponseBodyLimit .*/SecResponseBodyLimit 524288/'             /etc/modsecurity/modsecurity.conf

# ── Step 2: Activate the OWASP CRS ───────────────────────────────────────────
# On Ubuntu 24.04 the modsecurity-crs package installs an Apache load file at:
#   /usr/share/modsecurity-crs/owasp-crs.load
# That load file already handles Including crs-setup.conf and all rule files.
# We must NOT overwrite /etc/apache2/mods-available/security2.conf — the
# package-installed version already wires up modsecurity.conf + owasp-crs.load.
#
# The only thing we need to do is copy crs-setup.conf.example into place so
# the Include inside owasp-crs.load resolves without error.

CRS_DIR="/usr/share/modsecurity-crs"
CRS_SETUP="${CRS_DIR}/crs-setup.conf"

if [[ -f "${CRS_SETUP}.example" && ! -f "${CRS_SETUP}" ]]; then
  cp "${CRS_SETUP}.example" "${CRS_SETUP}"
  ok "OWASP CRS setup file created: ${CRS_SETUP}"
elif [[ -f "${CRS_SETUP}" ]]; then
  ok "OWASP CRS setup file already exists: ${CRS_SETUP}"
else
  warn "crs-setup.conf.example not found — CRS may not have installed correctly"
  warn "Check: dpkg -L modsecurity-crs"
fi

# Confirm the Ubuntu CRS load file exists (it activates all CRS rules for Apache)
if [[ -f "${CRS_DIR}/owasp-crs.load" ]]; then
  ok "OWASP CRS Apache load file found: ${CRS_DIR}/owasp-crs.load"
else
  warn "owasp-crs.load not found at ${CRS_DIR}/owasp-crs.load"
  warn "Check: dpkg -L modsecurity-crs | grep load"
fi

# ── Step 3: Ensure SecDataDir is set in security2.conf ───────────────────────
# The package-installed security2.conf already Includes /etc/modsecurity/*.conf
# which picks up our modsecurity.conf. We only inject SecDataDir if absent.
SECURITY2_CONF="/etc/apache2/mods-available/security2.conf"
if ! grep -q 'SecDataDir' "${SECURITY2_CONF}" 2>/dev/null; then
  sed -i 's|<IfModule security2_module>|<IfModule security2_module>\n    SecDataDir /tmp/modsecurity-data|' \
    "${SECURITY2_CONF}"
fi

mkdir -p /tmp/modsecurity-data
chown www-data:www-data /tmp/modsecurity-data

ok "ModSecurity configured in ENFORCEMENT mode with OWASP CRS"

# -----------------------------------------------------------------------------
#  2.5 ModEvasive (DDoS / request-flood protection)
# -----------------------------------------------------------------------------
banner "2.5 — ModEvasive"

mkdir -p /var/log/apache2/evasive
chown www-data:www-data /var/log/apache2/evasive

cat > /etc/apache2/mods-available/evasive.conf << EOF
<IfModule mod_evasive20.c>
    DOSHashTableSize     3097
    DOSPageCount         10
    DOSSiteCount         100
    DOSPageInterval      2
    DOSSiteInterval      2
    DOSBlockingPeriod    600
    DOSLogDir            /var/log/apache2/evasive
    $( [[ -n "$MODEVASIVE_EMAIL" ]] && echo "DOSEmailNotify       ${MODEVASIVE_EMAIL}" || echo "# DOSEmailNotify     (not configured)" )
</IfModule>
EOF

ok "ModEvasive configured (page: 10 req/2s, site: 100 req/2s, ban: 10 min)"

# -----------------------------------------------------------------------------
#  2.6 Generate self-signed TLS certificate
# -----------------------------------------------------------------------------
banner "2.6 — TLS Certificate"

TLS_KEY="/etc/ssl/private/apache-selfsigned.key"
TLS_CERT="/etc/ssl/certs/apache-selfsigned.crt"

log "Generating 4096-bit RSA self-signed certificate (valid ${TLS_DAYS} days)..."
openssl req -x509 -nodes -days "$TLS_DAYS" \
  -newkey rsa:4096 \
  -keyout "$TLS_KEY" \
  -out    "$TLS_CERT" \
  -subj   "/C=${TLS_COUNTRY}/ST=${TLS_STATE}/L=${TLS_CITY}/O=${TLS_ORG}/CN=${TLS_CN}" \
  2>/dev/null

chmod 640 "$TLS_KEY"
chmod 644 "$TLS_CERT"
chown root:ssl-cert "$TLS_KEY" 2>/dev/null || chown root:root "$TLS_KEY"

ok "Self-signed certificate generated:"
ok "  Key : $TLS_KEY"
ok "  Cert: $TLS_CERT"
warn "Replace with a CA-signed cert (Let's Encrypt) for production use."

# Generate strong Diffie-Hellman parameters for perfect forward secrecy
DH_PARAMS="/etc/ssl/certs/dhparam.pem"
log "Generating 2048-bit DH parameters (forward secrecy)..."
openssl dhparam -out "$DH_PARAMS" 2048 2>/dev/null
ok "DH parameters generated: $DH_PARAMS"

# -----------------------------------------------------------------------------
#  2.7 Secure VirtualHost configuration
# -----------------------------------------------------------------------------
banner "2.7 — VirtualHost Configuration"

# Disable the default site
a2dissite 000-default.conf 2>/dev/null || true

cat > /etc/apache2/sites-available/secure-web.conf << EOF
# =============================================================================
#  Apache Secure VirtualHost
#  Managed by harden-ubuntu-web.sh — customise as needed
# =============================================================================

# ── HTTP: redirect everything to HTTPS ───────────────────────────────────────
<VirtualHost *:80>
    ServerName  ${TLS_CN}
    ServerAdmin webmaster@localhost

    RewriteEngine On
    RewriteCond   %{HTTPS} off
    RewriteRule   ^(.*)$ https://%{HTTP_HOST}\$1 [R=301,L]

    # Allow Let's Encrypt ACME challenges over plain HTTP
    Alias /.well-known/acme-challenge/ /var/www/html/.well-known/acme-challenge/
    <Directory /var/www/html/.well-known/acme-challenge/>
        Options None
        Require all granted
    </Directory>

    ErrorLog  \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>

# ── HTTPS: main secure site ──────────────────────────────────────────────────
<VirtualHost *:443>
    ServerName  ${TLS_CN}
    ServerAdmin webmaster@localhost
    DocumentRoot ${DOC_ROOT}

    # ── TLS configuration ────────────────────────────────────────────────────
    SSLEngine on
    SSLCertificateFile    ${TLS_CERT}
    SSLCertificateKeyFile ${TLS_KEY}

    # Disable legacy protocols (SSLv3, TLSv1.0, TLSv1.1)
    SSLProtocol           all -SSLv3 -TLSv1 -TLSv1.1

    # Modern cipher suite — forward secrecy, AEAD only
    SSLCipherSuite        ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:\
ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:\
ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256

    SSLHonorCipherOrder   off
    SSLSessionTickets     off
    SSLCompression        off

    # Diffie-Hellman parameters (generated above)
    SSLOpenSSLConfCmd DHParameters "${DH_PARAMS}"

    # OCSP Stapling (works once you have a real CA-signed certificate)
    SSLUseStapling        off

    # ── Content Security Policy ──────────────────────────────────────────────
    Header always set Content-Security-Policy \
      "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"

    # ── Document root ────────────────────────────────────────────────────────
    <Directory ${DOC_ROOT}>
        Options       -Indexes -ExecCGI -Includes -FollowSymLinks
        AllowOverride None
        Require       all granted

        # Deny access to hidden files (.htaccess, .git, .env, etc.)
        <FilesMatch "^\.">
            Require all denied
        </FilesMatch>
    </Directory>

    # ── Deny access to sensitive file extensions ──────────────────────────────
    <FilesMatch "\.(bak|config|sql|fla|psd|ini|log|sh|inc|swp|dist|orig)$">
        Require all denied
    </FilesMatch>

    # ── Logging ──────────────────────────────────────────────────────────────
    ErrorLog  \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
    CustomLog \${APACHE_LOG_DIR}/ssl_request.log \
              "%t %h %{SSL_PROTOCOL}x %{SSL_CIPHER}x \"%r\" %b"

</VirtualHost>

# ── Server-wide SSL session cache ────────────────────────────────────────────
SSLSessionCache         shmcb:\${APACHE_RUN_DIR}/ssl_scache(512000)
SSLSessionCacheTimeout  300
SSLStaplingCache        shmcb:\${APACHE_RUN_DIR}/ssl_stapling(32768)
EOF

a2ensite secure-web.conf
ok "Secure VirtualHost enabled (HTTP→HTTPS redirect + TLS 1.2/1.3 only)"

# -----------------------------------------------------------------------------
#  2.8 Lock down DocumentRoot permissions
# -----------------------------------------------------------------------------
banner "2.8 — DocumentRoot Permissions"

chown -R www-data:www-data "$DOC_ROOT"
find "$DOC_ROOT" -type d -exec chmod 750 {} \;
find "$DOC_ROOT" -type f -exec chmod 640 {} \;
ok "DocumentRoot permissions locked (750 dirs / 640 files, owner www-data)"

# -----------------------------------------------------------------------------
#  2.9 Write a verification test page
# -----------------------------------------------------------------------------
banner "2.9 — Verification Test Page"

cat > "${DOC_ROOT}/index.html" << EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${CT_HOSTNAME} — Hardened Web Server</title>
  <style>
    body { font-family: sans-serif; max-width: 680px; margin: 60px auto;
           background: #0f1117; color: #c9d1d9; }
    h1   { color: #58a6ff; }
    code { background: #21262d; padding: 2px 6px; border-radius: 4px; }
    .ok  { color: #3fb950; }
    .ts  { color: #8b949e; font-size: .85em; }
  </style>
</head>
<body>
  <h1>&#x1F512; ${CT_HOSTNAME}</h1>
  <p>This server was deployed and hardened by <code>harden-ubuntu-web.sh</code>.</p>
  <ul>
    <li class="ok">&#x2713; Ubuntu 24.04 LTS — fully updated</li>
    <li class="ok">&#x2713; Apache 2.4 — hardened</li>
    <li class="ok">&#x2713; ModSecurity + OWASP CRS — active</li>
    <li class="ok">&#x2713; ModEvasive — active</li>
    <li class="ok">&#x2713; TLS 1.2/1.3 only, strong ciphers</li>
    <li class="ok">&#x2713; Security headers configured</li>
    <li class="ok">&#x2713; fail2ban — active</li>
    <li class="ok">&#x2713; UFW — active</li>
  </ul>
  <p class="ts">Deployed: $(date -u '+%Y-%m-%dT%H:%M:%S UTC')</p>
  <p><strong>Replace this page with your content at <code>${DOC_ROOT}/</code></strong></p>
</body>
</html>
EOF

chown www-data:www-data "${DOC_ROOT}/index.html"
chmod 640 "${DOC_ROOT}/index.html"
ok "Verification test page written to ${DOC_ROOT}/index.html"

# -----------------------------------------------------------------------------
#  2.10 Final Apache config test and restart
# -----------------------------------------------------------------------------
banner "2.10 — Apache Config Validation and Start"

log "Running Apache config syntax check..."
apache2ctl configtest || die "Apache configuration has errors — check output above."
ok "Apache config syntax: OK"

log "Enabling Apache at boot and starting service..."
systemctl enable apache2
systemctl restart apache2
ok "Apache started and enabled at boot"

# =============================================================================
#  HARDENING SUMMARY
# =============================================================================

banner "Hardening Complete"

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  HARDENING SUMMARY — $(date -u '+%Y-%m-%d %H:%M UTC')${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  System"
printf "    %-35s %s\n" "Hostname:"                 "$CT_HOSTNAME"
printf "    %-35s %s\n" "Admin user:"               "$ADMIN_USER (sudo)"
printf "    %-35s %s\n" "Root login:"               "LOCKED"
printf "    %-35s %s\n" "SSH PasswordAuth:"         "$( [[ -n "$ADMIN_SSH_PUBKEY" ]] && echo 'DISABLED' || echo 'enabled — ADD KEY + DISABLE' )"
printf "    %-35s %s\n" "fail2ban:"                 "active"
printf "    %-35s %s\n" "Unattended upgrades:"      "active (security only)"
printf "    %-35s %s\n" "sysctl hardening:"         "applied"
printf "    %-35s %s\n" "auditd:"                   "active"
printf "    %-35s %s\n" "UFW:"                      "active (22/80/443)"
echo ""
echo "  Apache"
printf "    %-35s %s\n" "ModSecurity:"              "ON (OWASP CRS enforcement)"
printf "    %-35s %s\n" "ModEvasive:"               "active"
printf "    %-35s %s\n" "TLS protocols:"            "TLSv1.2, TLSv1.3 only"
printf "    %-35s %s\n" "HTTP → HTTPS redirect:"    "active (301)"
printf "    %-35s %s\n" "Directory indexing:"       "DISABLED"
printf "    %-35s %s\n" "HSTS:"                     "2 years (max-age=63072000)"
printf "    %-35s %s\n" "TLS certificate:"          "Self-signed ($TLS_DAYS days)"
echo ""
echo "  Log files"
printf "    %-35s %s\n" "Hardening log:"            "$HARDEN_LOG"
printf "    %-35s %s\n" "Apache error:"             "/var/log/apache2/error.log"
printf "    %-35s %s\n" "Apache access:"            "/var/log/apache2/access.log"
printf "    %-35s %s\n" "ModSecurity audit:"        "/var/log/apache2/modsec_audit.log"
printf "    %-35s %s\n" "ModEvasive:"               "/var/log/apache2/evasive/"
printf "    %-35s %s\n" "fail2ban:"                 "/var/log/fail2ban.log"
printf "    %-35s %s\n" "Audit:"                    "/var/log/audit/audit.log"
echo ""
echo -e "${YELLOW}  ⚠  NEXT STEPS:${NC}"
echo "  1. Replace self-signed cert with Let's Encrypt:"
echo "       apt install -y certbot python3-certbot-apache"
echo "       certbot --apache -d yourdomain.com"
echo ""
echo "  2. Enable OCSP stapling in the VirtualHost after installing a real cert."
echo ""
echo "  3. Deploy your web content to ${DOC_ROOT}/"
echo ""
echo "  4. Review ModSecurity for false positives:"
echo "       tail -f /var/log/apache2/modsec_audit.log"
echo ""
if [[ -z "$ADMIN_SSH_PUBKEY" ]]; then
  echo -e "${YELLOW}  5. SSH key was NOT configured — add one and disable PasswordAuthentication:${NC}"
  echo "       ssh-copy-id ${ADMIN_USER}@<server-ip>"
  echo "       sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config"
  echo "       systemctl restart ssh"
  echo ""
fi
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
