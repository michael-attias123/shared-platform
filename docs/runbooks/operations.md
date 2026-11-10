# Operations

## Shell on the VM (OCI Bastion)
`make vault-ssh` opens a 3-hour Bastion session and SSHes through it with `~/.ssh/qops_oci`; it reuses the
session while it's alive.

**Company network blocks outbound SSH (port 22)?** Use **OCI Cloud Shell** (console, top right `>_`). It runs in
Oracle's network:
1. In the console: *Identity & Security → Bastion → platformbastion → Create session* (port forwarding, target
   `vault-1`, port 22, upload `qops_oci.pub`).
2. Copy the session's SSH command into Cloud Shell, using your private key there (upload it for the session,
   delete it after).

## Reboots and auto-unseal
Vault unseals itself through OCI KMS (instance principal). After a reboot: `make vault-health` shows
`sealed: false` within about 1–2 minutes. If it stays sealed:
1. `make vault-ssh`, then `sudo journalctl -u vault -n 50`. Look for `ocikms` errors: is the policy
   `platform-vault` intact, and the key enabled?
2. Check `sudo systemctl status caddy` for certificate problems.

## Snapshots and restore
A daily timer (~02:30 UTC) uploads `vault-<timestamp>.snap` to the `vault-snapshots` bucket. Objects are kept 30
days. Check the last run with `make vault-ssh`, then `systemctl list-timers vault-snapshot.timer` and
`journalctl -u vault-snapshot -n 5`.

**Restore** (onto the same or a rebuilt VM; needs the same KMS key, since snapshots are encrypted by Vault's
barrier):
1. Download the snapshot: OCI console → bucket → object → *Download*. Copy it to the VM with `scp` through
   Bastion, or download it on the VM with `/opt/oci-cli/bin/oci os object get --auth instance_principal ...`.
2. On the VM:
   ```bash
   VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=<admin or new root token> vault operator raft snapshot restore -force file.snap
   ```
3. Check with `make vault-health`, then log in.

A rebuilt VM starts uninitialized. Initialize it (`make vault-init`, new keys), then restore the snapshot: data,
policies and users come back, including the old recovery configuration.

## Upgrades
- **OS:** unattended security upgrades run daily.
- **Vault** is pinned (`vault_version` in `stacks/vault-server/variables.tf`, and `apt-mark hold` on the VM). To upgrade:
  1. `make vault-ssh`.
  2. `sudo apt-mark unhold vault && sudo apt-get install vault=<new>-1 && sudo apt-mark hold vault && sudo systemctl restart vault`.
  3. Bump `vault_version` in a PR so new VMs match.
- **Caddy** upgrades with the OS packages.

## Idle reclaim
Oracle may **stop** (not delete) Always Free VMs that stay almost idle for 7 days. Symptom: `make vault-health`
times out and the console shows `vault-1` *Stopped*. Fix: *Start* it in the console. Vault unseals itself.

## Rotating credentials
| What | How |
|---|---|
| Admin password | `make vault-admin` (as admin) |
| Admin TOTP | `vault write identity/mfa/method/totp/admin-destroy method_id=... entity_id=...`, then `make vault-mfa-enroll` |
| AppRole secret ID | `make vault-approle-secret PROJECT=<name>` (valid 90 days) |
| Lost root/admin | `vault operator generate-root` with 3 of the 5 recovery keys |

## The sslip.io name
`vault.<a-b-c-d>.sslip.io` resolves through the public sslip.io DNS service. If sslip.io were ever down, names
couldn't resolve. Clients can pin the IP (`/etc/hosts`, or `--resolve` in curl) until it's back. Moving to your own
domain later is one change: point a DNS A record at the reserved IP, put the name in the Caddyfile and `api_addr`
on the VM, and update `VAULT_ADDR` in clients.
