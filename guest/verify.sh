#!/usr/bin/env bash
# guest/verify.sh - runs INSIDE the container as root. Emits machine-readable lines:
#   RESULT|PASS|FAIL|WARN|SKIP|<check>|<detail>
# Read-only except for short-lived probe files it removes itself.
# shellcheck disable=SC2015  # res() always succeeds, so A && B || C is safe here
set -uo pipefail

: "${ADMIN_USER:?}"
: "${EXPECT_PROFILE:=}"
: "${EXPECT_HTTPS:=0}"
: "${EXPECT_SSH_ALLOW:=$ADMIN_USER}"

res() { printf 'RESULT|%s|%s|%s\n' "$1" "$2" "$3"; }
check() { # name detail cmd...
  local name=$1 detail=$2; shift 2
  if "$@" >/dev/null 2>&1; then res PASS "$name" "$detail"; else res FAIL "$name" "$detail"; fi
}

# ---- OS -------------------------------------------------------------------------
# shellcheck disable=SC1091
. /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]] && res PASS "Ubuntu 24.04" "$PRETTY_NAME" || res FAIL "Ubuntu 24.04" "$PRETTY_NAME"

# ---- Network ----------------------------------------------------------------------
ip=$(ip -4 -o addr show dev "${NET_IF:-eth0}" scope global | awk '{split($4,a,"/"); print a[1]; exit}')
[[ -n $ip ]] && res PASS "IPv4 address" "$ip" || res FAIL "IPv4 address" "none on eth0"
check "DNS resolution" "archive.ubuntu.com" getent hosts archive.ubuntu.com
check "Outbound HTTP" "archive.ubuntu.com:80" curl -fsS -m 10 -o /dev/null http://archive.ubuntu.com/ubuntu/dists/noble/Release
check "Outbound HTTPS" "archive.ubuntu.com:443" curl -fsS -m 10 -o /dev/null -I https://archive.ubuntu.com/ubuntu/

# ---- Services ----------------------------------------------------------------------
for svc in apache2 mariadb ssh; do
  check "Service $svc" "active + enabled" bash -c "systemctl is-active --quiet $svc && systemctl is-enabled --quiet $svc"
done
failed=$(systemctl --failed --no-legend 2>/dev/null | awk '{print $2}' | paste -sd, -)
[[ -z $failed ]] && res PASS "No failed units" "systemctl --failed empty" || res WARN "No failed units" "$failed"

# ---- Apache -------------------------------------------------------------------------
host=$(hostname)
body=$(curl -fsS -m 10 http://127.0.0.1/ 2>/dev/null || true)
[[ $body == *"$host"* ]] && res PASS "Apache serves landing page" "HTTP 200, hostname present" || res FAIL "Apache serves landing page" "hostname not in response"
hdr=$(curl -sI -m 10 http://127.0.0.1/ | tr -d '\r' | awk -F': ' 'tolower($1)=="server" {print $2}')
[[ $hdr == Apache ]] && res PASS "Apache version hidden" "Server: $hdr" || res FAIL "Apache version hidden" "Server: $hdr"
probe=/var/www/html/.verify-probe-$$
mkdir -p "$probe" && touch "$probe/x"
code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1/${probe##*/}/")
rm -rf "$probe"
[[ $code == 403 || $code == 404 ]] && res PASS "Directory listing disabled" "HTTP $code (no listing)" || res FAIL "Directory listing disabled" "HTTP $code"
if [[ $EXPECT_HTTPS == 1 ]]; then
  check "Apache HTTPS" "self-signed on 443" curl -fsSk -m 10 -o /dev/null https://127.0.0.1/
fi

# ---- MariaDB ---------------------------------------------------------------------------
listen=$(ss -ltnH 'sport = :3306' | awk '{print $4}' | paste -sd, -)
if [[ $listen == "127.0.0.1:3306" ]]; then res PASS "MariaDB local-only" "$listen"; else res FAIL "MariaDB local-only" "${listen:-not listening}"; fi
anon=$(mariadb --batch --skip-column-names -e "SELECT COUNT(*) FROM mysql.user WHERE User=''" 2>/dev/null || echo ?)
[[ $anon == 0 ]] && res PASS "No anonymous DB users" "0" || res FAIL "No anonymous DB users" "$anon"
rroot=$(mariadb --batch --skip-column-names -e "SELECT COUNT(*) FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1')" 2>/dev/null || echo ?)
[[ $rroot == 0 ]] && res PASS "No remote root" "0" || res FAIL "No remote root" "$rroot"

# ---- Languages --------------------------------------------------------------------------
check "PHP CLI" "$(php -r 'echo PHP_VERSION;' 2>/dev/null)" php -r 'exit(0);'
out=$(curl -fsS -m 10 http://127.0.0.1/demo/php-test.php 2>/dev/null || true)
[[ $out == PHP-OK* ]] && res PASS "PHP via Apache" "${out%%$'\n'*}" || res FAIL "PHP via Apache" "unexpected output"
out=$(curl -sS -m 10 http://127.0.0.1/demo/db-test.php 2>/dev/null || true)
case $out in
  DB-OK*)   res PASS "PHP to MariaDB" "${out%%$'\n'*}" ;;
  DB-SKIP*) res SKIP "PHP to MariaDB" "demo database disabled" ;;
  *)        res FAIL "PHP to MariaDB" "${out%%$'\n'*}" ;;
esac
check "Python 3" "$(python3 -V 2>&1)" python3 -c 'import sys'
tmp=$(mktemp -d)
if python3 -m venv "$tmp/v" >/dev/null 2>&1 && "$tmp/v/bin/pip" --version >/dev/null 2>&1; then
  res PASS "Python venv + pip" "$("$tmp/v/bin/pip" --version | cut -d' ' -f1-2)"
else
  res FAIL "Python venv + pip" "venv creation failed"
fi
rm -rf "$tmp"
check "Perl" "$(perl -e 'print $^V')" perl -MDBI -e 'print "ok"'

# ---- SSH / accounts ------------------------------------------------------------------------
eff=$(sshd -T -C "user=$ADMIN_USER,host=localhost,addr=127.0.0.1" 2>/dev/null)
get() { awk -v k="$1" '$1==k {print $2; exit}' <<<"$eff"; }
[[ $(get permitrootlogin) == no ]] && res PASS "Root SSH login denied" "permitrootlogin no (effective)" || res FAIL "Root SSH login denied" "permitrootlogin $(get permitrootlogin)"
[[ $(get passwordauthentication) == yes ]] && res PASS "SSH password auth enabled" "effective" || res FAIL "SSH password auth enabled" "$(get passwordauthentication)"
[[ $(get permitemptypasswords) == no ]] && res PASS "Empty passwords denied" "effective" || res FAIL "Empty passwords denied" "$(get permitemptypasswords)"
(( $(get maxauthtries) <= 6 )) && res PASS "SSH MaxAuthTries" "$(get maxauthtries)" || res FAIL "SSH MaxAuthTries" "$(get maxauthtries)"
allow=$(awk '$1=="allowusers" {$1=""; print $0}' <<<"$eff" | xargs)
[[ $allow == "$EXPECT_SSH_ALLOW" ]] && res PASS "SSH AllowUsers" "$allow" || res FAIL "SSH AllowUsers" "$allow"
getent passwd "$ADMIN_USER" | grep -q ':/bin/bash$' && res PASS "Admin user shell/home" "$ADMIN_USER bash" || res FAIL "Admin user shell/home" "$ADMIN_USER"
id -nG "$ADMIN_USER" | grep -qw sudo && res PASS "Admin in sudo group" "$ADMIN_USER" || res FAIL "Admin in sudo group" "$ADMIN_USER"
if grep -rqs 'NOPASSWD' /etc/sudoers /etc/sudoers.d; then res FAIL "sudo requires password" "NOPASSWD rule found"; else res PASS "sudo requires password" "no NOPASSWD rules"; fi
[[ $(stat -c %a "$(getent passwd "$ADMIN_USER" | cut -d: -f6)") -le 750 ]] && res PASS "Admin home permissions" "<=750" || res WARN "Admin home permissions" ">750"
ext=$(ss -ltnH | awk '{print $4}' | grep -Ev '^(127\.|\[::1\]|::1)' | awk -F: '{print $NF}' | sort -un | paste -sd' ' -)
bad=""
for p in $ext; do case $p in 22|80) ;; 443) [[ $EXPECT_HTTPS == 1 ]] || bad+="$p ";; *) bad+="$p ";; esac; done
[[ -z $bad ]] && res PASS "Only expected ports exposed" "tcp: $ext" || res FAIL "Only expected ports exposed" "unexpected: $bad"

# ---- Profiles ---------------------------------------------------------------------------------
if [[ $EXPECT_PROFILE == ai-cli || -e /etc/demo-factory/profiles/ai-cli ]]; then
  for url in https://claude.ai https://downloads.claude.ai https://chatgpt.com; do
    # Any HTTP response counts: we only test that the endpoint is reachable.
    if curl -sS -m 10 -o /dev/null "$url" 2>/dev/null; then res PASS "Reach ${url#https://}" "TLS ok"; else res WARN "Reach ${url#https://}" "unreachable (needed to install/use the CLI)"; fi
  done
  for cli in claude codex; do
    v=$(runuser -l "$ADMIN_USER" -c "$cli --version" 2>&1 | head -n1)
    if runuser -l "$ADMIN_USER" -c "command -v $cli" >/dev/null 2>&1 && [[ -n $v ]]; then
      res PASS "$cli CLI" "$v"
    else
      res FAIL "$cli CLI" "not found in login-shell PATH"
    fi
  done
  home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
  creds=""
  [[ -s $home/.claude/.credentials.json ]] && creds+="claude "
  [[ -s $home/.codex/auth.json ]] && creds+="codex "
  [[ -z $creds ]] && res PASS "AI CLIs unauthenticated (clean)" "no saved credentials" \
                  || res WARN "AI CLIs unauthenticated (clean)" "saved login present: $creds(expected after first use)"
fi
