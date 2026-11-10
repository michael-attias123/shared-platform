#!/usr/bin/env bash
# tofu-stack.yml's post-apply hook, run in the stack directory: proves it runs
# after the apply with the state in place.
set -euo pipefail
[[ "${PLAN_CHANGED:-}" == true ]] || {
  echo "::error::post-apply: expected PLAN_CHANGED=true on a fresh runner"
  exit 1
}
[[ "$(tofu output -raw greeting)" == "hello from the example consumer" ]]
# The saved plan, as JSON, for hooks that decide from it (e.g. house-manager's Pages rebuild).
[[ -s "${PLAN_JSON:-}" ]] || {
  echo "::error::post-apply: PLAN_JSON is not set or empty"
  exit 1
}
jq -e '.resource_changes[] | select(.address == "terraform_data.example")' "$PLAN_JSON" >/dev/null
[[ -n "${GH_TOKEN:-}" ]] || {
  echo "::error::post-apply: GH_TOKEN is not set"
  exit 1
}
echo "post-apply: ran after the apply"
