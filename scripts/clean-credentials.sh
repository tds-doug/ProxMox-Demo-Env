#!/usr/bin/env bash
# scripts/clean-credentials.sh - host side. Removes saved Claude/Codex logins and local
# session data from a container so it can be snapshotted/backed up/handed over clean.
# Sourced by deploy.sh (command: clean-ai-credentials). Never touches the CLI binaries.
# shellcheck shell=bash

clean_ai_credentials() {
  ct_exists "$CTID" || die "$EX_VALIDATION" "Container $CTID does not exist."
  ct_running "$CTID" || die "$EX_VALIDATION" "Container $CTID must be running."
  if ! ((ASSUME_YES)) && ! ((DRY_RUN)); then
    local ans
    read -r -p "Delete saved Claude/Codex logins, history and sessions for '$ADMIN_USER' in CT $CTID? [y/N] " ans
    [[ $ans =~ ^[Yy]$ ]] || { log_info "Aborted."; return 0; }
  fi
  # shellcheck disable=SC2016  # $HOME must expand in the guest, not here
  run pct exec "$CTID" -- runuser -l "$ADMIN_USER" -c '
    set -e
    rm -rf  "$HOME/.claude" "$HOME/.config/claude" "$HOME/.cache/claude"
    rm -f   "$HOME/.claude.json" "$HOME/.claude.json.backup"
    rm -f   "$HOME/.codex/auth.json" "$HOME/.codex/history.jsonl"
    rm -rf  "$HOME/.codex/sessions" "$HOME/.codex/log" "$HOME/.codex/tmp"
    rm -f   "$HOME/.bash_history"
    echo cleaned'
  log_ok "Saved AI CLI credentials and session data removed (binaries kept)."
  log_warn "Also: /etc/shadow still holds the admin password hash, and SSH host keys persist."
  log_warn "Rebuild from scripts for a distributable baseline rather than cloning this container."
}
