#!/usr/bin/env bash
# profiles/ai-cli/guest.sh - runs INSIDE the container as root.
# Installs Claude Code (native installer) and OpenAI Codex CLI (standalone installer)
# for ADMIN_USER. Never authenticates. Idempotent; AI_CLI_UPDATE=1 reinstalls/updates.
set -euo pipefail
: "${ADMIN_USER:?}"
: "${AI_CLI_UPDATE:=0}"

log() { printf '[ai-cli] %s\n' "$*"; }
id -u "$ADMIN_USER" >/dev/null || { echo "admin user '$ADMIN_USER' missing; run the base deployment first" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl missing; run the base deployment first" >&2; exit 1; }
home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)

as_admin() { runuser -l "$ADMIN_USER" -c "$1"; }
has_cli() { as_admin "command -v $1" >/dev/null 2>&1; }

if [[ $AI_CLI_UPDATE == 1 ]] || ! has_cli claude; then
  log "installing Claude Code (https://claude.ai/install.sh)"
  as_admin 'curl -fsSL https://claude.ai/install.sh | bash'
else
  log "Claude Code already installed; skipping (AI_CLI_UPDATE=1 to refresh)"
fi

if [[ $AI_CLI_UPDATE == 1 ]] || ! has_cli codex; then
  log "installing Codex CLI (https://chatgpt.com/codex/install.sh)"
  as_admin 'curl -fsSL https://chatgpt.com/codex/install.sh | sh'
else
  log "Codex CLI already installed; skipping (AI_CLI_UPDATE=1 to refresh)"
fi

# PATH for every login shell. The installers' own bin dir is detected rather than
# assumed, so a changed upstream default location does not break the profile.
dirs=("$home/.local/bin")
for d in "$home/.codex/bin" "$home/.local/share/codex/bin" "$home/.cargo/bin"; do
  [[ -x $d/codex ]] && dirs+=("$d")
done
found=$(find "$home" -maxdepth 4 -type f -name codex -perm -u+x -not -path '*/node_modules/*' 2>/dev/null | head -n1 || true)
[[ -n $found ]] && dirs+=("$(dirname "$found")")
{
  echo '# Managed by proxmox-demo-factory (ai-cli profile)'
  for d in $(printf '%s\n' "${dirs[@]}" | awk '!s[$0]++'); do
    rel=${d#"$home"}
    # shellcheck disable=SC2016  # literal $PATH/$HOME belong in the generated file
    printf 'case ":$PATH:" in *":$HOME%s:"*) ;; *) [ -d "$HOME%s" ] && PATH="$HOME%s:$PATH";; esac\n' "$rel" "$rel" "$rel"
  done
  echo 'export PATH'
} >/etc/profile.d/demo-ai-cli.sh
chmod 644 /etc/profile.d/demo-ai-cli.sh

mkdir -p /etc/demo-factory/profiles
touch /etc/demo-factory/profiles/ai-cli

for cli in claude codex; do
  has_cli "$cli" || { echo "ERROR: $cli not found on the login PATH after install" >&2; exit 1; }
  log "$cli: $(as_admin "$cli --version" 2>&1 | head -n1)"
done
log "done - no authentication was performed. Log in interactively over SSH (docs/ai-cli.md)."
