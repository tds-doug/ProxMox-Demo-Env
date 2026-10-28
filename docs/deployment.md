# Deployment guide

## Normal deployment

```bash
sudo ./deploy.sh check      # PVE version, config, storage, bridge
sudo ./deploy.sh plan       # shows every step; creates nothing
sudo ./deploy.sh deploy     # hidden password prompt (12+ chars, confirmed); or: --password-stdin
```

Automation (password from a protected source, never an argument): `sudo ./deploy.sh --password-stdin deploy < <(pass show lab/demoadmin)`.

Output ends with the container IP, SSH/web URLs and the verification result. Everything is also logged to `/var/log/proxmox-demo-factory.log` (override with `LOG_FILE=`); the log never contains passwords.

## Resuming / re-running safely

If a stage fails, the container is left running. Fix the cause (see [troubleshooting](troubleshooting.md)) and run:

```bash
sudo ./deploy.sh --ctid 201 configure        # re-applies base + hardening + profile; no data loss, no password reset
sudo ./deploy.sh --ctid 201 profile ai-cli   # just the profile
AI_CLI_UPDATE=1 sudo -E ./deploy.sh --ctid 201 profile ai-cli   # refresh the CLIs
```

If the admin user was never created (failure before that stage), `configure` prompts for the password then.

## Rebuilding

```bash
pct stop 201 && pct destroy 201 --purge     # your decision; the factory never destroys
sudo ./deploy.sh deploy
```

Snapshots/backups are conveniences, not the rebuild mechanism. `./deploy.sh snapshot` (or `SNAPSHOT_AFTER_DEPLOY=1`) works only on snapshot-capable storage (ZFS, LVM-thin, btrfs, Ceph); on `dir`/LVM-thick use `vzdump`. Run `clean-ai-credentials` first: a snapshot taken after login would capture tokens, and always contains the admin password hash.

## Live acceptance test

Not yet performed. On a PVE 9 host:

```bash
sudo ./deploy.sh plan && sudo ./deploy.sh --profile ai-cli deploy
sudo ./deploy.sh --ctid 201 verify --test-login --reboot     # expect: 0 failed
ssh demoadmin@<ip>; curl http://<ip>/ ; curl http://<ip>/demo/db-test.php
ssh root@<ip>                                                  # must be refused
ssh demoadmin@<ip> 'free -m; claude --version; codex --version'
# memory: idle, then with claude and codex sessions open
pct exec 201 -- free -m ; pct exec 201 -- ps -eo rss,comm --sort=-rss | head
```

Also check: `pct config 201` (unprivileged: 1, 2 cores, 4096 MB, 1024 swap, 40G), firewall enforcement from another LAN host (`nmap -p 22,80,443,3306 <ip>`: 3306 closed/filtered), and an interactive `claude` and `codex` login.
