# Troubleshooting

Logs: `/var/log/proxmox-demo-factory.log` (host), `pct enter <id>` for the guest. Exit codes: 2 validation, 3 create, 4 start, 5 network, 6 guest config, 7 packages, 8 profile, 9 verify.

| Symptom | Cause / fix |
|---|---|
| `Proxmox VE 9.x required` | Run on PVE 9, or `ALLOW_OTHER_PVE=1` (untested). |
| Template missing / download fails | `pveam update; pveam available --section system \| grep ubuntu-24`. Host needs `download.proxmox.com`. Pick another `TEMPLATE_STORAGE` (`./deploy.sh storage`). |
| `Storage 'x' is missing, inactive, or does not allow content` | In the GUI: Datacenter > Storage > edit > Content must include *Disk image/Container* (`rootdir`) or *Container template* (`vztmpl`). |
| Snapshot fails | Storage type lacks snapshots (dir, LVM-thick). Use `vzdump` or just rebuild. |
| No IPv4 address (exit 5) | No DHCP on `BRIDGE`/`VLAN_TAG`; wrong bridge; or the Proxmox firewall dropping DHCP (rules set `dhcp: 1`; check `/etc/pve/firewall/<id>.fw`). `pct exec <id> -- ip -4 a`. Use static mode as a workaround. |
| DNS/outbound failure | `pct exec <id> -- getent hosts archive.ubuntu.com`; check gateway/DNS, proxy requirements, datacenter egress rules. |
| SSH "Permission denied" | Wrong password; user not in `AllowUsers`; check `pct exec <id> -- sshd -T -C user=<u>,host=x,addr=1.1.1.1 \| grep -E 'allowusers\|passwordauth'`; `journalctl -u ssh`. Reset from the host: `pct enter <id>` then `passwd <user>`. |
| SSH connection timeout | Firewall: `SSH_MGMT_SUBNET` excludes your client; or firewall rules not matching. Verify with `./deploy.sh verify`. |
| `verify --test-login` fails but you can log in | The Proxmox host is outside `SSH_MGMT_SUBNET`. |
| `apt` errors (exit 7) | Mirror/DNS/proxy; `pct exec <id> -- apt-get update`; re-run `configure` (idempotent). |
| Apache/MariaDB won't start, `status=226/NAMESPACE`, "Failed to set up mount namespace" | systemd sandboxing needs more than a non-nested unprivileged LXC allows. Set `CT_NESTING=1`, `pct set <id> --features nesting=1`, reboot the CT, re-run `configure`. (Unverified live.) Otherwise `journalctl -u apache2 -u mariadb -n 50`. |
| Apache: `AH00558` ServerName warning | Harmless; the factory sets a global `ServerName`. |
| `claude: command not found` | Use a **login** shell (`ssh user@host`, not `ssh host cmd`); `ls ~/.local/bin/claude`; `cat /etc/profile.d/demo-ai-cli.sh`; re-run `profile ai-cli`. |
| `codex: command not found` | `find ~ -name codex -type f`; re-run `profile ai-cli` (it records the install directory). The Codex installer needs `chatgpt.com` (falls back to GitHub releases). |
| Login URL/code on a headless box | See [ai-cli.md](ai-cli.md). Use your own browser; for Codex prefer `--device-auth`. |
| Memory exhaustion / OOM | `free -m`, `ps -eo rss,comm --sort=-rss \| head`; stop MariaDB if unused; one CLI at a time; raise `CT_MEMORY` and `pct set <id> --memory N`. |
| Firewall warning "NOT enforced" | Enable Datacenter > Firewall > Options > Firewall (ensure host access rules first), and `systemctl enable --now pve-firewall`. |
