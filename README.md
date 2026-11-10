# shared-platform

Shared services for all of my projects, on Oracle Cloud Always Free ($0). Today that's one service:
**a public HashiCorp Vault** at `https://vault.<public-ip-with-dashes>.sslip.io` (`make output STACK=vault-server`).

```
Internet ──443──> Caddy (Let's Encrypt) ──> Vault 127.0.0.1:8200 ──> raft storage, auto-unsealed by OCI KMS
Admin ──OCI Bastion──> SSH (port 22 is never open to the internet)
```

| Stack | What |
|---|---|
| [`stacks/oci-foundation/`](stacks/oci-foundation/) | The OpenTofu state bucket every stack uses and the tenancy's $1 budget with its alerts (taken over from QuantumOps' `oci.sh`). Laptop-only |
| [`stacks/vault-server/`](stacks/vault-server/) | Compartment `platform`, VCN, `VM.Standard.E2.1.Micro` (Always Free), reserved IP (its [sslip.io](https://sslip.io) name needs no domain), KMS unseal key, snapshot bucket, Bastion |
| [`stacks/vault-config/`](stacks/vault-config/) | Vault as code: KV store, audit log, rate limits, admin login with TOTP MFA, GitHub Actions / Kubernetes / AppRole auth, one project per [`projects/*.yaml`](projects/), the platform's own CI roles |
| [`stacks/github/`](stacks/github/) | Branch protection for this repo and the `VAULT_ADDR` Actions variable |

Everything runs through `make` (`make help`). OpenTofu state, this repo's and QuantumOps', lives in one versioned OCI
bucket that `oci-foundation` owns; each stack encrypts its own state.

It also holds the **building blocks every project's CI uses**. Projects reference them at `main`, with no
version tags; each change is tested in this repo before it merges ([docs/contract.md](docs/contract.md)):

| Folder | What |
|---|---|
| [`.github/workflows/`](.github/workflows/) | Reusable workflows: `tofu-stack.yml` (plan with a PR comment, guarded apply, drift issue, outage tolerance), `security.yml` (gitleaks, actionlint, shellcheck, trivy), `gha-telemetry.yml` (CI runs as traces) |
| [`.github/actions/`](.github/actions/) | `vault-env` (OIDC login to the shared Vault, masked env vars), `setup-tools` (pinned OpenTofu, Terraform, TFLint, actionlint) |
| [`modules/`](modules/) | OpenTofu modules for projects: `secrets-vault` (a project's KV secrets as one map) |
| [`tools/`](tools/) | The scripts those workflows run, with tests ([tools/README.md](tools/README.md)) |
| [`examples/consumer/`](examples/consumer/) | A minimal project stack that `building-blocks.yml` runs the reusable workflows against |

Where this is going: [docs/ROADMAP.md](docs/ROADMAP.md).

## Using Vault from a project
1. **Declare it:** add `projects/<project>.yaml` (its repo, login roles, shared credentials, and the secret keys
   it needs) in a PR. After the merge, the vault-config stack creates its policies and roles.
2. **Fill its secrets:** `make vault-seed PROJECT=<project>` asks for each missing key, or takes it from a
   SOPS file or env files. It never prints a value.
3. **Connect the client:** in GitHub Actions, the `vault-env` action or `tofu-stack.yml`'s `vault-role` input.
   The onboarding runbook also has Kubernetes (External Secrets) and AppRole.

Format and examples: [docs/runbooks/onboard-project.md](docs/runbooks/onboard-project.md). GitHub access goes
through GitHub Apps, not personal tokens: [docs/runbooks/github-apps.md](docs/runbooks/github-apps.md).

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
- **Changes go through PRs** with green CI (`make check`, `make lint` and `make test-tools` locally).
- **Projects follow `main`.** Keep every change backward compatible, or move the projects first
  ([docs/contract.md](docs/contract.md)).
