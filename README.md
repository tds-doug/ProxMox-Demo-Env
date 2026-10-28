# Proxmox Demo Environment Factory

Tiny Dragon Solutions. Rebuild-from-scripts provisioning of Ubuntu 24.04 LXC demo containers on **Proxmox VE 9.x**, using only Bash, `pct`/`pvesm`/`pveam` and Ubuntu packages (no Ansible, Terraform, Docker, or extra servers).

One command gives you an unprivileged container with **2 vCPU / 4 GB RAM (1 GB swap) / 40 GB disk**, DHCP networking, Apache, MariaDB, Python 3, PHP, Perl, password-based SSH for a non-root admin, practical hardening, and (profile `ai-cli`) **Claude Code** and **OpenAI Codex CLI** ready for interactive login.

> **Status:** the host-side flow is tested against mocked Proxmox tools, and the guest-side scripts were executed on a real Ubuntu 24.04 system (no systemd, no LXC). **No live Proxmox VE 9 deployment has been performed yet.** See [Verification status](#verification-status) and the [live acceptance test](docs/deployment.md#live-acceptance-test).

## Prerequisites

- Proxmox VE 9.x host, run as `root`, with `pct pvesm pveam pvesh` (all present by default) and an `ssh` client.
- A bridge (default `vmbr0`) on a network with a DHCP server (or use static settings).
- Storage that supports `rootdir` (container disks) and `vztmpl` (templates): `./deploy.sh storage`.
- Outbound access from the container: `archive.ubuntu.com`/`security.ubuntu.com` (80/443), and for `ai-cli`: `claude.ai`, `downloads.claude.ai`, `api.anthropic.com`, `chatgpt.com`, `auth.openai.com`, `api.openai.com`, `github.com` + `releases.openai.com` (installer fallback). Outbound from the host: `download.proxmox.com` (template catalogue). Working DNS is required.
- Trusted LAN or VPN only. These systems are **not** designed for internet exposure ([docs/security.md](docs/security.md)).

## Quick start

```bash
git clone https://github.com/tds-doug/ProxMox-Demo-Env.git && cd ProxMox-Demo-Env
cp config/demo.env.example config/demo.env && nano config/demo.env   # CTID, hostname, storage, admin user...
sudo ./deploy.sh storage          # what storage can I use?
sudo ./deploy.sh plan             # dry run; changes nothing
sudo ./deploy.sh deploy           # prompts (hidden) for the admin password, ~5-10 min
```

Equivalent one-liners with flags instead of a config file:

```bash
sudo ./deploy.sh --profile base   --ctid 210 --hostname demo-base-01 deploy
sudo ./deploy.sh --profile ai-cli --ctid 201 --storage local-lvm --mgmt-subnet 192.168.1.0/24 deploy
sudo ./deploy.sh --ctid 210 profile ai-cli    # add the AI CLIs to an existing base container
sudo ./deploy.sh --ctid 201 verify --test-login   # re-run all checks (+ real SSH password login)
```

Commands: `deploy configure profile verify plan check config storage snapshot clean-ai-credentials help`. Options: `./deploy.sh help`.

## Configuration

`config/defaults.env` holds defaults; `config/demo.env` (git-ignored, copy from `demo.env.example`) overrides it; command-line flags override both. Files are **parsed, not executed**, and unknown keys, `$`, backticks, `;`, `|`, `&` are rejected. **Never put a password in a config file** - the password is prompted for (or `--password-stdin`).

| Key | Default | Notes |
|---|---|---|
| `CTID`, `CT_HOSTNAME` | 201, `demo-ai-01` | |
| `CT_CORES` / `CT_MEMORY` / `CT_SWAP` / `CT_DISK` | 2 / 4096 / 1024 / 40 | MB, MB, GB |
| `NETWORK_MODE` | `dhcp` | `static` + `STATIC_IP/PREFIX/GATEWAY/DNS` |
| `BRIDGE`, `VLAN_TAG` | `vmbr0`, empty | |
| `STORAGE`, `TEMPLATE_STORAGE` | `auto` | `auto` prefers `local-lvm`/`local-zfs`/`local`, else first valid |
| `ADMIN_USER` | `demoadmin` | non-root; sudo with password |
| `SSH_MGMT_SUBNET` | empty | restrict TCP/22 in the Proxmox firewall |
| `PROFILE` | `ai-cli` | `base` or `ai-cli` |
| `ENABLE_HTTPS` | 0 | self-signed on 443; no redirect/HSTS |
| `DEMO_DB`, `UNATTENDED_UPGRADES`, `PROXMOX_FIREWALL` | 1 | |
| `CT_NESTING` | 0 | only enable if systemd units fail ([troubleshooting](docs/troubleshooting.md)) |

## What gets installed

Apache 2.4 + PHP (mod_php) with a landing page showing hostname and profile, `demo/php-test.php`, `demo/db-test.php`; MariaDB (localhost only, optional `demo` database with a restricted `demo_app` account whose random password lives only in `/etc/demo-factory/db.cnf`, mode 0640); Python 3 + pip + venv (PEP 668 respected: use venvs); PHP CLI + `php-mysql`; Perl + DBI; OpenSSH server; git, curl, wget, sudo, ca-certificates, iproute2, ping, dig, htop, lsof, jq, unzip, nano.

## SSH access

```bash
ssh demoadmin@<ip>            # password you entered at deploy time; root login is disabled
pct enter 201                 # emergency root console from the Proxmox host (bypasses SSH)
```

Password login stays enabled even if you add `ADMIN_SSH_PUBKEY`. The password is never stored in files or logs and is **not** reset on re-runs. To change it later: `passwd` inside the container, or `pct enter 201` then `passwd demoadmin`.

## AI CLIs (profile `ai-cli`)

Installed for the admin user and **not authenticated**:

```bash
ssh demoadmin@<ip>
claude                        # follow the on-screen login (open the URL on your own browser, paste the code back)
codex login --device-auth     # headless ChatGPT login (or just `codex` and choose "Sign in with ChatGPT")
```

Details, updating, memory guidance and credential cleanup: [docs/ai-cli.md](docs/ai-cli.md).

## Verification

```bash
sudo ./deploy.sh --ctid 201 verify                # config, services, web, PHP, DB, SSH config, CLIs, firewall
sudo ./deploy.sh --ctid 201 verify --test-login   # also a real SSH password login (prompts; password never touches argv/disk)
sudo ./deploy.sh --ctid 201 verify --reboot       # also proves services come back after a restart
```

Exit code 9 if any check fails; warnings (e.g. firewall not enforced on the host) do not fail the run.

## Rebuilding

The repository is the source of truth. To replace a demo: back up anything you need, then destroy it yourself (`pct stop 201 && pct destroy 201` - the factory never destroys containers) and run `deploy` again. To repair or update an existing one without data loss: `sudo ./deploy.sh --ctid 201 configure`. See [docs/deployment.md](docs/deployment.md).

## Adding a profile

Create `profiles/<name>/install.sh` defining `profile_install` (host side: push and run a guest script with `guest_run`) and a guest-side script; use `/etc/demo-factory/profiles/<name>` as the marker. `profiles/ai-cli/` is the template (about 30 lines). Then `./deploy.sh profile <name>` or `--profile <name>`. Details: [docs/architecture.md](docs/architecture.md).

## Tests

```bash
tests/run-tests.sh      # ShellCheck + bash -n + mocked host-flow tests (86 checks)
```

## Verification status

| Area | Status |
|---|---|
| ShellCheck / `bash -n` | passed |
| Config parsing, validation, refusal of occupied CTID, plan mode, idempotent rerun, firewall file generation, password never in argv/log/stdout (mocked `pct`) | passed |
| Guest scripts executed on real Ubuntu 24.04 (Apache, MariaDB, PHP, Python venv, Perl, sshd config, hardening; run twice) | passed (systemd replaced by a shim) |
| Live Proxmox VE 9 deployment, unprivileged-LXC behaviour (systemd sandboxing, DHCP), `pct exec` stdin, firewall enforcement | **not yet verified** |
| Actual SSH password login to a deployed container | **not yet verified** |
| Claude Code installation inside the container | **not yet verified** (official installer, not run in an LXC) |
| Codex CLI installation | **not yet verified** (installer host unreachable from the build sandbox) |
| Authenticated Claude/Codex use | **not performed** (by design) |
