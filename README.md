# shared-platform

Shared services for all of my projects, on Oracle Cloud Always Free ($0). Today that's one service:
**a public HashiCorp Vault** at `https://<vault_hostname>`.

```
Internet ──443──> Caddy (Let's Encrypt) ──> Vault 127.0.0.1:8200 ──> raft storage, auto-unsealed by OCI KMS
Admin ──OCI Bastion──> SSH (port 22 is never open to the internet)
```

| Stack | What |
|---|---|
| [`vault-server/`](vault-server/) | Compartment `platform`, VCN, `VM.Standard.E2.1.Micro` (Always Free), reserved IP, Cloudflare DNS record, KMS unseal key, snapshot bucket, Bastion |
| [`vault-config/`](vault-config/) | Vault as code: KV store, audit log, rate limits, admin login with TOTP MFA, GitHub Actions / Kubernetes / AppRole auth, [one module call per project](vault-config/projects.tf) |
| [`github/`](github/) | Branch protection for this repo and the `VAULT_ADDR` Actions variable |

Everything runs through `make` (`make help`). OpenTofu state is in the same encrypted OCI bucket as QuantumOps.

## Using Vault from a project
1. Add a `module "<project>"` block to [`vault-config/projects.tf`](vault-config/projects.tf), open a PR, merge,
   then `make plan STACK=vault-config` and `make apply STACK=vault-config`.
2. Put secrets under `kv/<project>/...`, in the UI or with `vault kv put kv/<project>/name key=value`.
3. Connect the client. There are examples for Kubernetes (External Secrets), GitHub Actions and AppRole in
   [docs/runbooks/onboard-project.md](docs/runbooks/onboard-project.md).

Machines never use passwords: Kubernetes and GitHub Actions log in with short-lived JWTs, VMs with AppRole.

## Runbooks
- [First setup](docs/runbooks/setup.md): from nothing to a public, initialized, MFA-protected Vault.
- [Operations](docs/runbooks/operations.md): Bastion SSH, reboot and auto-unseal, snapshots and restore,
  upgrades, idle reclaim, rotating credentials.
- [Onboarding a project](docs/runbooks/onboard-project.md).

## Rules
- **$0:** Always Free shapes only (the code refuses others). Ask before anything that costs money.
- **No secrets in Git.** Local credentials live in `~/.config/platform/` and `~/.config/qops/` (0600); state is
  encrypted.
- **Changes go through PRs** with green CI (`make check` and `make lint` locally).
