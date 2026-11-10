# What a project can rely on

Projects use this repo's building blocks **at `main`**, never at a tag:

```yaml
uses: michael-attias123/shared-platform/.github/workflows/tofu-stack.yml@main
```
```hcl
source = "git::https://github.com/michael-attias123/shared-platform.git//modules/secrets-vault?ref=main"
```

So `main` must never break a project. That is this repo's side of the deal:

1. **Backward compatible.** Inputs, outputs, Vault paths and tool arguments only get added. To change or
   remove one: add the new form, move every project to it, then remove the old one in a later PR.
2. **Tested before merge.**
   - `building-blocks.yml` runs the reusable workflows and actions at the PR's commit against
     [`examples/consumer`](../examples/consumer).
   - `make check` and `make test-tools` cover the modules and tools.
   - The downstream check runs each project's own plan against the PR (see the roadmap, SP4).
3. **A bad merge is fixed by a revert on `main`.** Every project picks the fix up on its next run.

## Trying a platform branch from a project
- **Modules:** `tofu-stack.yml` takes `platform-ref`. Set it from an Actions variable (e.g.
  `platform-ref: ${{ vars.PLATFORM_REF || 'main' }}`) and set `PLATFORM_REF` to a branch in a draft PR. The
  stack's `?ref=main` sources are rewritten in the runner's checkout only (`tools/platform_ref.sh`); nothing is
  committed. That makes `ref=main` in the sources a literal, so the code stays valid Terraform too.
- **Reusable workflows:** a `uses:` line can't take a variable. To try a workflow change, open the
  shared-platform PR: `building-blocks.yml` runs it there.

## The building blocks
| Block | Inputs that matter | The caller's job needs |
|---|---|---|
| `tofu-stack.yml` | `dir`, `mode` (plan / apply / drift), `vault-role`, `vault-secrets`, `guard-allow`, `guard-protect`, `pre-plan`, `post-apply`, `allow-outage`, `platform-ref` | `contents: read`, `id-token: write`, `actions: read`, plus `pull-requests: write` (plan) or `issues: write` (drift) |
| `security.yml` | `shellcheck` (globs), `gitleaks-config`, `trivy-dir` | `contents: read` |
| `gha-telemetry.yml` | `workflows`, `vault-role`, `vault-secrets` | `contents: read`, `actions: read`, `id-token: write` |
| `vault-env` action | `addr` (`vars.VAULT_ADDR`), `role`, `secrets`, `export-token` | `id-token: write` |
| `setup-tools` action | `tofu-version`, `terraform-version`, `tflint-version`, `actionlint` | nothing |
| `modules/secrets-vault` | `paths` (KV names) → `values` (sensitive map) | a configured `vault` provider (`VAULT_ADDR`, `VAULT_TOKEN` from `vault-env` with `export-token`) |

## Vault, from a project's side
- **Login:** a job logs in as `<project>-<owner>-<repo>` with its OIDC token, audience `vault`. No stored
  secret. The roles come from the project's declaration in this repo.
- **Paths:**
  - `kv/<project>/*`: the project's own secrets, written by the owner.
  - `kv/<project>/platform/*`: credentials and facts the platform mints for it (from SP3/SP5 on).
- **Changes:** a value changed in Vault reaches a stack on its next plan. Scheduled jobs read it on their next run.

## What a project must not do
- Pin a building block to a tag or SHA, except temporarily through `platform-ref` while a fix is on the way.
- Read another repo's state.
- Write outside `kv/<project>/`.
