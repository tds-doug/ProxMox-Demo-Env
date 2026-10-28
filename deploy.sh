#!/usr/bin/env bash
# deploy.sh - Proxmox Demo Environment Factory entry point (run as root on the PVE host).
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export REPO_DIR

# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"
# shellcheck source=scripts/create-container.sh
source "$REPO_DIR/scripts/create-container.sh"
# shellcheck source=scripts/configure-base.sh
source "$REPO_DIR/scripts/configure-base.sh"
# shellcheck source=scripts/verify-container.sh
source "$REPO_DIR/scripts/verify-container.sh"
# shellcheck source=scripts/clean-credentials.sh
source "$REPO_DIR/scripts/clean-credentials.sh"

usage() {
  cat <<'USAGE'
Usage: ./deploy.sh [options] <command> [args]

Commands:
  deploy                 Create a new container and fully configure it (refuses an existing CTID)
  configure              Re-apply base + hardening (+ profile) to an EXISTING container
                         (non-destructive; also how you resume a failed run)
  profile <name>         Apply one demo profile (base | ai-cli) to an existing base container
  verify                 Run all checks against an existing container
  plan                   Show what 'deploy' would do; changes nothing
  check                  Validate host prerequisites, configuration and storage only
  config                 Print the effective configuration
  storage                List storage usable for containers and templates
  snapshot               Snapshot the container (if its storage supports it)
  clean-ai-credentials   Remove saved Claude/Codex logins and session data from the container
  help                   This text

Options (override config/demo.env, which overrides config/defaults.env):
  -c, --config FILE      Use FILE instead of config/demo.env
      --ctid N           --hostname NAME      --profile base|ai-cli
      --cores N          --memory MB          --swap MB          --disk GB
      --storage NAME     --template-storage NAME     --bridge NAME
      --admin-user NAME  --mgmt-subnet CIDR   --https
      --static IP/PREFIX --gateway IP         --dns IP
      --password-stdin   Read the admin password from stdin (automation)
      --test-login       (verify) prompt for the password and test a real SSH login
      --reboot           (verify) reboot the container and re-check services
  -n, --dry-run          Print actions without changing anything
  -y, --yes              Do not ask for confirmation
  -h, --help

Examples:
  sudo ./deploy.sh plan
  sudo ./deploy.sh --profile ai-cli deploy
  sudo ./deploy.sh --ctid 201 verify --test-login
USAGE
}

# --- defaults and config files ----------------------------------------------------------
load_config_file "$REPO_DIR/config/defaults.env" || exit "$EX_VALIDATION"

CONFIG_FILE=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case ${args[i]} in -c|--config) CONFIG_FILE=${args[i + 1]:-} ;; esac
done
if [[ -n $CONFIG_FILE ]]; then
  load_config_file "$CONFIG_FILE" || exit "$EX_VALIDATION"
elif [[ -f $REPO_DIR/config/demo.env ]]; then
  load_config_file "$REPO_DIR/config/demo.env" || exit "$EX_VALIDATION"
fi

# --- command line --------------------------------------------------------------------------
COMMAND=""; PROFILE_ARG=""; VERIFY_ARGS=()
need() { [[ $# -ge 2 && -n $2 ]] || die "$EX_VALIDATION" "Option $1 needs a value"; }
while (($#)); do
  case $1 in
    -c|--config) need "$@"; shift 2 ;;
    --ctid)            need "$@"; set_config CTID "$2" || exit "$EX_VALIDATION"; shift 2 ;;
    --hostname)        need "$@"; set_config CT_HOSTNAME "$2" || exit "$EX_VALIDATION"; shift 2 ;;
    --profile)         need "$@"; set_config PROFILE "$2" || exit "$EX_VALIDATION"; shift 2 ;;
    --cores)           need "$@"; set_config CT_CORES "$2" || exit "$EX_VALIDATION"; shift 2 ;;
    --memory)          need "$@"; set_config CT_MEMORY "$2" || exit "$EX_VALIDATION"; shift 2 ;;
    --swap)            need "$@"; set_config CT_SWAP "$2" || exit "$EX_VALIDATION"; shift 2 ;;
    --disk)            need "$@"; set_config CT_DISK "$2" || exit "$EX_VALIDATION"; shift 2 ;;
    --storage)         need "$@"; set_config STORAGE "$2" || exit "$EX_VALIDATION"; shift 2 ;;
    --template-storage) need "$@"; set_config TEMPLATE_STORAGE "$2" || exit "$EX_VALIDATION"; shift 2 ;;
    --bridge)          need "$@"; set_config BRIDGE "$2" || exit "$EX_VALIDATION"; shift 2 ;;
    --admin-user)      need "$@"; set_config ADMIN_USER "$2" || exit "$EX_VALIDATION"; shift 2 ;;
    --mgmt-subnet)     need "$@"; set_config SSH_MGMT_SUBNET "$2" || exit "$EX_VALIDATION"; shift 2 ;;
    --https)           ENABLE_HTTPS=1; shift ;;
    --static)          need "$@"; NETWORK_MODE=static
                       set_config STATIC_IP "${2%/*}" || exit "$EX_VALIDATION"
                       set_config STATIC_PREFIX "${2#*/}" || exit "$EX_VALIDATION"; shift 2 ;;
    --gateway)         need "$@"; set_config STATIC_GATEWAY "$2" || exit "$EX_VALIDATION"; shift 2 ;;
    --dns)             need "$@"; set_config STATIC_DNS "$2" || exit "$EX_VALIDATION"; shift 2 ;;
    --password-stdin)  PASSWORD_FROM_STDIN=1; shift ;;
    --test-login|--reboot) VERIFY_ARGS+=("$1"); shift ;;
    -n|--dry-run)      DRY_RUN=1; shift ;;
    -y|--yes)          ASSUME_YES=1; shift ;;
    -h|--help)         COMMAND=help; shift ;;
    -*)                die "$EX_VALIDATION" "Unknown option: $1 (see ./deploy.sh help)" ;;
    *)
      if [[ -z $COMMAND ]]; then COMMAND=$1
      elif [[ $COMMAND == profile && -z $PROFILE_ARG ]]; then PROFILE_ARG=$1
      else die "$EX_VALIDATION" "Unexpected argument: $1"; fi
      shift ;;
  esac
done
[[ -n $SSH_ALLOW_USERS ]] || SSH_ALLOW_USERS=$ADMIN_USER

# --- flows ----------------------------------------------------------------------------------------
apply_profile() { # name
  local p=$1
  if [[ $p == base ]]; then log_info "Profile 'base': nothing further to install."; return 0; fi
  [[ -f $REPO_DIR/profiles/$p/install.sh ]] || die "$EX_VALIDATION" "Unknown profile '$p' (profiles/$p/install.sh missing)."
  # shellcheck source=/dev/null
  source "$REPO_DIR/profiles/$p/install.sh"
  profile_install
}

summary() {
  local ip=${CT_IP_ADDR:-$(ct_ip "$CTID" || true)}
  echo
  echo "================================================================"
  echo " Deployment summary"
  echo "================================================================"
  echo "  Container : $CTID ($CT_HOSTNAME)   ${CT_CORES} vCPU / ${CT_MEMORY} MB / ${CT_DISK} GB"
  echo "  Address   : ${ip:-unknown} ($NETWORK_MODE)"
  echo "  Profile   : $PROFILE"
  echo "  Web       : http://${ip:-<ip>}/"
  echo "  SSH       : ssh $ADMIN_USER@${ip:-<ip>}      (root login disabled)"
  echo "  Console   : pct enter $CTID                  (emergency root access from this host)"
  echo "  Verify    : ./deploy.sh --ctid $CTID verify --test-login"
  echo "  Log       : $LOG_FILE"
  if [[ $PROFILE == ai-cli ]]; then
    echo "  AI CLIs   : NOT authenticated. SSH in, then run: claude   |   codex login --device-auth"
    echo "              (see docs/ai-cli.md)"
  fi
  echo "================================================================"
}

cmd_prechecks() {
  preflight
  resolve_storage
  log_ok "Configuration and prerequisites are valid"
}

cmd_deploy() {
  cmd_prechecks
  if ct_exists "$CTID"; then
    die "$EX_VALIDATION" "CTID $CTID already exists; refusing to modify it. Use 'configure' for an existing container."
  fi
  if ! ((DRY_RUN)); then read_new_password; ADMIN_PW_HOLD=$REPLY; fi
  ensure_template
  create_container
  start_container
  wait_network
  create_admin_user
  configure_base
  harden_container
  apply_profile "$PROFILE"
  if ((DRY_RUN)); then log_info "Plan complete; nothing was changed."; return 0; fi
  # The password is still in memory only: verify uses it for a real SSH login test.
  if ! verify_container; then
    ADMIN_PW_HOLD=""
    log_warn "Verification reported failures; container left running for investigation."
    summary
    exit "$EX_VERIFY"
  fi
  ADMIN_PW_HOLD=""
  if [[ $SNAPSHOT_AFTER_DEPLOY == 1 ]]; then cmd_snapshot || log_warn "Snapshot skipped/failed (non-fatal)"; fi
  summary
}

require_existing_ct() {
  preflight
  ct_exists "$CTID" || die "$EX_VALIDATION" "Container $CTID does not exist."
  [[ $(pct config "$CTID" | sed -n 's/^unprivileged: //p') == 1 ]] || die "$EX_VALIDATION" "CT $CTID is not unprivileged; refusing."
  if ! ct_running "$CTID"; then stage start "$EX_START"; run pct start "$CTID"; fi
}

cmd_configure() {
  require_existing_ct
  CT_IP_ADDR=$(wait_for_ip "$CTID" "$NET_TIMEOUT") || die "$EX_NETWORK" "Container has no IPv4 address."
  if ! ct_exec "$CTID" id -u "$ADMIN_USER" >/dev/null 2>&1; then
    if ! ((DRY_RUN)); then read_new_password; ADMIN_PW_HOLD=$REPLY; fi
    create_admin_user
  fi
  configure_base
  harden_container
  apply_profile "$PROFILE"
  verify_container || { ADMIN_PW_HOLD=""; exit "$EX_VERIFY"; }
  ADMIN_PW_HOLD=""
  summary
}

cmd_profile() {
  [[ -n $PROFILE_ARG ]] || die "$EX_VALIDATION" "Usage: ./deploy.sh profile <name>"
  require_existing_ct
  ct_exec "$CTID" test -e /etc/demo-factory/profiles/base || die "$EX_VALIDATION" "CT $CTID has no base install; run 'configure' first."
  PROFILE=$PROFILE_ARG
  if ! ((DRY_RUN)); then push_guest_files; fi
  apply_profile "$PROFILE"
  log_ok "Profile '$PROFILE' applied to CT $CTID"
}

cmd_verify() {
  preflight
  verify_container "${VERIFY_ARGS[@]}"
}

cmd_snapshot() {
  ct_exists "$CTID" || die "$EX_VALIDATION" "Container $CTID does not exist."
  local st name
  st=$(cfg_value rootfs); st=${st%%:*}
  case $(storage_type "$st") in
    zfspool|lvmthin|btrfs|rbd|cephfs) ;;
    *) log_warn "Storage '$st' ($(storage_type "$st")) may not support container snapshots." ;;
  esac
  name="clean-$(date +%Y%m%d-%H%M)"
  run pct snapshot "$CTID" "$name" --description "Factory baseline. Snapshots hold the admin password hash; clean AI logins first." \
    || { log_warn "pct snapshot failed - storage likely lacks snapshot support. Use vzdump or rebuild instead."; return 1; }
  log_ok "Snapshot '$name' created"
}

cmd_storage() {
  require_root; require_pve_tools
  echo "Usable for container root filesystems (rootdir):"; pvesm_storages rootdir | sed 's/^/  /'
  echo "Usable for templates (vztmpl):";                  pvesm_storages vztmpl | sed 's/^/  /'
}

case $COMMAND in
  deploy|configure|profile|verify|snapshot|clean-ai-credentials) enable_error_trap ;;
esac

case $COMMAND in
  deploy)    cmd_deploy ;;
  configure) cmd_configure ;;
  profile)   cmd_profile ;;
  verify)    cmd_verify ;;
  plan)      DRY_RUN=1; cmd_deploy ;;
  check)     cmd_prechecks ;;
  config)    validate_config || true; show_config ;;
  storage)   cmd_storage ;;
  snapshot)  preflight; cmd_snapshot ;;
  clean-ai-credentials) preflight; clean_ai_credentials ;;
  help|"")   usage ;;
  *)         die "$EX_VALIDATION" "Unknown command: $COMMAND (see ./deploy.sh help)" ;;
esac
