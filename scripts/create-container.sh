#!/usr/bin/env bash
# scripts/create-container.sh - host side: preflight, template, create, start, wait for IP.
# Sourced by deploy.sh (functions only). Requires lib/common.sh and loaded config.
# shellcheck shell=bash

# pvesm_storages CONTENT - names of active storages that support CONTENT.
pvesm_storages() {
  pvesm status --content "$1" 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}'
}

storage_type() { pvesm status 2>/dev/null | awk -v s="$1" '$1==s {print $2}'; }

# pick_storage CONTENT REQUESTED PREFERRED... - echoes the chosen storage or fails.
pick_storage() {
  local content=$1 requested=$2; shift 2
  local avail p
  avail=$(pvesm_storages "$content")
  if [[ $requested != auto && -n $requested ]]; then
    if grep -qx "$requested" <<<"$avail"; then printf '%s' "$requested"; return 0; fi
    log_err "Storage '$requested' is missing, inactive, or does not allow content '$content'."
    log_err "Usable for '$content': ${avail:-<none>}"
    return 1
  fi
  for p in "$@"; do
    if grep -qx "$p" <<<"$avail"; then printf '%s' "$p"; return 0; fi
  done
  [[ -n $avail ]] || { log_err "No active storage supports content '$content'."; return 1; }
  head -n1 <<<"$avail"
}

# pick_template - newest ubuntu-24.04-standard template name from `pveam available`.
pick_template() {
  pveam available --section system 2>/dev/null \
    | awk '{print $2}' | grep -E '^ubuntu-24\.04-standard_.*_amd64\.tar\.(zst|gz|xz)$' \
    | sort -V | tail -n1
}

# cached_template STORAGE - newest ubuntu-24.04 template already on STORAGE.
cached_template() {
  pveam list "$1" 2>/dev/null | awk '{print $1}' | sed 's|^[^:]*:vztmpl/||' \
    | grep -E '^ubuntu-24\.04-standard_.*_amd64\.tar\.(zst|gz|xz)$' | sort -V | tail -n1
}

preflight() {
  stage preflight "$EX_VALIDATION"
  require_root
  require_pve_tools
  local major; major=$(pve_major)
  if [[ $major == 9 ]]; then
    log_ok "Proxmox VE $(pveversion | cut -d/ -f2) detected"
  elif [[ $ALLOW_OTHER_PVE == 1 ]]; then
    log_warn "Proxmox VE major version '${major:-unknown}' is not 9 (ALLOW_OTHER_PVE=1, continuing)"
  else
    die "$EX_VALIDATION" "Proxmox VE 9.x required (found '${major:-unknown}'). Set ALLOW_OTHER_PVE=1 to override."
  fi
  have ssh || log_warn "ssh client missing on host: SSH login test will be skipped."
  validate_config || die "$EX_VALIDATION" "Configuration is invalid."
  [[ -n $SSH_ALLOW_USERS ]] || SSH_ALLOW_USERS=$ADMIN_USER
  [[ -d $REPO_DIR/profiles/$PROFILE || $PROFILE == base ]] \
    || die "$EX_VALIDATION" "Unknown profile '$PROFILE' (no profiles/$PROFILE directory)."
}

# resolve_storage - sets ROOTFS_STORAGE and TPL_STORAGE
resolve_storage() {
  ROOTFS_STORAGE=$(pick_storage rootdir "$STORAGE" local-lvm local-zfs local) \
    || die "$EX_VALIDATION" "Cannot select container storage."
  TPL_STORAGE=$(pick_storage vztmpl "$TEMPLATE_STORAGE" local) \
    || die "$EX_VALIDATION" "Cannot select template storage."
  log_ok "Container storage: $ROOTFS_STORAGE ($(storage_type "$ROOTFS_STORAGE")); template storage: $TPL_STORAGE"
  if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
    die "$EX_VALIDATION" "Bridge '$BRIDGE' does not exist on this host (ip link show $BRIDGE)."
  fi
}

ensure_template() { # sets TEMPLATE_VOLID
  stage template "$EX_CREATE"
  local name
  name=$(cached_template "$TPL_STORAGE" || true)
  if [[ -z $name ]]; then
    log_info "Updating template catalogue..."
    run pveam update >/dev/null || log_warn "pveam update failed; using the cached catalogue"
    name=$(pick_template || true)
    [[ -n $name ]] || die "$EX_CREATE" "No Ubuntu 24.04 template found. Check: pveam available --section system"
    log_info "Downloading $name to $TPL_STORAGE ..."
    run pveam download "$TPL_STORAGE" "$name" || die "$EX_CREATE" "Template download failed (outbound access to download.proxmox.com required)."
  else
    log_ok "Template already present: $name (not downloading)"
  fi
  TEMPLATE_VOLID="$TPL_STORAGE:vztmpl/$name"
}

net0_string() {
  local s="name=eth0,bridge=$BRIDGE,firewall=$PROXMOX_FIREWALL"
  [[ -z $VLAN_TAG ]] || s+=",tag=$VLAN_TAG"
  if [[ $NETWORK_MODE == dhcp ]]; then
    s+=",ip=dhcp"
  else
    s+=",ip=$STATIC_IP/$STATIC_PREFIX,gw=$STATIC_GATEWAY"
  fi
  printf '%s' "$s"
}

create_container() {
  stage create "$EX_CREATE"
  if ct_exists "$CTID"; then
    die "$EX_VALIDATION" "CTID $CTID already exists; refusing to touch it. Use './deploy.sh configure --ctid $CTID' to (re)configure it non-destructively, or choose another CTID."
  fi
  local args=(
    "$CTID" "$TEMPLATE_VOLID"
    --hostname "$CT_HOSTNAME" --ostype ubuntu --unprivileged 1
    --cores "$CT_CORES" --memory "$CT_MEMORY" --swap "$CT_SWAP"
    --rootfs "$ROOTFS_STORAGE:$CT_DISK"
    --net0 "$(net0_string)"
    --onboot "$CT_ONBOOT" --tags demo-factory
    --description "Created by proxmox-demo-factory (profile: $PROFILE). Rebuild with deploy.sh; do not hand-edit."
    --start 0
  )
  [[ $CT_NESTING == 1 ]] && args+=(--features nesting=1)
  [[ $NETWORK_MODE == static ]] && args+=(--nameserver "$STATIC_DNS")
  # No --password: root has no password; use `pct enter` for console access.
  run pct create "${args[@]}" || die "$EX_CREATE" "pct create failed."
  log_ok "Container $CTID created (unprivileged, ${CT_CORES} vCPU, ${CT_MEMORY} MB, ${CT_DISK} GB on $ROOTFS_STORAGE)"
}

start_container() {
  stage start "$EX_START"
  ct_running "$CTID" || run pct start "$CTID" || die "$EX_START" "pct start failed (see: journalctl -u pve-container@$CTID)."
  ((DRY_RUN)) && return 0
  local i
  for ((i = 0; i < 30; i++)); do ct_running "$CTID" && break; sleep 1; done
  ct_running "$CTID" || die "$EX_START" "Container did not reach running state."
  log_ok "Container $CTID is running"
}

wait_network() { # sets CT_IP_ADDR
  stage network "$EX_NETWORK"
  ((DRY_RUN)) && { log_info "[dry-run] would wait up to ${NET_TIMEOUT}s for an IPv4 address"; CT_IP_ADDR="(dry-run)"; return 0; }
  CT_IP_ADDR=$(wait_for_ip "$CTID" "$NET_TIMEOUT") \
    || die "$EX_NETWORK" "No IPv4 address after ${NET_TIMEOUT}s. Check the bridge/VLAN has a DHCP server, and that the Proxmox firewall allows DHCP (see docs/troubleshooting.md)."
  log_ok "Container address: $CT_IP_ADDR"
  local i
  for ((i = 0; i < 10; i++)); do
    ct_exec "$CTID" getent hosts archive.ubuntu.com >/dev/null 2>&1 && break
    sleep 2
  done
  ct_exec "$CTID" getent hosts archive.ubuntu.com >/dev/null 2>&1 \
    || die "$EX_NETWORK" "DNS resolution failed inside the container."
  ct_exec "$CTID" bash -c 'exec 3<>/dev/tcp/archive.ubuntu.com/80' 2>/dev/null \
    || die "$EX_NETWORK" "No outbound TCP/80 connectivity to archive.ubuntu.com."
  log_ok "DNS and outbound connectivity verified"
}
