#!/usr/bin/env bash
# scripts/configure-base.sh - host side: admin user, base stack, in-guest scripts.
# Sourced by deploy.sh. Requires lib/common.sh, loaded config, REPO_DIR.
# shellcheck shell=bash

GUEST_DIR=/opt/demo-factory

# push_guest_files - copy guest-side scripts into the container (root-only dir).
push_guest_files() {
  ct_exec "$CTID" install -d -m 0700 "$GUEST_DIR"
  local f
  for f in "$REPO_DIR"/guest/*.sh; do
    pct push "$CTID" "$f" "$GUEST_DIR/$(basename "$f")" --perms 0700
  done
}

# guest_env_args - non-secret settings handed to guest scripts.
guest_env_args() {
  printf '%s\n' \
    "ADMIN_USER=$ADMIN_USER" "CT_HOSTNAME=$CT_HOSTNAME" \
    "SSH_ALLOW_USERS=$SSH_ALLOW_USERS" "ADMIN_SSH_PUBKEY=$ADMIN_SSH_PUBKEY" \
    "ENABLE_HTTPS=$ENABLE_HTTPS" "DEMO_DB=$DEMO_DB" \
    "UNATTENDED_UPGRADES=$UNATTENDED_UPGRADES"
}

# guest_run SCRIPT [ENV=VAL...] - run a pushed guest script as root.
guest_run() {
  local script=$1; shift
  local envs=()
  mapfile -t envs < <(guest_env_args)
  ct_exec "$CTID" env "${envs[@]}" "$@" bash "$GUEST_DIR/$script"
}

# create_admin_user - creates the account only if absent; never resets an
# existing password. The password travels over stdin only.
create_admin_user() {
  stage admin-user "$EX_GUEST"
  if ((DRY_RUN)); then log_info "[dry-run] would create '$ADMIN_USER' (password prompt) if absent"; return 0; fi
  if ct_exec "$CTID" id -u "$ADMIN_USER" >/dev/null 2>&1; then
    log_ok "User '$ADMIN_USER' already exists; password left unchanged"
    return 0
  fi
  if [[ -z ${ADMIN_PW_HOLD:-} ]]; then
    read_new_password
    ADMIN_PW_HOLD=$REPLY
  fi
  ct_exec "$CTID" useradd -m -s /bin/bash -G sudo "$ADMIN_USER"
  # printf is a shell builtin: the secret never appears in any argv.
  printf '%s:%s\n' "$ADMIN_USER" "$ADMIN_PW_HOLD" | ct_exec "$CTID" chpasswd
  log_ok "User '$ADMIN_USER' created with sudo rights (password set)"
}

configure_base() {
  stage base-config "$EX_GUEST"
  ((DRY_RUN)) && { log_info "[dry-run] would push guest scripts and install the base stack"; return 0; }
  push_guest_files
  stage packages "$EX_PACKAGES"
  log_info "Installing base packages (several minutes)..."
  guest_run base.sh
  log_ok "Base stack installed"
}

harden_container() {
  stage hardening "$EX_GUEST"
  ((DRY_RUN)) && { log_info "[dry-run] would apply guest hardening and firewall rules"; return 0; }
  guest_run harden.sh
  log_ok "Guest hardening applied"
  configure_firewall
}

# ---------------------------------------------------------------------------
# Proxmox firewall (per-container only; host/datacenter policy is never edited)
# ---------------------------------------------------------------------------
FW_MARKER="# managed-by: proxmox-demo-factory"

render_fw_file() {
  cat <<FW
$FW_MARKER
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT
dhcp: 1
ndp: 0
macfilter: 1
log_level_in: nolog

[RULES]
IN Ping(ACCEPT) -log nolog
IN HTTP(ACCEPT) -log nolog
FW
  if [[ $ENABLE_HTTPS == 1 ]]; then echo "IN HTTPS(ACCEPT) -log nolog"; fi
  if [[ -n $SSH_MGMT_SUBNET ]]; then
    echo "IN SSH(ACCEPT) -source $SSH_MGMT_SUBNET -log nolog"
  else
    echo "IN SSH(ACCEPT) -log nolog"
  fi
}

configure_firewall() {
  stage firewall "$EX_GUEST"
  if [[ $PROXMOX_FIREWALL != 1 ]]; then log_warn "PROXMOX_FIREWALL=0: skipping firewall rules"; return 0; fi
  local fw="${PVE_FW_DIR:-/etc/pve/firewall}/$CTID.fw" tmp
  if [[ -f $fw ]] && ! grep -qxF "$FW_MARKER" "$fw"; then
    log_warn "$fw exists and was not created by this factory; leaving it untouched."
    return 0
  fi
  make_tmpdir; tmp=$REPLY/fw
  render_fw_file >"$tmp"
  if [[ -f $fw ]] && cmp -s "$tmp" "$fw"; then
    log_ok "Firewall rules already current"
  else
    cat "$tmp" >"$fw"
    log_ok "Firewall rules written to $fw"
  fi
  # net0 must carry firewall=1 for the rules to attach to the interface.
  if ! pct config "$CTID" | grep -E '^net0:' | grep -q 'firewall=1'; then
    local cur; cur=$(pct config "$CTID" | sed -n 's/^net0: //p')
    run pct set "$CTID" --net0 "$(sed -E 's/,?firewall=[01]//; s/$/,firewall=1/' <<<"$cur")"
  fi
  firewall_effectiveness_report || true   # advisory: warnings already printed
}

# firewall_effectiveness_report - tells the admin whether rules can be enforced.
# Returns 0 when enforced, 1 when something host-side prevents enforcement.
firewall_effectiveness_report() {
  local node dc="${PVE_FW_DIR:-/etc/pve/firewall}/cluster.fw" ok=0
  node=$(hostname)
  if ! grep -qE '^enable:[[:space:]]*1' <(sed -n '/^\[OPTIONS\]/,/^\[/p' "$dc" 2>/dev/null); then
    log_warn "Datacenter firewall is DISABLED: per-container rules are NOT enforced."
    log_warn "  Enable it in GUI: Datacenter > Firewall > Options > Firewall = Yes"
    log_warn "  Before enabling, make sure a rule allows your management access (TCP/8006, TCP/22) to the host."
    ok=1
  fi
  local hostfw="${PVE_FW_DIR:-/etc/pve}/nodes/$node/host.fw"
  [[ -f $hostfw ]] || hostfw="/etc/pve/nodes/$node/host.fw"
  if grep -qE '^nftables:[[:space:]]*1' "$hostfw" 2>/dev/null; then
    log_info "Firewall backend: nftables (proxmox-firewall)"
    have systemctl && ! systemctl is-active --quiet proxmox-firewall 2>/dev/null \
      && { log_warn "proxmox-firewall service is not active; rules are not enforced."; ok=1; }
  else
    log_info "Firewall backend: iptables (pve-firewall)"
    have systemctl && ! systemctl is-active --quiet pve-firewall 2>/dev/null \
      && { log_warn "pve-firewall service is not active: systemctl enable --now pve-firewall"; ok=1; }
  fi
  if [[ -n $SSH_MGMT_SUBNET ]]; then
    log_warn "SSH is restricted to $SSH_MGMT_SUBNET; this Proxmox host must be inside it for the SSH login test."
  fi
  return "$ok"
}
