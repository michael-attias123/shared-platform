# Roadmap: one platform for every project

shared-platform becomes the single owner of everything that exists once:
- the OCI foundation;
- Vault and its config;
- the Grafana stack's shared parts;
- the GitHub baseline;
- the CI building blocks.

Projects (house-manager, QuantumOps) keep only their own resources and content. They get credentials and facts
through Vault, and use the building blocks at `main` ([contract.md](contract.md)).

## Status
| PR | What | Status |
|---|---|---|
| SP1 | Layout (`stacks/`), tools, actions, reusable workflows, `modules/secrets-vault`, example consumer | ✅ |
| SP2 | `oci-foundation`: the state bucket and the budget, imported | ✅ (laptop apply pending) |
| SP3 | vault-config from `projects/*.yaml`, platform CI roles, seed script, GitHub Apps | ✅ (laptop apply, seeding and the Apps pending) |
| HM1 | house-manager reads Vault and uses the building blocks (empty plan) | in review (house-manager#39) |
| SP4 | github baseline, platform CI/CD, downstream check | in review |
| SP5 | grafana stack (imports from house-manager), dashboard validator moves here | ☐ |
| HM2 | house-manager hands over Grafana, SOPS removed | ☐ |
| QO1 | QuantumOps P4 on the shared Vault (ESO), platform conventions | ☐ |

**Changes from the plan:**
- **`validate.py`** (the Grafana dashboards and alerts checker, 781 lines of house-manager layout rules) moves
  in SP5, with the `grafana-alerts` module whose file layout it checks. It doesn't move in SP1.
- **The downstream check needs no receiver credentials.** The platform starts each project's
  `platform-check.yml`, waits for the run and reads its result, so a project never reports back with
  `platform-bot`; `report_to` only names the run.
- **`platform-bot` has Contents: write** on the repos it is installed on: GitHub ties `repository_dispatch`
  (`platform-changed`) to it.
- **`project-changed` waits for SP5,** where it first has something to trigger (the grafana stack), and where a
  project gets a credential to send it. Until then `platform-apply.yml` can be started from the Actions tab.
- **Secret scanning is set by a script** (`stacks/github/scripts/repo-security.sh`, after each apply and
  checked by the drift run): the GitHub provider only has it on the whole `github_repository` resource, which
  the platform doesn't own.

## Ownership rules
1. Each resource has one owner repo.
2. The platform creates the space and the credential; the project fills the space.
3. Handoff:
   - secrets and facts tofu needs go to `kv/<project>/platform/*`;
   - workflow-level facts become Actions variables (`VAULT_ADDR`).
   - No repo reads another repo's state.
4. Moving a resource between repos: the new owner adds an `import {}` block and applies first; the old owner adds `removed { lifecycle { destroy = false } }`. Both plans must show nothing created or destroyed.
5. Every PR must be safe on its own, i.e. backward compatible. Removing something goes in reverse order (the project stops using it, then the platform removes it).

## Target layout: shared-platform
```
stacks/
  oci-foundation/   NEW  state bucket (imported from QuantumOps), $0 budgets      laptop-only
  vault-server/     moved from root                                              laptop-only (break-glass)
  vault-config/     moved; reads projects/*.yaml                                 CI-applied
  grafana/          NEW  stack-level Grafana + per-project spaces                CI-applied
  github/           moved; baseline for every project repo                       CI-applied
projects/<name>.yaml   one declaration per project (house-manager, quantumops, smoke)
modules/               used by projects: secrets-vault, grafana-alerts (YAML→rules), grafana-synthetic
                       (the per-project Vault and GitHub modules are internal: stacks/vault-config/modules/project, stacks/github/modules/baseline)
tools/                 python: changes.py, plan_guard.py, transient.py, downstream.py, dashboards validate.py, gha_trace.py (+ tests)
.github/actions/       vault-env (OIDC login + export), setup-tools (pinned + checksums)
.github/workflows/     reusable: tofu-stack.yml, security.yml, gha-telemetry.yml; own: ci, platform-apply, drift, downstream, platform-check
examples/consumer/     a minimal project that the in-repo tests run the reusable workflows against
docs/                  ROADMAP (this plan), contract.md (what a project can rely on), runbooks
```
Moving a stack folder doesn't change its state: the state key is set in the backend block, not by the folder. `scripts/tofu.sh` takes `STACK=stacks/<name>`.

## Vault layout
| Path | Holds | Written by | Read by |
|---|---|---|---|
| `kv/platform/*` | the platform's own credentials: Grafana cloud token + stack SA, the platform GitHub App key, state S3 keys + passphrase | admin (seed) | platform CI |
| `kv/shared/supabase` | Supabase PAT (account-wide, can't be scoped) | admin | projects that declare `shared_credentials: [supabase]` |
| `kv/<project>/{app,monitoring,providers,state}` | the project's own secrets | admin (seed script) | the project's CI roles |
| `kv/<project>/platform/*` | minted for the project: Grafana OTLP tokens, project SA token, SM token, Faro URL, its GitHub App key | platform apply (+ user for the App key) | the project |
| `kv/<project>/generated` | values the project's own apply mints | project apply | the project's scheduled jobs |

## Project declaration (example)
```yaml
# projects/house-manager.yaml
repo: michael-attias123/house-manager
vault:
  roles: [{ role: main, ref: refs/heads/main, write: [generated] }, { role: pr, ref: "refs/pull/*" }]
  shared_credentials: [supabase]
grafana:
  folders: { dashboards: House manager, alerts: House manager alerts }
  otlp: [edge, ci]
  faro_origin: https://house-manager-9y8.pages.dev
  gitsync: { path: observability/dashboards }
  alert_routing: observability/alerting/policies.yaml   # subtree, read from the project repo at plan time
github: { baseline: true, allowed_actions: [denoland/setup-deno@*] }
downstream: { workflow: platform-check.yml, changed_event: platform-changed }
```

## Work, as PRs in order
**SP = shared-platform, HM = house-manager, QO = QuantumOps.** User steps are marked 👤.

### SP1: layout + shared building blocks (no infra change)
- **Folders:** move stacks to `stacks/`; update `tofu.sh`, the Makefile, CI and docs.
- **`tools/`:** port the house-manager scripts with their tests. They're generalized by a config file per consumer:
  - `changes.py` reads `.platform/changes.toml`;
  - `plan_guard.py` takes allowed prefixes and protected resource types as arguments;
  - `validate.py` takes its paths and the data-source allowlist as arguments.
- **`setup-tools` action:** tofu, terraform, tflint and actionlint, pinned by commit SHA or sha256. Trivy runs through its pinned action; shellcheck comes with the runner.
- **`vault-env` action:** its own script (no third-party action): JWT login on `jwt-github`, `<path> <key> | <ENV>` lines, `export-token`, and 4 tries.
- **`tofu-stack.yml` (`workflow_call`):**
  - **Inputs:** dir, vault role, vault paths, guard args, `pre_plan` / `post_apply` scripts and `drift_issue_label`.
  - **On a PR:** plan with the transient retry, then a PR comment.
  - **On main:** apply the saved plan, then run `post_apply`.
  - **On a schedule:** the drift check opens or updates an issue.
  - **`PLATFORM_REF` support:** before init, rewrite `?ref=main` to `?ref=$PLATFORM_REF` in the runner's checkout. Sources stay literal `ref=main`, so house-manager keeps Terraform compatibility. Tools are checked out at the same ref.
- **`security.yml`:** gitleaks, trivy config, actionlint, shellcheck. **`gha-telemetry.yml`:** generalized from house-manager's `telemetry.yml`.
- **Tests:** in-repo workflows call each reusable workflow by local path against `examples/consumer/`, so the PR's version is what gets tested. Module `tftest`s cover the rest.

### SP2: oci-foundation
- **Imports (`import {}`):** QuantumOps's state bucket (versioning stays), the $0 budget alarms that `oci.sh` creates today, and the existing tenancy-level IAM it needs.
- **State:** its own state lives in that bucket, under key `platform/oci-foundation`.
- **Credential files:** `tofu.sh` reads `~/.config/platform/state.env`, falling back to the old `~/.config/qops/*`.
- 👤 Apply from the laptop. The plan must show only imports.

### SP3: vault-config driven by projects/*.yaml
- **Projects from YAML:** `fileset("projects/*.yaml")` + `yamldecode` → `for_each` over `stacks/vault-config/modules/project`. `smoke` becomes `projects/smoke.yaml`.
- **Module features:**
  - a role-name suffix (several roles per repo);
  - `bound_claims_type = "glob"` (`refs/pull/*`);
  - write sub-paths;
  - `shared_credentials` grants;
  - Kubernetes roles for QuantumOps (`clusters/qops.pub.pem`).
- **Platform CI roles:**
  - `platform-plan`: shared-platform `refs/pull/*`; reads config and `kv/platform/*`.
  - `platform-apply`: shared-platform `refs/heads/main`. Its policy manages policies, roles and mounts, and writes `kv/*/platform/*`.
  - `platform-drift` (added in SP4): `refs/heads/main` with the plan policy, for the scheduled drift check.
- **Policy changes in review:** the vault-config plan comment on the PR shows each policy's diff (SP4, `platform-apply.yml`).
- 👤 First apply from the laptop with the admin token (MFA). CI applies from then on.
- 👤 Seed script `scripts/seed.sh`, run from the laptop:
  - copies house-manager's SOPS values to `kv/house-manager/{app,monitoring}`;
  - prompts with hidden input for each provider token and the state values into `kv/*/providers|state` and `kv/platform/*`;
  - prints names only.
- 👤 Create the GitHub Apps with a manifest link the script prints, one browser click each:
  - `platform-bot`, installed on all three repos, for dispatches and baseline;
  - `house-manager-bot`, installed only on house-manager, replacing `GH_ADMIN_TOKEN`;
  - `quantumops-bot`.

  Their keys go into Vault through the seed script.

### HM1: house-manager reads Vault + consumes the shared building blocks (empty plan)
- **Secrets:** the earlier plan, now through `modules/secrets-vault` (`?ref=main`), with the same `values` map, so the plan is empty.
- **Workflows:**
  - `infra.yml` and `observability-sync.yml` call `tofu-stack.yml`. Their extra steps (`pages-rebuild`, `sync-vault`, `sync-db-roles`, Grafana env) become `pre_plan` / `post_apply` scripts.
  - db-migrate, prices, venues, price-probe and telemetry use `vault-env`.
  - The GitHub provider uses a `house-manager-bot` installation token instead of `GH_ADMIN_TOKEN`.
- **Tools:** delete the local copies of the 5 tools and their tests; CI uses `tools/` at `PLATFORM_REF`.
- **`platform-check.yml`:** a new workflow that receives the downstream check (`workflow_dispatch`, inputs `platform_ref` and `report_to`; [contract.md](contract.md)). It runs the path-rule tests and a full plan at that ref; the run's conclusion is the answer.
- **`platform-changed`:** a `repository_dispatch` trigger on `infra.yml` that applies main.
- **Kept for rollback:** SOPS stays in this PR. Merge gate: the plan shows no change except Actions secrets → variables.

### SP4: github stack + platform CI/CD
- **github stack, for each project with `github.baseline: true`:**
  - a baseline ruleset `platform-baseline` (PR required, no force push or deletion);
  - secret scanning + push protection (`repo-security.sh`);
  - Actions default token read-only, plus an allowed-actions list: GitHub's own, what the building blocks use, and the project's `github.allowed_actions`;
  - the `VAULT_ADDR` variable (`adopt_vault_addr: true` imports one set by hand).
- **What projects keep:** a separate required-checks ruleset each (rulesets stack). house-manager's `github_branch_protection` becomes a `github_repository_ruleset` with checks only. That change is in HM2, after the baseline exists.
- **Platform workflows:**
  - `ci.yml`: changed stacks only, through `tools/changes.py` and `.platform/changes.toml`;
  - `platform-apply.yml`: plans on a PR; on merge applies in order vault-config → grafana (SP5) → github, each through `tofu-stack.yml`, with a destroy guard. Destroying a KV mount, auth backend, audit device, policy or ruleset needs the `allow-destroy` label. (The state bucket is laptop-only and has `prevent_destroy`.)
  - `drift.yml`: every 6 hours, read-only;
  - `downstream.yml`, a required check: start `platform-check` in each project, wait, post one comment with each project's plan summary, fail if any failed. After merge, `platform-apply.yml` checks again and sends `platform-changed` to each project whose plan isn't empty.
  - `platform-check.yml`: this repo's own receiver (it plans `examples/consumer`), so the check is exercised on every PR even before a project has one.
- **Project changes** (SP5): when house-manager's alert routing or project declaration inputs change on its main, the platform applies `grafana`.

### SP5: grafana stack (imports from house-manager)
- **Provider credentials:** from `kv/platform/grafana`.
- **Imports from house-manager's state:**
  - the SM installation + publisher token;
  - org preferences;
  - the `email-owner` contact point;
  - the notification policy;
  - the dashboard and alert folders;
  - the Git Sync repository;
  - the Faro app;
  - the OTLP access policies + rotating tokens.

  The ids come from `tofu state show` on the HM side, using a helper script.
- **New:**
  - **Notification tree:** the root is `email-owner`, with one route per project (`project=<name>`). Its children come from the file the project names in `alert_routing`, read with `data "github_repository_file"` at plan time.
  - **Per-project tokens:** a service account (Editor) token per project, plus the SM token, Faro URL and OTLP tokens. All are written to `kv/<project>/platform/grafana`.
  - **Platform folder:** an SM check on Vault's `/v1/sys/health` with a "Vault down/sealed" alert, and a free-tier usage dashboard with alerts at 80% (series, logs, traces, SM executions). It uses the stack's usage data source; its uid gets verified when the stack is built.
- **When a token rotates:** after an apply that rotated a token, the project's plan has changes, so the platform sends it `platform-changed`, and its apply re-applies its Edge Function secrets.
- **`project-changed`:** the way for a project to ask for a grafana apply, and the credential it sends it with.

### HM2: house-manager hands over Grafana + removes SOPS
- **`removed` blocks:** for every resource SP5 imported.
- **New inputs:** `module.observability` reads OTLP, SA, SM and Faro from `kv/house-manager/platform/grafana`.
- **What it keeps:** the Postgres data source, scrape job, rule groups, mute timings, synthetic checks and the `app-push` contact point.
  - Rules get a `project=house-manager` label (added in the renderer).
  - `app-push` is renamed `house-manager-app-push`, and the platform tree references the new name. Order inside the PR: create the new name before the tree switch, which applies in SP5's next run.
- **Required checks:** the branch-protection → checks-ruleset change.
- **Remove SOPS:** delete `secrets.enc.yaml`, `.sops.yaml`, `modules/secrets/sops` and `encrypt-secrets.sh`, and the sops steps.
- 👤 Run `scripts/drop-github-secrets.sh` (`gh secret delete` for the 8 hand-set secrets).
- **Docs:** `BOOTSTRAP.md`, `SECRETS.md`, `MIGRATING.md`, `docs/setup.md` §8 and `CLAUDE.md` (monitoring + secrets sections).

### QO1: QuantumOps P4 on the shared Vault + platform conventions
- **State bucket:** `oci.sh`'s bucket and budgets steps become a check that the bucket exists, since oci-foundation owns them now.
- **P4 Vault:** ADR + ROADMAP: P4 uses the **shared Vault** (no in-cluster Vault, no vault-config-operator; Vault config lives in shared-platform), and P11 sends Alloy output to the shared Grafana stack.
- **Argo CD apps:**
  - External Secrets Operator;
  - a `ClusterSecretStore` → `https://<vault>`, JWT on `jwt-k8s-qops`;
  - an `ExternalSecret` for the Tailscale OAuth client, replacing the bootstrap-script secret noted in `values.yaml`.

  CI checks them with helm lint and kubeconform.
- **Declaration and cluster key:**
  - `projects/quantumops.yaml` (k8s role, plus GitHub role for main);
  - 👤 copy the cluster's service-account public key into `stacks/vault-config/clusters/qops.pub.pem`, using the command in onboard-project.md.
- **CI:** QuantumOps calls `security.yml`, and gets a `platform-check.yml` receiver (its CI + `tofu plan` for `infra/oci` and `infra/github`).

## Defaults chosen (tell me to change any)
- **vault-config applies on its own after merge,** with the destroy guard: no approval click.
- **GitHub API access:** one App per project, plus `platform-bot`. Fine-grained PATs expire yearly, so no PATs.
- **house-manager's state stays in its pg backend.** Only the connection string and passphrase move to Vault, which keeps it Terraform-compatible.
- **QuantumOps P11 (observability):** only the ADR and roadmap change now. Its manifests come when P8 is done.

## Verification
- **SP1:** `make check`; the reusable-workflow test runs against `examples/consumer` are green; the tools' tests are green.
- **SP2 / SP3:** the laptop plans show imports only. `vault-smoke.yml` is green. `vault read auth/jwt-github/role/house-manager-…-main` shows the right claims, and a PR role can't write.
- **HM1:**
  - The PR plan is empty (except secrets → variables).
  - After merge, each of these runs green once: infra apply, observability-sync, db-migrate, prices, venues and telemetry.
  - The `bootstrap-check` Vault checks pass.
  - A `platform-check` dispatch reports back.
- **SP4:**
  - A test PR in shared-platform shows the downstream comment for house-manager (and QuantumOps after QO1).
  - A PR that breaks the module example is blocked.
  - Drift runs and the issue opens.
- **SP5 + HM2:**
  - Both plans show no create or destroy for the moved resources.
  - Alerts still reach email and the app push; to test, fire a test alert with the `push="true"` label.
  - Faro data still arrives.
  - The Vault health alert fires when the check URL is pointed at a bad path in a test PR.
- **QO1:** CI green (helm and kubeconform); after Argo CD syncs, the `ExternalSecret` shows `SecretSynced` (👤 visible in the cluster).
- **Finally:** `grep -r 'secrets\.' .github/workflows` in house-manager lists only `github.token`. No hand-set secrets remain in any repo.

## Needed from the user, in order
1. Vault initialized, public, admin MFA on; its URL.
2. Approve write access for shared-platform and QuantumOps in this session.
3. Laptop applies: SP2, the first apply of SP3.
4. The seed script.
5. 3 App creations and installs.
6. The cluster public key.
7. The final `drop-github-secrets.sh`.
