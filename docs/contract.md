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
   - The downstream check runs each project's own CI and plan against the PR, and blocks the merge when one
     fails (below).
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
| `tofu-stack.yml` | `dir`, `mode` (plan / apply / drift), `vault-role`, `vault-secrets`, `github-app`, `guard-allow`, `guard-protect`, `pre-plan`, `post-apply`, `post-drift`, `allow-outage`, `platform-ref`. Hooks get `PLAN_JSON`, `GH_TOKEN` and the Vault values. Outputs: `exitcode` (0, 2 or skip) and `summary` (the plan's counts) | `contents: read`, `id-token: write`, `actions: read`, plus `pull-requests: write` (plan) or `issues: write` (drift) |
| `security.yml` | `shellcheck` (globs), `gitleaks-config`, `trivy-dir` | `contents: read` |
| `gha-telemetry.yml` | `workflows`, `vault-role`, `vault-secrets` | `contents: read`, `actions: read`, `id-token: write` |
| `vault-env` action | `addr` (`vars.VAULT_ADDR`), `role`, `secrets`, `export-token` | `id-token: write` |
| `setup-tools` action | `tofu-version`, `terraform-version`, `tflint-version`, `actionlint` | nothing |
| `modules/secrets-vault` | `paths` (KV names) → `values` (sensitive map) | a configured `vault` provider (`VAULT_ADDR`, `VAULT_TOKEN` from `vault-env` with `export-token`) |

## The downstream check
Every shared-platform PR is tested against each project before it can merge. A project takes part by
declaring a receiver in its `projects/<name>.yaml`:
```yaml
downstream:
  workflow: platform-check.yml        # in the project's repo, on its default branch
  apply:                              # optional: started after a merge that changes the project's plan
    workflow: infra.yml
    inputs: { apply: "true" }
```
The receiver ([this repo's own](../.github/workflows/platform-check.yml) is the example):
- **Trigger:** `workflow_dispatch` with the inputs `platform_ref` (the commit to test) and `request_id`.
- **`run-name`** must contain `${{ inputs.request_id }}`: that is how the platform finds the run.
- **What it runs:** the project's CI and a `tofu-stack.yml` plan of each stack, all with
  `platform-ref: ${{ inputs.platform_ref }}`. It must change nothing: plan, never apply.
- **Result:** the run's conclusion. Success lets the platform PR merge; anything else blocks it.
- **Optional report:** an artifact named `platform-check` holding `result.json`,
  `{"stacks": [{"name": "infra", "exitcode": "<tofu-stack exitcode>", "summary": "<tofu-stack summary>"}]}`.
  The PR comment shows it, and an `exitcode` of `2` is what starts `downstream.apply` after the merge.

It needs no credential for shared-platform: `platform-bot` starts the run and reads its result. Until the
receiver file exists on the project's default branch, the check lists the project as "no receiver yet" and
doesn't block.

## The GitHub baseline
A project with `github: { baseline: true }` gets, from the platform's `github` stack:
- **The `platform-baseline` ruleset** on its default branch: changes come through pull requests (no review
  needed), and the branch can't be deleted or force-pushed. Required checks stay in the project's own rule.
- **A read-only default Actions token.** A job that writes (a PR comment, an issue) asks for it in
  `permissions:`.
- **Only listed actions run:** GitHub's own (`actions/*`), this account's, the ones the building blocks use,
  and what the project lists in `github.allowed_actions` (`owner/*` or `owner/repo@*`). Add an action there,
  in a shared-platform PR, before a workflow uses it.
- **Secret scanning with push protection,** and the `VAULT_ADDR` Actions variable.

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
