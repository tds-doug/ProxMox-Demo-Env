# Architecture

```
deploy.sh                    CLI, config loading, flows (deploy / configure / profile / verify / ...)
lib/common.sh                logging, stages + exit codes, config parser, validators, password prompt
scripts/create-container.sh  HOST: preflight, storage pick, template via pveam, pct create/start, DHCP wait
scripts/configure-base.sh    HOST: admin user, push+run guest scripts, Proxmox firewall file
scripts/verify-container.sh  HOST: config/firewall checks, runs guest verify, SSH login test, reboot test
scripts/clean-credentials.sh HOST: remove saved Claude/Codex logins
guest/base.sh harden.sh verify.sh   run INSIDE the container as root via `pct exec` (pushed to /opt/demo-factory, 0700)
profiles/<name>/install.sh   HOST hook: defines profile_install
profiles/<name>/guest.sh     INSIDE the container
```

Host-side scripts never run application logic; guest scripts never see passwords. Non-secret settings travel as `env VAR=...` arguments to `pct exec`; the admin password travels only on `chpasswd`'s stdin.

## Flow and failure classes

`deploy`: preflight → storage → template → create → start → network → admin-user → packages → hardening → firewall → profile → verify. Each stage sets an exit code: 2 validation, 3 create/template, 4 start, 5 network, 6 guest config, 7 packages, 8 profile, 9 verify. On failure the container is **never** removed; the message names the stage and the resume command (`configure`).

## Idempotency rules

- `deploy` refuses an existing CTID; only `configure`/`profile`/`verify` act on existing containers (and require unprivileged).
- User creation only if absent; password only set at creation.
- Config files the factory owns are rewritten wholesale (sshd drop-in `00-demo-factory.conf`, Apache `zz-demo-hardening.conf`, MariaDB `99-demo-factory.cnf`, `/etc/pve/firewall/<id>.fw` with a marker; a firewall file without the marker is left untouched).
- Demo DB created once; existing data/credentials untouched.
- Installers skipped when the CLI is already on PATH (`AI_CLI_UPDATE=1` forces a refresh).

## Decisions made

- Rules are written as `/etc/pve/firewall/<CTID>.fw` (declarative, diffable, idempotent) rather than `pvesh create` calls, which duplicate rules on re-run.
- `Include`-order: sshd uses first-match, so the SSH drop-in is `00-`; Apache uses last-match, so hardening is `zz-`. Both were found/verified by running the scripts.
- No Docker/Node/Python tooling on the host side beyond Bash and coreutils.

## Adding a profile

1. `profiles/foo/guest.sh`: runs as root in the container; read `ADMIN_USER`; idempotent; `touch /etc/demo-factory/profiles/foo`.
2. `profiles/foo/install.sh`: `profile_install() { stage "profile:foo" "$EX_PROFILE"; pct push "$CTID" "$REPO_DIR/profiles/foo/guest.sh" "$GUEST_DIR/foo.sh" --perms 0700; guest_run foo.sh; }`
3. `./deploy.sh --ctid N profile foo`. Add checks to `guest/verify.sh` if wanted.
