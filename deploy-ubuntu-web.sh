#!/usr/bin/env bash
# =============================================================================
#  deploy-ubuntu-web.sh
#  Fully automated Ubuntu 24.04 LTS hardened web-server LXC deployment
#  for Proxmox VE 8.x
# =============================================================================
#
#  USAGE:
#    1. Copy this script AND harden-ubuntu-web.sh to your Proxmox node:
#         scp deploy-ubuntu-web.sh harden-ubuntu-web.sh root@<proxmox-ip>:/root/
#
#    2. SSH into the Proxmox node:
#         ssh root@<proxmox-ip>
#
#    3. Edit the CONFIGURATION section below (CT ID, storage, network, etc.)
#
#    4. Run the script:
#         chmod +x deploy-ubuntu-web.sh
#         ./deploy-ubuntu-web.sh
#
#  WHAT THIS SCRIPT DOES:
#    - Validates prerequisites (pct, pvesm, template availability)
#    - Downloads the Ubuntu 24.04 LXC template if not already present
#    - Creates an unprivileged LXC container with hardened settings
#    - Configures Proxmox firewall rules (SSH / HTTP / HTTPS only)
#    - Copies harden-ubuntu-web.sh into the container and executes it
#    - Waits for hardening to complete and reports results
#    - Takes an initial snapshot as a clean baseline
#
#  REQUIREMENTS (all present by default on Proxmox 8.x):
#    pct, pvesm, pvesh, pveam
#
#  TWO-SCRIPT DESIGN:
#    deploy-ubuntu-web.sh  — runs on the PROXMOX HOST, creates the container
#    harden-ubuntu-web.sh  — runs INSIDE the container, hardens OS + Apache
#    Both scripts must be in the same directory when you run deploy-ubuntu-web.sh.
# =============================================================================

set -euo pipefail

# =============================================================================
#  CONFIGURATION — edit these values before running
# =============================================================================

## Container identity
CTID=201                          # Proxmox container ID (must not already exist)
CT_NAME="ubuntu-web"              # Hostname and display name

## Storage (run: pvesm status  to list available storage pools)
STORAGE="local-lvm"              # Storage pool for the container rootfs

## Container resources
CT_CORES=2                        # vCPU cores
CT_MEMORY=1024                    # RAM in MB
CT_SWAP=512                       # Swap in MB
DISK_SIZE=20                      # Root filesystem size in GB

## Network — choose STATIC or DHCP
#   For a web server, a static IP is strongly recommended.
#   Set USE_DHCP=false and fill in the three values below.
USE_DHCP=false
CT_IP="192.168.1.50"              # Container static IP address
CT_CIDR=24                        # Subnet prefix length (24 = 255.255.255.0)
CT_GW="192.168.1.1"              # Default gateway
CT_DNS="1.1.1.1"                 # DNS resolver

## Proxmox bridge
BRIDGE="vmbr0"

## Ubuntu 24.04 template — update version string if a newer point release exists
#   Run: pveam available --section system | grep ubuntu-24
#   to see the exact name in your repository.
TEMPLATE_NAME="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
TEMPLATE_STORAGE="local"          # Storage that holds LXC templates

## Root password for the container (change this before running)
CT_PASSWORD="CHANGEME_PASSWORD"

## Admin user created inside the container (sudo, SSH key auth only)
ADMIN_USER="webadmin"

## SSH public key to install for the admin user.
#   Leave empty ("") to skip key installation (password SSH auth will remain
#   enabled — less secure; change PasswordAuthentication in harden script).
ADMIN_SSH_PUBKEY=""               # e.g. "ssh-ed25519 AAAA... user@host"

## Path to the in-container hardening script (must be alongside this script)
HARDEN_SCRIPT="$(dirname "$0")/harden-ubuntu-web.sh"

# =============================================================================
#  SCRIPT INTERNALS — no edits needed below this line
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()     { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()    { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

banner() {
  echo ""
  echo -e "${CYAN}============================================================${NC}"
  echo -e "${CYAN}  $*${NC}"
  echo -e "${CYAN}============================================================${NC}"
  echo ""
}

# -----------------------------------------------------------------------------
#  1. Preflight checks
# -----------------------------------------------------------------------------
preflight() {
  banner "Preflight Checks"

  [[ $EUID -eq 0 ]] || die "This script must be run as root."
  ok "Running as root"

  command -v pct    >/dev/null 2>&1 || die "'pct' not found. Run this script on the Proxmox node."
  command -v pvesm  >/dev/null 2>&1 || die "'pvesm' not found. Run this script on the Proxmox node."
  command -v pveam  >/dev/null 2>&1 || die "'pveam' not found. Run this script on the Proxmox node."
  command -v pvesh  >/dev/null 2>&1 || die "'pvesh' not found. Run this script on the Proxmox node."
  ok "Proxmox tools (pct, pvesm, pveam, pvesh) found"

  # CT ID must not already exist
  if pct status "$CTID" >/dev/null 2>&1; then
    die "Container ID $CTID already exists. Choose a different CTID or destroy it first:\n  pct destroy $CTID"
  fi
  ok "Container ID $CTID is available"

  # Storage pool must exist
  if ! pvesm status | awk '{print $1}' | grep -qx "$STORAGE"; then
    die "Storage pool '$STORAGE' not found. Available pools:\n$(pvesm status)"
  fi
  ok "Storage pool '$STORAGE' found"

  # Template storage must exist
  if ! pvesm status | awk '{print $1}' | grep -qx "$TEMPLATE_STORAGE"; then
    die "Template storage '$TEMPLATE_STORAGE' not found."
  fi
  ok "Template storage '$TEMPLATE_STORAGE' found"

  # Hardening script must be present
  [[ -f "$HARDEN_SCRIPT" ]] || \
    die "harden-ubuntu-web.sh not found at: $HARDEN_SCRIPT\n  Place it in the same directory as this script."
  ok "harden-ubuntu-web.sh found"

  # Warn if default password was not changed
  if [[ "$CT_PASSWORD" == "CHANGEME_PASSWORD" ]]; then
    warn "CT_PASSWORD is still set to 'CHANGEME_PASSWORD'."
    warn "The container will deploy with that weak root password."
    warn "Edit the CONFIGURATION section and re-run."
    echo ""
    read -rp "Continue anyway? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { log "Aborted by user."; exit 0; }
  fi
}

# -----------------------------------------------------------------------------
#  2. Download the Ubuntu 24.04 LXC template (if not already cached)
# -----------------------------------------------------------------------------
download_template() {
  banner "Checking LXC Template"

  local TEMPLATE_CACHE
  TEMPLATE_CACHE=$(pvesm path "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}" 2>/dev/null || true)

  if [[ -f "$TEMPLATE_CACHE" ]]; then
    ok "Template already cached: $TEMPLATE_NAME"
  else
    log "Updating template repository list..."
    pveam update
    ok "Template list updated"

    log "Downloading Ubuntu 24.04 template (this may take a few minutes)..."
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME" \
      || die "Template download failed. Check: pveam available --section system | grep ubuntu-24"
    ok "Template downloaded: $TEMPLATE_NAME"
  fi
}

# -----------------------------------------------------------------------------
#  3. Create the container
# -----------------------------------------------------------------------------
create_container() {
  banner "Creating Container: $CT_NAME (ID: $CTID)"

  # Build the network string depending on DHCP vs static
  local net_config
  if [[ "$USE_DHCP" == "true" ]]; then
    net_config="name=eth0,bridge=${BRIDGE},ip=dhcp,firewall=1"
    log "Network mode: DHCP"
  else
    net_config="name=eth0,bridge=${BRIDGE},ip=${CT_IP}/${CT_CIDR},gw=${CT_GW},firewall=1"
    log "Network mode: Static — ${CT_IP}/${CT_CIDR} via ${CT_GW}"
  fi

  log "Creating unprivileged LXC container..."
  pct create "$CTID" \
    "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}" \
    --hostname    "$CT_NAME" \
    --ostype      ubuntu \
    --cores       "$CT_CORES" \
    --memory      "$CT_MEMORY" \
    --swap        "$CT_SWAP" \
    --rootfs      "${STORAGE}:${DISK_SIZE}" \
    --net0        "$net_config" \
    --nameserver  "$CT_DNS" \
    --password    "$CT_PASSWORD" \
    --unprivileged 1 \
    --features    "nesting=0" \
    --onboot      1 \
    --start       0
  ok "Container created (unprivileged)"

  log "Container configuration:"
  pct config "$CTID"
}

# -----------------------------------------------------------------------------
#  4. Configure the Proxmox firewall for this container
# -----------------------------------------------------------------------------
configure_firewall() {
  banner "Configuring Proxmox Firewall"

  local NODE
  NODE=$(hostname)
  local FW_API="/nodes/${NODE}/lxc/${CTID}/firewall"

  log "Enabling container firewall with default-deny inbound policy..."
  pvesh set "${FW_API}/options" \
    --enable 1 \
    --policy_in  DROP \
    --policy_out ACCEPT \
    --log_level_in  info \
    --log_level_out nolog
  ok "Firewall enabled (inbound: DROP, outbound: ACCEPT)"

  log "Adding firewall rules..."

  # SSH
  pvesh create "${FW_API}/rules" \
    --type    in \
    --action  ACCEPT \
    --proto   tcp \
    --dport   22 \
    --comment "SSH"
  ok "Rule added: TCP/22 (SSH)"

  # HTTP
  pvesh create "${FW_API}/rules" \
    --type    in \
    --action  ACCEPT \
    --proto   tcp \
    --dport   80 \
    --comment "HTTP"
  ok "Rule added: TCP/80 (HTTP)"

  # HTTPS
  pvesh create "${FW_API}/rules" \
    --type    in \
    --action  ACCEPT \
    --proto   tcp \
    --dport   443 \
    --comment "HTTPS"
  ok "Rule added: TCP/443 (HTTPS)"

  log "Active firewall rules for CT $CTID:"
  pvesh get "${FW_API}/rules" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
#  5. Start the container
# -----------------------------------------------------------------------------
start_container() {
  banner "Starting Container"

  log "Starting container $CTID..."
  pct start "$CTID"
  ok "Container started"

  log "Waiting for network stack to initialise..."
  sleep 8

  # Confirm the container is running
  local status
  status=$(pct status "$CTID" | awk '{print $2}')
  [[ "$status" == "running" ]] || die "Container did not reach 'running' state (status: $status)."
  ok "Container is running"
}

# -----------------------------------------------------------------------------
#  6. Inject SSH public key for the admin user (if supplied)
# -----------------------------------------------------------------------------
inject_ssh_key() {
  if [[ -z "$ADMIN_SSH_PUBKEY" ]]; then
    warn "ADMIN_SSH_PUBKEY is empty — skipping SSH key injection."
    warn "Password authentication will remain enabled until you add a key."
    return
  fi

  banner "Injecting SSH Public Key"

  log "Creating admin user '$ADMIN_USER' and injecting SSH key..."
  pct exec "$CTID" -- bash -c "
    id '$ADMIN_USER' &>/dev/null || useradd -m -s /bin/bash '$ADMIN_USER'
    usermod -aG sudo '$ADMIN_USER'
    mkdir -p /home/${ADMIN_USER}/.ssh
    echo '${ADMIN_SSH_PUBKEY}' > /home/${ADMIN_USER}/.ssh/authorized_keys
    chmod 700 /home/${ADMIN_USER}/.ssh
    chmod 600 /home/${ADMIN_USER}/.ssh/authorized_keys
    chown -R ${ADMIN_USER}:${ADMIN_USER} /home/${ADMIN_USER}/.ssh
  "
  ok "SSH key injected for $ADMIN_USER"
}

# -----------------------------------------------------------------------------
#  7. Push and execute the in-container hardening script
# -----------------------------------------------------------------------------
run_hardening() {
  banner "Running In-Container Hardening"

  log "Copying harden-ubuntu-web.sh into the container..."
  pct push "$CTID" "$HARDEN_SCRIPT" /root/harden-ubuntu-web.sh --perms 0700
  ok "Script copied to /root/harden-ubuntu-web.sh"

  log "Passing configuration to the hardening script via environment variables..."
  log "Executing harden-ubuntu-web.sh inside container $CTID..."
  log "(This typically takes 3–8 minutes — live output follows)"
  echo ""

  # Pass deployment-time variables into the container environment so the
  # hardening script can configure itself without requiring edits.
  pct exec "$CTID" -- env \
    ADMIN_USER="$ADMIN_USER" \
    ADMIN_SSH_PUBKEY="$ADMIN_SSH_PUBKEY" \
    CT_HOSTNAME="$CT_NAME" \
    bash /root/harden-ubuntu-web.sh

  local rc=$?
  echo ""
  if [[ $rc -eq 0 ]]; then
    ok "Hardening script completed successfully (exit code 0)"
  else
    die "Hardening script exited with code $rc — review output above."
  fi
}

# -----------------------------------------------------------------------------
#  8. Take a baseline snapshot
# -----------------------------------------------------------------------------
take_snapshot() {
  banner "Taking Baseline Snapshot"

  local snap_name="baseline-$(date +%Y%m%d)"
  log "Creating snapshot '$snap_name'..."
  pct snapshot "$CTID" "$snap_name" \
    --description "Clean baseline — post-deploy hardened Ubuntu 24.04 + Apache"
  ok "Snapshot '$snap_name' created"
  log "To restore:  pct rollback $CTID $snap_name"
}

# -----------------------------------------------------------------------------
#  9. Post-deploy summary
# -----------------------------------------------------------------------------
post_deploy_summary() {
  banner "Deployment Complete"

  # Resolve the actual container IP for display
  local CT_DISPLAY_IP="$CT_IP"
  if [[ "$USE_DHCP" == "true" ]]; then
    CT_DISPLAY_IP=$(pct exec "$CTID" -- ip -4 addr show eth0 2>/dev/null \
                    | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "check-with-pct-exec")
  fi

  echo -e "${GREEN}Container '$CT_NAME' (ID: $CTID) is deployed and hardened.${NC}"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  CONTAINER DETAILS"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "  ID       : $CTID"
  echo "  Hostname : $CT_NAME"
  echo "  IP       : $CT_DISPLAY_IP"
  echo "  Admin    : $ADMIN_USER (sudo, key-based SSH)"
  echo "  Root pw  : set (use 'pct enter $CTID' for emergency console access)"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  WHAT WAS CONFIGURED INSIDE THE CONTAINER"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "  OS hardening:"
  echo "    ✓ System fully updated"
  echo "    ✓ Non-root admin user created ($ADMIN_USER)"
  echo "    ✓ SSH hardened (no root login, MaxAuthTries 3)"
  echo "    ✓ fail2ban installed and active (SSH jail enabled)"
  echo "    ✓ Unattended security updates enabled"
  echo "    ✓ Kernel network hardening via sysctl"
  echo "    ✓ auditd installed and active"
  echo "    ✓ UFW enabled (22/80/443 only)"
  echo ""
  echo "  Apache hardening:"
  echo "    ✓ Apache 2.4 installed and enabled"
  echo "    ✓ Unnecessary modules disabled (autoindex, status, cgi)"
  echo "    ✓ Security headers (X-Frame-Options, CSP, HSTS, etc.)"
  echo "    ✓ ModSecurity WAF with OWASP CRS (detection + enforcement)"
  echo "    ✓ ModEvasive DDoS protection"
  echo "    ✓ TLS 1.2/1.3 only, strong cipher suite"
  echo "    ✓ Self-signed certificate (replace with Let's Encrypt when ready)"
  echo "    ✓ HTTP → HTTPS redirect"
  echo "    ✓ Directory indexing disabled"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  RECOMMENDED NEXT STEPS"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "  1. SSH into the container:"
  echo "       ssh ${ADMIN_USER}@${CT_DISPLAY_IP}"
  echo ""
  echo "  2. Replace the self-signed certificate with Let's Encrypt"
  echo "     (requires a public domain pointing to this server's IP):"
  echo "       sudo apt install -y certbot python3-certbot-apache"
  echo "       sudo certbot --apache -d yourdomain.com"
  echo ""
  echo "  3. Review ModSecurity audit log for false positives:"
  echo "       sudo tail -f /var/log/apache2/modsec_audit.log"
  echo ""
  echo "  4. Deploy your web content to /var/www/html/"
  echo ""
  echo "  5. Restrict SSH source IPs in the Proxmox firewall rule for TCP/22"
  echo "     to only your management IP range."
  echo ""
  echo "  6. Console access (emergency, bypasses SSH):"
  echo "       pct enter $CTID"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  ok "All done. CT $CTID ($CT_NAME) is live at https://${CT_DISPLAY_IP}/"
}

# =============================================================================
#  MAIN
# =============================================================================
main() {
  banner "Ubuntu 24.04 LTS Hardened Web Server — Proxmox LXC Deployment"
  log "Proxmox node  : $(hostname)"
  log "Container ID  : $CTID"
  log "CT Hostname   : $CT_NAME"
  log "Storage       : $STORAGE"
  log "Cores / RAM   : ${CT_CORES} cores / ${CT_MEMORY} MB"
  log "Disk size     : ${DISK_SIZE} GB"
  log "Network       : $BRIDGE"
  if [[ "$USE_DHCP" == "true" ]]; then
    log "IP address    : DHCP"
  else
    log "IP address    : ${CT_IP}/${CT_CIDR} gw ${CT_GW}"
  fi
  echo ""

  preflight
  download_template
  create_container
  configure_firewall
  start_container
  inject_ssh_key
  run_hardening
  take_snapshot
  post_deploy_summary
}

main "$@"
