#!/usr/bin/env bash
# scripts/verify-container.sh - host side verification. Sourced by deploy.sh.
# Requires lib/common.sh, scripts/configure-base.sh (guest_run/push helpers), loaded config.
# shellcheck shell=bash disable=SC2015

V_PASS=0; V_FAIL=0; V_WARN=0; V_SKIP=0
v_report() { # status name detail
  local color=$C_GRN
  case $1 in
    PASS) V_PASS=$((V_PASS + 1)) ;;
    FAIL) V_FAIL=$((V_FAIL + 1)); color=$C_RED ;;
    WARN) V_WARN=$((V_WARN + 1)); color=$C_YEL ;;
    SKIP) V_SKIP=$((V_SKIP + 1)); color=$C_CYN ;;
  esac
  printf '  %s%-4s%s  %-34s %s\n' "$color" "$1" "$C_OFF" "$2" "$3"
  { printf '%s verify %s %s %s\n' "$(date '+%F %T')" "$1" "$2" "$3" >>"$LOG_FILE"; } 2>/dev/null || true
}

cfg_value() { pct config "$CTID" 2>/dev/null | sed -n "s/^$1: //p"; }

verify_host_side() {
  local major
  major=$(pve_major)
  [[ $major == 9 ]] && v_report PASS "Proxmox VE 9.x" "$(pveversion | cut -d/ -f2)" || v_report FAIL "Proxmox VE 9.x" "major=${major:-unknown}"
  [[ $(cfg_value unprivileged) == 1 ]] && v_report PASS "LXC unprivileged" "unprivileged: 1" || v_report FAIL "LXC unprivileged" "unprivileged flag not set"
  local feat; feat=$(cfg_value features)
  [[ $feat != *nesting=1* ]] && v_report PASS "No LXC nesting" "${feat:-none}" \
    || { [[ $CT_NESTING == 1 ]] && v_report WARN "No LXC nesting" "nesting enabled by configuration" || v_report FAIL "No LXC nesting" "$feat"; }
  [[ $(cfg_value cores) == "$CT_CORES" ]] && v_report PASS "CPU cores" "$CT_CORES" || v_report FAIL "CPU cores" "expected $CT_CORES, got $(cfg_value cores)"
  [[ $(cfg_value memory) == "$CT_MEMORY" ]] && v_report PASS "Memory (MB)" "$CT_MEMORY" || v_report FAIL "Memory (MB)" "expected $CT_MEMORY, got $(cfg_value memory)"
  [[ $(cfg_value swap) == "$CT_SWAP" ]] && v_report PASS "Swap (MB)" "$CT_SWAP" || v_report FAIL "Swap (MB)" "expected $CT_SWAP, got $(cfg_value swap)"
  local rootfs; rootfs=$(cfg_value rootfs)
  if [[ $rootfs =~ size=([0-9]+)G ]] && [[ ${BASH_REMATCH[1]} == "$CT_DISK" ]]; then
    v_report PASS "Disk (GB)" "$CT_DISK"
  else
    v_report FAIL "Disk (GB)" "expected ${CT_DISK}G, got '${rootfs}'"
  fi
  local net; net=$(cfg_value net0)
  if [[ $NETWORK_MODE == dhcp ]]; then
    [[ $net == *ip=dhcp* ]] && v_report PASS "Network mode" "DHCP" || v_report FAIL "Network mode" "net0=$net"
  else
    [[ $net == *"ip=$STATIC_IP/$STATIC_PREFIX"* ]] && v_report PASS "Network mode" "static $STATIC_IP" || v_report FAIL "Network mode" "net0=$net"
  fi
  [[ $(cfg_value onboot) == "$CT_ONBOOT" ]] && v_report PASS "Start at boot" "$CT_ONBOOT" || v_report WARN "Start at boot" "onboot=$(cfg_value onboot)"
  verify_firewall
}

verify_firewall() {
  [[ $PROXMOX_FIREWALL == 1 ]] || { v_report SKIP "Proxmox firewall" "PROXMOX_FIREWALL=0"; return 0; }
  local fw="${PVE_FW_DIR:-/etc/pve/firewall}/$CTID.fw"
  if [[ -f $fw ]] && grep -qxF "$FW_MARKER" "$fw"; then
    local want; make_tmpdir; want=$REPLY/fw; render_fw_file >"$want"
    cmp -s "$want" "$fw" && v_report PASS "Firewall rules file" "$fw matches configuration" \
                         || v_report FAIL "Firewall rules file" "differs from configuration; re-run configure"
  else
    v_report FAIL "Firewall rules file" "missing or not factory-managed ($fw)"
  fi
  [[ $(cfg_value net0) == *firewall=1* ]] && v_report PASS "NIC firewall flag" "net0 firewall=1" || v_report FAIL "NIC firewall flag" "net0 lacks firewall=1"
  if firewall_effectiveness_report 2>/dev/null; then
    v_report PASS "Firewall enforced" "datacenter enabled, service active"
  else
    v_report WARN "Firewall enforced" "NOT enforced on this host - see warnings above / docs/security.md"
  fi
}

# ssh_login_test IP USER PASSWORD - real password login via a FIFO-fed askpass helper.
ssh_login_test() {
  local ip=$1 user=$2 pw=$3 dir fifo askpass out rc=0
  have ssh || { v_report SKIP "SSH password login" "ssh client not installed on host"; return 0; }
  make_tmpdir; dir=$REPLY; fifo=$dir/pw; askpass=$dir/askpass
  mkfifo -m 600 "$fifo"
  printf '#!/bin/sh\ncat %s\n' "$fifo" >"$askpass"; chmod 700 "$askpass"
  { printf '%s\n' "$pw" >"$fifo"; } &            # builtin printf: no argv exposure
  local wpid=$!
  out=$(SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=none timeout 30 ssh \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -o NumberOfPasswordPrompts=1 -o ConnectTimeout=10 \
        "$user@$ip" 'id -un' 2>&1 </dev/null) || rc=$?
  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
  if [[ $rc == 0 && $out == "$user" ]]; then
    v_report PASS "SSH password login" "$user@$ip authenticated"
  else
    v_report FAIL "SSH password login" "login as $user failed (rc=$rc); firewall/SSH_MGMT_SUBNET or wrong password?"
  fi
  # Root must be refused even with a (wrong) password attempt; check the rejection reason is auth, not network.
  out=$(timeout 20 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o BatchMode=yes -o ConnectTimeout=10 "root@$ip" true 2>&1 </dev/null || true)
  if [[ $out == *"Permission denied"* ]]; then
    v_report PASS "Root SSH login (live)" "refused by server"
  elif [[ $out == *"timed out"* || $out == *"refused"* ]]; then
    v_report SKIP "Root SSH login (live)" "could not reach sshd"
  else
    v_report FAIL "Root SSH login (live)" "unexpected result: ${out:0:80}"
  fi
}

verify_guest_side() {
  local status name detail
  while IFS='|' read -r tag status name detail; do
    [[ $tag == RESULT ]] || continue
    v_report "$status" "$name" "$detail"
  done < <(guest_run verify.sh "EXPECT_PROFILE=${1:-}" "EXPECT_HTTPS=$ENABLE_HTTPS" "EXPECT_SSH_ALLOW=$SSH_ALLOW_USERS" 2>&1 || true)
}

# verify_container [--reboot] [--test-login]
verify_container() {
  local do_reboot=0 do_login=0 a
  for a in "$@"; do
    case $a in --reboot) do_reboot=1 ;; --test-login) do_login=1 ;; esac
  done
  stage verify "$EX_VERIFY"
  ct_exists "$CTID" || die "$EX_VALIDATION" "Container $CTID does not exist."
  ct_running "$CTID" || die "$EX_VALIDATION" "Container $CTID is not running."
  V_PASS=0; V_FAIL=0; V_WARN=0; V_SKIP=0
  echo
  echo "Verification of CT $CTID ($CT_HOSTNAME)"
  echo "----------------------------------------------------------------"
  verify_host_side
  ct_exec "$CTID" install -d -m 0700 "$GUEST_DIR"
  pct push "$CTID" "$REPO_DIR/guest/verify.sh" "$GUEST_DIR/verify.sh" --perms 0700
  verify_guest_side "$PROFILE"
  local ip; ip=$(ct_ip "$CTID" || true)
  if ((do_login)); then
    if [[ -z ${ADMIN_PW_VERIFY:-} ]]; then read_new_password_for_test; fi
    ssh_login_test "$ip" "$ADMIN_USER" "$ADMIN_PW_VERIFY"
  elif [[ -n ${ADMIN_PW_HOLD:-} && -n $ip ]]; then
    ssh_login_test "$ip" "$ADMIN_USER" "$ADMIN_PW_HOLD"
  else
    v_report SKIP "SSH password login" "re-run with --test-login to test with your password"
  fi
  if ((do_reboot)); then
    log_info "Rebooting container to confirm services persist..."
    pct reboot "$CTID" >/dev/null
    sleep 5
    wait_for_ip "$CTID" "$NET_TIMEOUT" >/dev/null || v_report FAIL "Reboot persistence" "no IP after reboot"
    sleep 10
    local before=$V_FAIL
    verify_guest_side "$PROFILE"
    ((V_FAIL == before)) && v_report PASS "Reboot persistence" "services came back"
  fi
  echo "----------------------------------------------------------------"
  printf 'Result: %d passed, %d failed, %d warnings, %d skipped\n' "$V_PASS" "$V_FAIL" "$V_WARN" "$V_SKIP"
  ((V_FAIL == 0)) || return "$EX_VERIFY"
}

# Prompt (no confirmation, no policy) for an EXISTING password, for --test-login.
read_new_password_for_test() {
  if [[ ${PASSWORD_FROM_STDIN:-0} == 1 ]]; then IFS= read -r ADMIN_PW_VERIFY
  else IFS= read -rsp "Password for '$ADMIN_USER' (login test): " ADMIN_PW_VERIFY </dev/tty; echo >&2; fi
}
