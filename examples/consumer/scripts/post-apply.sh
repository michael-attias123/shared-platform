#!/usr/bin/env bash
# tofu-stack.yml's post-apply hook, run in the stack directory: proves it runs
# after the apply with the state in place.
set -euo pipefail
[[ "${PLAN_CHANGED:-}" == true ]] || {
  echo "::error::post-apply: expected PLAN_CHANGED=true on a fresh runner"
  exit 1
}
[[ "$(tofu output -raw greeting)" == "hello from the example consumer" ]]
echo "post-apply: ran after the apply"
