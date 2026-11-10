#!/usr/bin/env bash
# Prints "<head_sha> <updated_at>" of the newest successful run of WORKFLOW
# on BRANCH whose job JOB ran and whose step STEP did not skip, or nothing.
# JOB '*' means any job (a reusable workflow's jobs are named "<caller> / <job>").
# A run that skips its real work (e.g. a provider outage, see transient.py)
# still ends as success, so the run's conclusion alone does not say the work
# happened. Runs older than the step (no step of that name at all) count as
# reached.
#   Usage: last_reached.sh WORKFLOW_FILE JOB STEP [BRANCH]
#   Needs GH_TOKEN (actions: read), GH_REPO, gh and jq.
set -euo pipefail

workflow="${1:?workflow file, e.g. observability-sync.yml}"
job="${2:?job name}"
step="${3:?step name}"
branch="${4:-main}"
: "${GH_REPO:?GH_REPO is required}"

runs="$(gh api "repos/$GH_REPO/actions/workflows/$workflow/runs?branch=$branch&status=success&per_page=30" \
          --jq '.workflow_runs[] | "\(.id) \(.head_sha) \(.updated_at)"')"
while read -r id sha updated; do
  [[ -n "$id" ]] || continue
  reached="$(gh api "repos/$GH_REPO/actions/runs/$id/jobs" | jq --arg job "$job" --arg step "$step" \
    '[.jobs[] | select($job == "*" or .name == $job) | .steps[]?] as $s
     | ($s | length > 0)
       and ([$s[] | select(.name == $step and .conclusion != "success")] | length == 0)')"
  if [[ "$reached" == true ]]; then
    echo "$sha $updated"
    exit 0
  fi
done <<<"$runs"
