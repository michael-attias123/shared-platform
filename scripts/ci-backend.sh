#!/usr/bin/env bash
# tofu-stack.yml's pre-plan hook for this repo's own stacks: points `tofu init` at the shared state bucket.
# The laptop gets the same three settings from scripts/tofu.sh; in CI they come from kv/platform/state
# through the job's Vault login (.github/workflows/platform-apply.yml).
#   Env: STATE_BUCKET, STATE_NAMESPACE, STATE_REGION, RUNNER_TEMP, GITHUB_ENV.
set -euo pipefail

: "${STATE_BUCKET:?}" "${STATE_NAMESPACE:?}" "${STATE_REGION:?}" "${RUNNER_TEMP:?}" "${GITHUB_ENV:?}"
for value in "$STATE_BUCKET" "$STATE_NAMESPACE" "$STATE_REGION"; do
  [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "::error::ci-backend: a state setting has unexpected characters" >&2
    exit 1
  }
done

file="$RUNNER_TEMP/backend.hcl"
cat >"$file" <<HCL
bucket    = "$STATE_BUCKET"
region    = "$STATE_REGION"
endpoints = { s3 = "https://$STATE_NAMESPACE.compat.objectstorage.$STATE_REGION.oci.customer-oci.com" }
HCL
echo "TF_CLI_ARGS_init=-backend-config=$file" >>"$GITHUB_ENV"
echo "ci-backend: tofu init uses the shared state bucket"
