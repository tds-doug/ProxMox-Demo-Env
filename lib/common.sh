#!/usr/bin/env bash
# lib/common.sh - shared helpers for host-side scripts (sourced, not executed).
# shellcheck shell=bash disable=SC2034

# Exit codes by failure class.
readonly EX_VALIDATION=2 EX_CREATE=3 EX_START=4 EX_NETWORK=5
readonly EX_GUEST=6 EX_PACKAGES=7 EX_PROFILE=8 EX_VERIFY=9

: "${LOG_FILE:=/var/log/proxmox-demo-factory.log}"
CURRENT_STAGE="init"
CURRENT_EXIT=1
DRY_RUN=0
ASSUME_YES=0

if [[ -t 2 ]]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[1;33m'; C_CYN=$'\033[0;36m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_OFF=""
fi

_log() { # level color message...
  local level=$1 color=$2; shift 2
  printf '%s[%s]%s %s\n' "$color" "$level" "$C_OFF" "$*" >&2
  { printf '%s [%s] %s\n' "$(date '+%F %T')" "$level" "$*" >>"$LOG_FILE"; } 2>/dev/null || true
}
log_info() { _log INFO "$C_CYN" "$@"; }
log_ok()   { _log OK   "$C_GRN" "$@"; }
log_warn() { _log WARN "$C_YEL" "$@"; }
log_err()  { _log ERROR "$C_RED" "$@"; }

# die CODE MESSAGE...
die() {
  local code=$1; shift
  log_err "$*"
  exit "$code"
}

# stage NAME EXIT_CODE - record the current stage so failures can be attributed.
stage() {
  CURRENT_STAGE=$1
  CURRENT_EXIT=$2
  log_info "=== Stage: $1 ==="
}

on_error() {
  local rc=$?
  trap - ERR
  log_err "Stage '$CURRENT_STAGE' failed (line ${BASH_LINENO[0]}, status $rc)."
  if [[ -n "${CTID:-}" ]] && have pct && pct status "$CTID" >/dev/null 2>&1; then
    log_warn "Container $CTID was left in place for investigation (pct enter $CTID)."
    log_warn "Fix the cause, then resume with: ./deploy.sh configure --ctid $CTID"
  fi
  exit "$CURRENT_EXIT"
}
enable_error_trap() { set -E; trap on_error ERR; }

have() { command -v "$1" >/dev/null 2>&1; }

# run CMD...  - execute unless in dry-run mode, in which case just print.
run() {
  if ((DRY_RUN)); then
    log_info "[dry-run] $*"
    return 0
  fi
  "$@"
}

# ---------------------------------------------------------------------------
# Temp files
# ---------------------------------------------------------------------------
TMP_DIRS=()
make_tmpdir() { # sets REPLY
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/demo-factory.XXXXXX")
  chmod 700 "$d"
  TMP_DIRS+=("$d")
  REPLY=$d
}
cleanup_tmp() {
  local d
  for d in "${TMP_DIRS[@]:-}"; do
    if [[ -n $d && -d $d ]]; then rm -rf "$d"; fi
  done
  return 0
}
trap cleanup_tmp EXIT

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CONFIG_KEYS=(
  CTID CT_HOSTNAME CT_CORES CT_MEMORY CT_SWAP CT_DISK CT_ONBOOT CT_NESTING
  NETWORK_MODE BRIDGE VLAN_TAG STATIC_IP STATIC_PREFIX STATIC_GATEWAY STATIC_DNS
  STORAGE TEMPLATE_STORAGE
  ADMIN_USER SSH_ALLOW_USERS ADMIN_SSH_PUBKEY SSH_MGMT_SUBNET
  PROFILE ENABLE_HTTPS DEMO_DB UNATTENDED_UPGRADES PROXMOX_FIREWALL
  NET_TIMEOUT SNAPSHOT_AFTER_DEPLOY ALLOW_OTHER_PVE
)

is_config_key() {
  local k
  for k in "${CONFIG_KEYS[@]}"; do [[ $k == "$1" ]] && return 0; done
  return 1
}

# set_config KEY VALUE - validates the key name and rejects shell metacharacters.
set_config() {
  local key=$1 val=$2
  is_config_key "$key" || { log_err "Unknown configuration key: $key"; return 1; }
  if [[ $val == *'$'* || $val == *'`'* || $val == *';'* || $val == *'|'* || $val == *'&'* || $val == *$'\n'* ]]; then
    log_err "Configuration value for $key contains forbidden characters"
    return 1
  fi
  printf -v "$key" '%s' "$val"
}

# load_config_file FILE - parses KEY=VALUE lines; never executes the file.
load_config_file() {
  local file=$1 line key val n=0
  [[ -r $file ]] || { log_err "Cannot read configuration file: $file"; return 1; }
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    line=${line%%[[:space:]]#*}                      # strip trailing " # comment"
    [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
    if [[ $line =~ ^[[:space:]]*([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      key=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}
      val=${val%"${val##*[![:space:]]}"}            # rtrim
      if [[ $val =~ ^\"(.*)\"$ || $val =~ ^\'(.*)\'$ ]]; then val=${BASH_REMATCH[1]}; fi
      set_config "$key" "$val" || { log_err "$file:$n: rejected"; return 1; }
    else
      log_err "$file:$n: not a KEY=VALUE line"
      return 1
    fi
  done <"$file"
}

# ---------------------------------------------------------------------------
# Validation helpers (pure functions, unit-tested)
# ---------------------------------------------------------------------------
valid_ctid()     { [[ $1 =~ ^[0-9]+$ ]] && (($1 >= 100 && $1 <= 999999999)); }
valid_hostname() { [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; }
valid_username() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,30}$ && $1 != root ]]; }
valid_posint()   { [[ $1 =~ ^[0-9]+$ ]] && (($1 > 0)); }
valid_bool()     { [[ $1 == 0 || $1 == 1 ]]; }
valid_ipv4() {
  local ip=$1 o
  [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  local IFS=.
  for o in $ip; do ((10#$o <= 255)) || return 1; done
}
valid_cidr() { # a.b.c.d/nn
  [[ $1 =~ ^([0-9.]+)/([0-9]{1,2})$ ]] || return 1
  local ip=${BASH_REMATCH[1]} prefix=${BASH_REMATCH[2]}   # valid_ipv4 clobbers BASH_REMATCH
  valid_ipv4 "$ip" && ((prefix <= 32))
}
valid_ssh_pubkey() { [[ $1 =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh.com)\ [A-Za-z0-9+/=]+(\ [^\'\"\\]*)?$ ]]; }

# validate_config - prints every problem, returns non-zero if any.
validate_config() {
  local bad=0
  valid_ctid "$CTID"                 || { log_err "CTID must be an integer >= 100 (got '$CTID')"; bad=1; }
  valid_hostname "$CT_HOSTNAME"      || { log_err "CT_HOSTNAME is not a valid hostname (got '$CT_HOSTNAME')"; bad=1; }
  valid_posint "$CT_CORES"           || { log_err "CT_CORES must be a positive integer"; bad=1; }
  valid_posint "$CT_MEMORY"          || { log_err "CT_MEMORY must be a positive integer (MB)"; bad=1; }
  [[ $CT_SWAP =~ ^[0-9]+$ ]]         || { log_err "CT_SWAP must be an integer (MB, 0 disables)"; bad=1; }
  valid_posint "$CT_DISK"            || { log_err "CT_DISK must be a positive integer (GB)"; bad=1; }
  valid_bool "$CT_ONBOOT"            || { log_err "CT_ONBOOT must be 0 or 1"; bad=1; }
  valid_bool "$CT_NESTING"           || { log_err "CT_NESTING must be 0 or 1"; bad=1; }
  valid_bool "$ENABLE_HTTPS"         || { log_err "ENABLE_HTTPS must be 0 or 1"; bad=1; }
  valid_bool "$DEMO_DB"              || { log_err "DEMO_DB must be 0 or 1"; bad=1; }
  valid_bool "$UNATTENDED_UPGRADES"  || { log_err "UNATTENDED_UPGRADES must be 0 or 1"; bad=1; }
  valid_bool "$PROXMOX_FIREWALL"     || { log_err "PROXMOX_FIREWALL must be 0 or 1"; bad=1; }
  valid_bool "$SNAPSHOT_AFTER_DEPLOY" || { log_err "SNAPSHOT_AFTER_DEPLOY must be 0 or 1"; bad=1; }
  valid_posint "$NET_TIMEOUT"        || { log_err "NET_TIMEOUT must be a positive integer (seconds)"; bad=1; }
  [[ $BRIDGE =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || { log_err "BRIDGE is not a valid interface name"; bad=1; }
  [[ -z $VLAN_TAG || ( $VLAN_TAG =~ ^[0-9]+$ && $VLAN_TAG -ge 1 && $VLAN_TAG -le 4094 ) ]] \
                                     || { log_err "VLAN_TAG must be empty or 1-4094"; bad=1; }
  valid_username "$ADMIN_USER"       || { log_err "ADMIN_USER must be a lowercase non-root username (got '$ADMIN_USER')"; bad=1; }
  [[ $PROFILE =~ ^[a-z0-9][a-z0-9-]*$ ]] || { log_err "PROFILE must be lowercase letters, digits, hyphens"; bad=1; }
  [[ -z $SSH_MGMT_SUBNET ]] || valid_cidr "$SSH_MGMT_SUBNET" \
                                     || { log_err "SSH_MGMT_SUBNET must be empty or a.b.c.d/nn"; bad=1; }
  [[ -z $ADMIN_SSH_PUBKEY ]] || valid_ssh_pubkey "$ADMIN_SSH_PUBKEY" \
                                     || { log_err "ADMIN_SSH_PUBKEY is not a valid single-line public key"; bad=1; }
  case $NETWORK_MODE in
    dhcp) ;;
    static)
      valid_ipv4 "$STATIC_IP"          || { log_err "STATIC_IP is not a valid IPv4 address"; bad=1; }
      [[ $STATIC_PREFIX =~ ^[0-9]+$ && $STATIC_PREFIX -ge 1 && $STATIC_PREFIX -le 32 ]] \
                                       || { log_err "STATIC_PREFIX must be 1-32"; bad=1; }
      valid_ipv4 "$STATIC_GATEWAY"     || { log_err "STATIC_GATEWAY is not a valid IPv4 address"; bad=1; }
      valid_ipv4 "$STATIC_DNS"         || { log_err "STATIC_DNS is not a valid IPv4 address"; bad=1; }
      ;;
    *) log_err "NETWORK_MODE must be 'dhcp' or 'static'"; bad=1 ;;
  esac
  return "$bad"
}

show_config() {
  local k
  for k in "${CONFIG_KEYS[@]}"; do
    [[ $k == ADMIN_SSH_PUBKEY && -n ${!k:-} ]] && { printf '%-22s= (set)\n' "$k"; continue; }
    printf '%-22s= %s\n' "$k" "${!k:-}"
  done
}

# ---------------------------------------------------------------------------
# Proxmox helpers
# ---------------------------------------------------------------------------
require_root() { [[ $EUID -eq 0 ]] || die "$EX_VALIDATION" "Run as root on the Proxmox host."; }

require_pve_tools() {
  local t
  for t in pct pvesm pveam pvesh pveversion; do
    have "$t" || die "$EX_VALIDATION" "'$t' not found - run this on a Proxmox VE host."
  done
}

# pve_major - prints the major version from `pveversion` (pve-manager/9.0.3/...)
pve_major() {
  local v
  v=$(pveversion 2>/dev/null | sed -n 's|^pve-manager/\([0-9]*\)\..*|\1|p')
  printf '%s' "$v"
}

ct_exists()  { pct status "$1" >/dev/null 2>&1; }
ct_running() { [[ $(pct status "$1" 2>/dev/null | awk '{print $2}') == running ]]; }

# ct_exec CTID CMD... - run a command in the guest.
ct_exec() { local id=$1; shift; pct exec "$id" -- "$@"; }

# ct_ip CTID - first global IPv4 on eth0 (no guest agent needed).
ct_ip() {
  pct exec "$1" -- ip -4 -o addr show dev eth0 scope global 2>/dev/null \
    | awk '{split($4,a,"/"); print a[1]; exit}'
}

# wait_for_ip CTID TIMEOUT - echoes the address or returns 1.
wait_for_ip() {
  local id=$1 timeout=$2 i ip
  for ((i = 0; i < timeout; i += 2)); do
    ip=$(ct_ip "$id" || true)
    if [[ -n $ip ]]; then printf '%s' "$ip"; return 0; fi
    sleep 2
  done
  return 1
}

# ---------------------------------------------------------------------------
# Password prompt: result in REPLY, never written to disk, logs or argv.
# ---------------------------------------------------------------------------
read_new_password() { # sets REPLY
  local p1 p2
  if [[ ${PASSWORD_FROM_STDIN:-0} == 1 ]]; then
    IFS= read -r p1 || die "$EX_VALIDATION" "No password supplied on stdin"
  else
    [[ -t 0 ]] || die "$EX_VALIDATION" "No terminal for the password prompt; use --password-stdin."
    while :; do
      IFS= read -rsp "Password for '$ADMIN_USER' (min 12 chars): " p1 </dev/tty; echo >&2
      IFS= read -rsp "Confirm password: " p2 </dev/tty; echo >&2
      [[ $p1 == "$p2" ]] || { log_warn "Passwords do not match."; continue; }
      ((${#p1} >= 12)) || { log_warn "Password must be at least 12 characters."; continue; }
      break
    done
  fi
  ((${#p1} >= 12)) || die "$EX_VALIDATION" "Password must be at least 12 characters."
  [[ $p1 != *$'\n'* && $p1 != *$'\r'* ]] || die "$EX_VALIDATION" "Password contains a newline."
  REPLY=$p1
}
