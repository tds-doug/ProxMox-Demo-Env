# AI CLI profile (`ai-cli`)

Installs, for the admin user only, from the vendors' official installers:

| Tool | Installer | Notes |
|---|---|---|
| Claude Code | `curl -fsSL https://claude.ai/install.sh \| bash` | native binary in `~/.local/bin`, self-updating; no Node needed |
| OpenAI Codex CLI | `curl -fsSL https://chatgpt.com/codex/install.sh \| sh` | standalone binary; no Node needed |

PATH is set for login shells via `/etc/profile.d/demo-ai-cli.sh` (install directories are detected, not assumed). Nothing is authenticated, no plugins/MCP servers are added, no background services are created.

Piping a vendor installer to a shell trusts those vendors and their TLS endpoints; the installs run as the unprivileged admin user, not root. Pin versions by editing `profiles/ai-cli/guest.sh` (e.g. `bash -s 2.1.89` for Claude Code) if you need repeatability.

## First login (administrator, over SSH)

**Claude Code** - run `claude`. On a headless host it shows a URL: open it in a browser on your own machine, sign in, and paste the returned code into the terminal. Requires a Pro/Max/Team/Enterprise or Console account. `claude doctor` checks the install.

**Codex** - run `codex login --device-auth` (headless device-code login with your ChatGPT account), then `codex`. If `--device-auth` is not available in your version, check `codex login --help`; alternatively run `codex`, choose *Sign in with ChatGPT*, and use the SSH port-forward method the CLI describes. Official docs: https://developers.openai.com/codex/cli/ (not reachable from the build environment, so these flags are from the project README and **not yet tested here**).

## Updating

```bash
claude update                         # as the admin user (native install also auto-updates)
sudo AI_CLI_UPDATE=1 ./deploy.sh --ctid 201 profile ai-cli     # on the PVE host: re-runs both installers
```

## Resources

The container has 4096 MB; Claude Code's docs list 4 GB+ RAM as a requirement. Measured so far (real services on Ubuntu 24.04, outside LXC, indicative only): Apache ≈ 119 MB (summed RSS, overcounts shared pages), MariaDB ≈ 104 MB, sshd 3 MB, so roughly 250 MB idle before the CLIs. **CLI memory use was not measured** (needs authenticated sessions in a live container). Running both CLIs at once with large repositories may be tight; if `free -m` shows swap use, raise `CT_MEMORY` (e.g. 8192) and `configure`/`pct set 201 --memory 8192`. Prefer one tool at a time on the default size. Stop MariaDB (`sudo systemctl stop mariadb`) if you need the headroom and don't use the demo DB.

## Known compatibility question

Codex's Linux command sandbox (bubblewrap/Landlock) may not work inside an *unprivileged, non-nested* LXC. If it errors, either run Codex with its sandbox disabled/`danger-full-access` (the container is already the isolation boundary), or deploy with `CT_NESTING=1`. Not yet tested.

## Clean baseline (remove credentials/session data)

```bash
sudo ./deploy.sh --ctid 201 clean-ai-credentials      # removes ~/.claude*, ~/.codex/auth.json, history, sessions, bash_history
```

Binaries stay. Before snapshotting/backing up/distributing, run this; better, rebuild from scripts and never log in on the baseline. Note the admin password hash in `/etc/shadow` and SSH host keys remain in any snapshot. Revoke sessions in the Claude and ChatGPT account settings if a logged-in container is discarded.
