#!/usr/bin/env bash
# tests/run-tests.sh - lightweight tests: static analysis + mocked host-side behaviour.
# These do NOT prove a live Proxmox deployment works; see docs/deployment.md#live-acceptance-test.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
t()    { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
tn()   { local name=$1; shift; if "$@" >/dev/null 2>&1; then bad "$name"; else ok "$name"; fi; }

TESTPW='Zq7!secret-Passw0rd#42'

new_env() { # fresh mock sandbox
  MOCK_DIR=$(mktemp -d); export MOCK_DIR
  export PATH="$REPO/tests/mocks:$PATH"
  export LOG_FILE="$MOCK_DIR/factory.log" PVE_FW_DIR="$MOCK_DIR/fw"
  mkdir -p "$PVE_FW_DIR"
  printf '[OPTIONS]\nenable: 1\n' >"$PVE_FW_DIR/cluster.fw"
}
D() { "$REPO/deploy.sh" -c /dev/null "$@"; }

echo "== Static analysis"
if command -v shellcheck >/dev/null; then
  t "shellcheck (warnings+)" shellcheck -x -S warning "$REPO"/deploy.sh "$REPO"/lib/*.sh "$REPO"/scripts/*.sh \
      "$REPO"/guest/*.sh "$REPO"/profiles/*/*.sh "$REPO"/tests/run-tests.sh
else
  echo "  skip  shellcheck not installed"
fi
for f in "$REPO"/deploy.sh "$REPO"/lib/*.sh "$REPO"/scripts/*.sh "$REPO"/guest/*.sh "$REPO"/profiles/*/*.sh; do
  t "bash -n ${f#"$REPO"/}" bash -n "$f"
done

echo "== Secrets hygiene"
tn "no password logging remnants" grep -rEn 'ADMIN CREDENTIALS|password=\$|ADMIN_TEMP_PW|--password ' "$REPO" --include=*.sh --exclude-dir=tests --exclude-dir=.git
tn "no keys/tokens committed" grep -rEIn '(sk-ant-|sk-proj-|ghp_[A-Za-z0-9]{20}|BEGIN (RSA|OPENSSH) PRIVATE KEY)' "$REPO" --exclude-dir=.git --exclude-dir=tests
t  "defaults.env has no password key" bash -c "! grep -iE '^[A-Z_]*PASS' '$REPO/config/defaults.env'"

echo "== Config parsing and validation"
# shellcheck source=../lib/common.sh
source "$REPO/lib/common.sh"; LOG_FILE=/dev/null
load_config_file "$REPO/config/defaults.env" 2>/dev/null
t  "defaults: 2 vCPU"  test "$CT_CORES" = 2
t  "defaults: 4096 MB" test "$CT_MEMORY" = 4096
t  "defaults: 1024 swap" test "$CT_SWAP" = 1024
t  "defaults: 40 GB"   test "$CT_DISK" = 40
t  "defaults: DHCP"    test "$NETWORK_MODE" = dhcp
t  "defaults validate" validate_config
tmp=$(mktemp); printf 'CT_MEMORY="8192"   # comment\n# note\n\nBRIDGE=vmbr1\n' >"$tmp"
t  "config file parse" load_config_file "$tmp"
t  "quotes/comments handled" test "$CT_MEMORY" = 8192 -a "$BRIDGE" = vmbr1
printf 'CT_HOSTNAME=$(touch /tmp/pwned)\n' >"$tmp";  tn "rejects command substitution" load_config_file "$tmp"
printf 'CT_HOSTNAME=a;rm -rf /\n' >"$tmp";            tn "rejects shell metacharacters" load_config_file "$tmp"
printf 'NOT_A_KEY=1\n' >"$tmp";                       tn "rejects unknown key" load_config_file "$tmp"
printf 'garbage line\n' >"$tmp";                      tn "rejects non-assignment line" load_config_file "$tmp"
printf 'ADMIN_PASSWORD=hunter2\n' >"$tmp";            tn "rejects password key in config" load_config_file "$tmp"
rm -f "$tmp"
t  "valid_ctid 201" valid_ctid 201;      tn "valid_ctid 5" valid_ctid 5;       tn "valid_ctid abc" valid_ctid abc
t  "valid_hostname" valid_hostname demo-ai-01; tn "bad hostname (underscore)" valid_hostname demo_ai
tn "root rejected as admin" valid_username root; t "valid_username" valid_username demoadmin
t  "valid_ipv4" valid_ipv4 10.0.0.5;     tn "invalid ipv4 999" valid_ipv4 10.0.0.999
t  "valid_cidr" valid_cidr 192.168.1.0/24; tn "invalid cidr /33" valid_cidr 192.168.1.0/33
t  "ssh pubkey ok" valid_ssh_pubkey 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIabc user@host'
tn "ssh pubkey injection" valid_ssh_pubkey "ssh-ed25519 AAAA' ; touch /x #"
CTID=abc; tn "validate_config catches bad CTID" validate_config; CTID=201; export CTID
NETWORK_MODE=static; tn "static mode needs address" validate_config; NETWORK_MODE=dhcp

echo "== Host flow with mocked Proxmox tools"
new_env
D config 2>&1 | grep -q 'CT_MEMORY *= 4096'; t "config command shows 4096" test $? -eq 0
t  "check passes" D check
t  "storage lists" D storage
MOCK_PVE=8.4.1 D check >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "PVE 8 rejected (exit 2)" || bad "PVE 8 rejected (exit 2)"
D --storage nope check >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "unknown storage rejected" || bad "unknown storage rejected"
D --storage tank check >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "inactive storage rejected" || bad "inactive storage rejected"
D --profile nosuch check >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "unknown profile rejected" || bad "unknown profile rejected"

: >"$MOCK_DIR/pct.log"
D plan >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "plan exits 0" || bad "plan exits 0 (rc=$rc)"
grep -qE '^pct (create|start|push)' "$MOCK_DIR/pct.log" && bad "plan made no changes" || ok "plan made no changes"
grep -q 'pveam download' "$MOCK_DIR/pveam.log" 2>/dev/null && bad "plan did not download" || ok "plan did not download"

# Occupied CTID is refused.
echo "__state: running" >"$MOCK_DIR/ct-201"; : >"$MOCK_DIR/pct.log"
echo "$TESTPW" | D --password-stdin deploy >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "deploy refuses existing CTID (exit 2)" || bad "deploy refuses existing CTID (rc=$rc)"
grep -qE '^pct (create|destroy)' "$MOCK_DIR/pct.log" && bad "no create/destroy on occupied CTID" || ok "no create/destroy on occupied CTID"
rm -f "$MOCK_DIR/ct-201"

# Full mocked deploy.
: >"$MOCK_DIR/pct.log"
export EXPECT_PW="$TESTPW"
out=$(echo "$TESTPW" | D --password-stdin --mgmt-subnet 192.168.50.0/24 deploy 2>&1); rc=$?
echo "$out" | grep -q 'PASS  SSH password login' && ok "SSH login test ran with password via FIFO askpass" || bad "SSH login test ran"
echo "$out" | grep -q 'PASS  Root SSH login (live)' && ok "root SSH refusal test ran" || bad "root SSH refusal test ran"
[[ $rc -eq 0 ]] && ok "mocked deploy completes" || { bad "mocked deploy completes (rc=$rc)"; echo "$out" | tail -15; }
grep -q 'pveam download local ubuntu-24.04-standard_24.10-2_amd64.tar.zst' "$MOCK_DIR/pveam.log" && ok "newest template chosen via pveam" || bad "newest template chosen via pveam"
grep -q 'pct create 201 .*--unprivileged 1' "$MOCK_DIR/pct.log" && ok "create: unprivileged" || bad "create: unprivileged"
grep -q -- '--cores 2 --memory 4096 --swap 1024 --rootfs local-lvm:40' "$MOCK_DIR/pct.log" && ok "create: 2/4096/1024/40GB on local-lvm" || bad "create: resources"
grep -q -- 'ip=dhcp' "$MOCK_DIR/pct.log" && ok "create: DHCP" || bad "create: DHCP"
grep -q -- '--password' "$MOCK_DIR/pct.log" && bad "no pct --password" || ok "no pct --password"
grep -q -- '--features' "$MOCK_DIR/pct.log" && bad "no nesting by default" || ok "no nesting by default"
echo "$out" | grep -q '192.168.50.23' && ok "reports assigned IP" || bad "reports assigned IP"
grep -qF "$TESTPW" "$MOCK_DIR/pct.log" && bad "password absent from pct argv" || ok "password absent from pct argv"
grep -qF "$TESTPW" "$LOG_FILE" && bad "password absent from log file" || ok "password absent from log file"
echo "$out" | grep -qF "$TESTPW" && bad "password absent from console output" || ok "password absent from console output"
grep -q "^demoadmin:" "$MOCK_DIR/chpasswd.stdin.1" && ok "password delivered via stdin to chpasswd" || bad "password delivered via stdin"
grep -rqF "$TESTPW" "$MOCK_DIR" --exclude='chpasswd.stdin.*' && bad "password on no other disk file" || ok "password on no other disk file"
[[ -f "$PVE_FW_DIR/201.fw" ]] && grep -q 'IN SSH(ACCEPT) -source 192.168.50.0/24' "$PVE_FW_DIR/201.fw" && ok "firewall: SSH limited to mgmt subnet" || bad "firewall: SSH limited"
grep -q 'IN HTTPS' "$PVE_FW_DIR/201.fw" && bad "firewall: no 443 unless HTTPS" || ok "firewall: no 443 unless HTTPS"
grep -q 'policy_in: DROP' "$PVE_FW_DIR/201.fw" && ok "firewall: default-deny inbound" || bad "firewall: default-deny"
grep -qE 'cluster|datacenter' "$MOCK_DIR/pct.log" && bad "host firewall untouched" || ok "host firewall untouched"

# Idempotency: reconfigure must not reset the password or duplicate rules.
cp "$PVE_FW_DIR/201.fw" "$MOCK_DIR/fw.before"
out=$(D --mgmt-subnet 192.168.50.0/24 configure 2>&1 </dev/null); rc=$?
[[ $rc -eq 0 ]] && ok "configure on existing CT succeeds" || { bad "configure on existing CT (rc=$rc)"; echo "$out" | tail; }
[[ $(ls "$MOCK_DIR"/chpasswd.stdin.* | wc -l) -eq 1 ]] && ok "configure does not reset password" || bad "configure does not reset password"
cmp -s "$PVE_FW_DIR/201.fw" "$MOCK_DIR/fw.before" && ok "firewall file idempotent" || bad "firewall file idempotent"
[[ $(grep -c 'IN SSH' "$PVE_FW_DIR/201.fw") -eq 1 ]] && ok "no duplicate firewall rules" || bad "no duplicate firewall rules"

# Foreign firewall file is not overwritten.
echo "[RULES]" >"$PVE_FW_DIR/201.fw"
D configure >/dev/null 2>&1 </dev/null
[[ $(cat "$PVE_FW_DIR/201.fw") == "[RULES]" ]] && ok "foreign firewall file preserved" || bad "foreign firewall file preserved"

# Template caching: no download when cached.
touch "$MOCK_DIR/template-cached"; : >"$MOCK_DIR/pveam.log"; rm -f "$MOCK_DIR"/ct-*
echo "$TESTPW" | D --password-stdin --ctid 202 deploy >/dev/null 2>&1
grep -q download "$MOCK_DIR/pveam.log" && bad "cached template not re-downloaded" || ok "cached template not re-downloaded"

# Verify detects drift.
sed -i 's/^memory: .*/memory: 2048/' "$MOCK_DIR/ct-202"
D --ctid 202 verify >/dev/null 2>&1; [[ $? -eq 9 ]] && ok "verify fails on wrong memory (exit 9)" || bad "verify fails on wrong memory"

# Static networking string, and refusing bad input.
t  "static net0 string" bash -c "source '$REPO/lib/common.sh'; source '$REPO/scripts/create-container.sh'; BRIDGE=vmbr0 PROXMOX_FIREWALL=1 VLAN_TAG='' NETWORK_MODE=static STATIC_IP=10.1.1.5 STATIC_PREFIX=24 STATIC_GATEWAY=10.1.1.1; [[ \$(net0_string) == *ip=10.1.1.5/24,gw=10.1.1.1 ]]"
D --static 10.1.1.999/24 --gateway 10.1.1.1 --dns 10.1.1.1 check >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "bad static IP rejected" || bad "bad static IP rejected"
D --password-stdin --ctid 203 deploy </dev/null >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "empty password rejected" || bad "empty password rejected"
echo short | D --password-stdin --ctid 203 deploy >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "short password rejected" || bad "short password rejected"
[[ ! -f "$MOCK_DIR/ct-203" ]] && ok "no container created after password rejection" || bad "no container created after password rejection"

unset EXPECT_PW
rm -rf "$MOCK_DIR"
echo
echo "Passed: $PASS  Failed: $FAIL"
((FAIL == 0))
