#!/usr/bin/env bash
# `tofu plan -detailed-exitcode` to a saved plan, for tofu-stack.yml. Run in
# the stack directory after `tofu init`.
#   Usage: tofu_plan.sh PLANFILE
#   Output (GITHUB_OUTPUT): exitcode=0 (no changes), 2 (changes) or skip
#   (the provider was down; see below), and summary= the plan's one-line
#   summary (counts only). Any other failure exits 1.
#
# The plan's text goes to $RUNNER_TEMP/plan.log; the log shows only its
# summary line, or the errors. A plan that failed only on server-side errors
# (tools/transient.py) is retried once after RETRY_DELAY seconds. If it fails
# the same way again and ALLOW_OUTAGE is true (scheduled runs: nobody waits on
# them, the next one catches up), the run ends with a warning instead, unless
# no run of this workflow has reached the providers for OUTAGE_GRACE_HOURS
# (tools/last_reached.sh), so a long outage still fails.
#
# Env: TARGETS (one -target address per line, optional), ALLOW_OUTAGE,
# OUTAGE_GRACE_HOURS (default 6), RETRY_DELAY (default 60), WORKFLOW_FILE,
# GH_REPO, GH_TOKEN, GITHUB_OUTPUT, GITHUB_STEP_SUMMARY, RUNNER_TEMP.
set -euo pipefail

TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
planfile="${1:?usage: tofu_plan.sh PLANFILE}"
log="${RUNNER_TEMP:?}/plan.log"
: "${GITHUB_OUTPUT:?}"
summary_file="${GITHUB_STEP_SUMMARY:-/dev/null}"

args=(plan -detailed-exitcode -no-color -input=false -lock-timeout=5m -out="$planfile")
while IFS= read -r target; do
  target="${target#"${target%%[![:space:]]*}"}"
  target="${target%"${target##*[![:space:]]}"}"
  [[ -n "$target" ]] && args+=("-target=$target")
done <<<"${TARGETS:-}"

code=0
plan() {
  set +e
  tofu "${args[@]}" >"$log" 2>&1
  code=$?
  set -e
}
transient() { python3 "$TOOLS/transient.py" "$log"; }

plan
if [[ "$code" == 1 ]] && transient; then
  echo "The provider is unavailable (server errors only); retrying in ${RETRY_DELAY:-60} s."
  sleep "${RETRY_DELAY:-60}"
  plan
fi
if [[ "$code" == 1 ]] && transient && [[ "${ALLOW_OUTAGE:-false}" == true ]]; then
  last="$("$TOOLS/last_reached.sh" "${WORKFLOW_FILE:?}" '*' 'Reached the providers' | cut -d' ' -f2 || true)"
  grace=$((${OUTAGE_GRACE_HOURS:-6} * 3600))
  if [[ -n "$last" ]] && (($(date -u +%s) - $(date -u -d "$last" +%s) < grace)); then
    echo "::warning::A provider is unavailable (server errors only). Nothing changed; the next run retries. Last run that reached the providers: $last."
    echo "Skipped: a provider was unavailable. Last run that reached the providers: $last." >>"$summary_file"
    echo "exitcode=skip" >>"$GITHUB_OUTPUT"
    echo "summary=Skipped: a provider was unavailable." >>"$GITHUB_OUTPUT"
    exit 0
  fi
  echo "No run has reached the providers for over ${OUTAGE_GRACE_HOURS:-6} hours (last: ${last:-none})."
fi
echo "exitcode=$code" >>"$GITHUB_OUTPUT"
case "$code" in
  0) summary="No changes." ;;
  2) summary="$(grep -m1 -E '^Plan: ' "$log" || echo "Only output changes.")" ;;
  *)
    echo "summary=The plan failed." >>"$GITHUB_OUTPUT"
    grep -A8 '^Error' "$log" || echo "The plan failed."
    exit 1
    ;;
esac
echo "$summary" | tee -a "$summary_file"
echo "summary=$summary" >>"$GITHUB_OUTPUT"
