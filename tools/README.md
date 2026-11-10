# tools

Scripts the reusable workflows run in projects' CI. Each has its tests in [`tests/`](tests/)
(`make test-tools`). They print names, counts and resource addresses, never values: project logs are public.

| Tool | Used by | Does |
|---|---|---|
| `tofu_plan.sh` | `tofu-stack.yml` | `tofu plan` to a saved file; retries once when a provider is down, and on scheduled runs ends with a warning instead of a failure, unless nothing has reached the providers for 6 hours |
| `transient.py` | `tofu_plan.sh` | Says whether a failed plan failed only on server-side errors (5xx, 429, timeouts) |
| `last_reached.sh` | `tofu_plan.sh` | The newest successful run of a workflow that really reached the providers |
| `plan_guard.py` | `tofu-stack.yml` | Refuses a plan with changes outside allowed modules, or deleting a protected resource type without the `allow-destroy` PR label |
| `plan_comment.sh` | `tofu-stack.yml` | One PR comment per stack with its plan |
| `drift_issue.sh` | `tofu-stack.yml` | Opens, updates or closes a stack's drift issue |
| `platform_ref.sh` | `tofu-stack.yml` | Points `shared-platform.git//...?ref=main` module sources at another ref, in the runner's checkout only |
| `changes.py` | projects' CI, `ci.yml` | Which CI areas a push or a pull request touches, from the repo's `.platform/changes.toml` |
| `downstream.py` | `downstream.yml`, `platform-apply.yml` | Starts each project's `platform-check` against a platform commit, waits, and writes the PR comment; after a merge, starts the apply of projects whose plan changed |
| `pr_comment.sh` | `downstream.yml` | Posts a PR comment, or updates the one posted before (found by its marker) |
| `gha_trace.py` | `gha-telemetry.yml` | One finished workflow run as an OpenTelemetry trace and two gauges |

`../.github/actions/vault-env/vault-env.sh` is tested here too (`tests/test_vault_env.py`, against a fake Vault),
and so are this repo's own CI hooks, `scripts/ci-backend.sh` and `stacks/github/scripts/repo-security.sh`
(`tests/test_platform_scripts.py`).
