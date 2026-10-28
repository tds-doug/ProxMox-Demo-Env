# Security notes

## Threat model

Trusted internal LAN or VPN; not internet-facing; demo data only. Hardening is "reasonable and administrable", not compliance-grade.

## Controls implemented

| Control | How |
|---|---|
| Unprivileged LXC, no nesting, no extra caps | `--unprivileged 1`, no `--features` (verified by `verify`) |
| No root password / root SSH | no `--password` on create; `PermitRootLogin no`; use `pct enter` |
| Admin account | non-root, bash, sudo group, **sudo asks for a password** (no NOPASSWD, checked) |
| SSH | drop-in `00-demo-factory.conf` (first-match wins over cloud-init's 50-): password auth on, empty passwords off, `MaxAuthTries 4`, `LoginGraceTime 30`, `AllowUsers <admin>`, no X11/agent forwarding, Ubuntu's modern default crypto; pubkey optional and additive |
| Apache | `ServerTokens Prod`, `ServerSignature Off`, `TraceEnable Off`, `-Indexes`, autoindex module disabled, `expose_php=Off`, basic headers; no WAF, no CGI, no forced HTTPS/HSTS |
| MariaDB | `bind-address=127.0.0.1`, no anonymous users, no remote root, `test` DB dropped, `local-infile=0`; app account has only DML on `demo.*`, random password (0640 root:www-data) |
| Updates | `unattended-upgrades`, security pocket, never auto-reboots |
| Firewall | `/etc/pve/firewall/<id>.fw`: policy_in DROP; allow ping, TCP/80, TCP/22 (optionally only from `SSH_MGMT_SUBNET`), TCP/443 only if HTTPS enabled |
| Secrets | none in repo/config/logs/argv; password only via stdin; SSH test uses a FIFO askpass (no file, no env, no argv) |

## Proxmox firewall: is it actually enforced?

Per-container rules do nothing unless **all** hold: Datacenter firewall enabled (`/etc/pve/firewall/cluster.fw` `[OPTIONS] enable: 1`), the firewall service is running (`pve-firewall`, or `proxmox-firewall` if the node uses the nftables backend: `nftables: 1` in the node's `host.fw`), the container NIC has `firewall=1`, and the container's own firewall is enabled. The factory writes the last two and **checks all four**, printing a WARN with explicit remediation if the host side is off. It never edits datacenter/host firewall settings. If you enable the datacenter firewall, first make sure a rule keeps TCP/8006 and TCP/22 to the host reachable from your admin network.

With `SSH_MGMT_SUBNET` set, the Proxmox host must be in that subnet for `verify --test-login` to work.

## Deliberately not installed

- **sysctl hardening**: most `net.*`/`kernel.*` keys are host-owned or read-only in an unprivileged container; the original script's `99-harden.conf` would error or be ineffective. Set on the Proxmox host if desired.
- **UFW**: duplicates the Proxmox firewall; two policies are a debugging hazard.
- **fail2ban**: its ban actions need netfilter, which unprivileged LXC does not provide, and it adds a daemon; `MaxAuthTries`, the 30 s grace time and the management-subnet restriction are the compensating controls. Consider on the *host* firewall instead.
- **auditd, ModSecurity/CRS, ModEvasive**: unneeded weight/false positives for a demo box; auditd is also kernel-bound.

## Accepted risks

1. **SSH password authentication is on, by requirement.** Brute-force exposure is limited by LAN/VPN placement, `AllowUsers`, `MaxAuthTries`, and the optional subnet restriction. Use a long unique password. Adding a key does not disable passwords.
2. Plain HTTP by default; HTTPS is optional and self-signed.
3. PHP and Apache run as `www-data` with a DB account that can modify demo data.
4. AI CLIs run with the admin user's privileges (and sudo with the password). Tokens saved after login live in the user's home (`~/.claude`, `~/.codex`); anyone with root on the Proxmox host can read them.
5. Unattended upgrades mean package changes between rebuilds.
6. Unverified live: behaviour of systemd sandboxing in unprivileged LXC (see troubleshooting).

## How the original scripts' credential problem was fixed

`harden-ubuntu-web.sh` generated a random admin password, printed it, and appended `ADMIN CREDENTIALS user=... password=...` to `/var/log/harden-ubuntu-web.log`; the deploy script also took `CT_PASSWORD` as a plaintext variable passed to `pct create --password`. Both were removed: the guest scripts never handle passwords, `pct create` is called without `--password`, and the password is read with hidden input, sent through stdin to `chpasswd`, held only in a shell variable, and cleared after use. The test suite asserts the password is absent from `pct` argv, the log file, console output, and any file other than the consumed stdin.
