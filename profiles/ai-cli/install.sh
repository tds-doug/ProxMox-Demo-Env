#!/usr/bin/env bash
# profiles/ai-cli/install.sh - host side hook, sourced by deploy.sh.
# Contract: define `profile_install` (pushes guest.sh and runs it). Base logic is not duplicated.
# shellcheck shell=bash

profile_install() {
  stage "profile:ai-cli" "$EX_PROFILE"
  ((DRY_RUN)) && { log_info "[dry-run] would install Claude Code + Codex CLI for $ADMIN_USER"; return 0; }
  ct_exec "$CTID" install -d -m 0700 "$GUEST_DIR"
  pct push "$CTID" "$REPO_DIR/profiles/ai-cli/guest.sh" "$GUEST_DIR/ai-cli.sh" --perms 0700
  guest_run ai-cli.sh "AI_CLI_UPDATE=${AI_CLI_UPDATE:-0}"
  log_ok "AI CLI profile installed (not authenticated)"
}
