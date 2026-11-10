#!/usr/bin/env bash
# Opens, updates or closes the drift issue of one stack, for tofu-stack.yml.
# Run in the stack directory after tofu_plan.sh.
#   Usage: drift_issue.sh EXITCODE PLANFILE   (EXITCODE from tofu_plan.sh: 0, 2 or skip)
#   Env: STACK, LABEL (default infra-drift), RUN_URL, GH_REPO, GH_TOKEN.
# One open issue per stack, found by the marker in its body. 0 closes it,
# 2 opens or updates it, skip leaves it as it is.
set -euo pipefail

exitcode="${1:?usage: drift_issue.sh EXITCODE PLANFILE}"
planfile="${2:?}"
: "${STACK:?}" "${RUN_URL:?}" "${GH_REPO:?}"
label="${LABEL:-infra-drift}"
marker="<!-- drift:$STACK -->"

open_issue() {
  gh issue list --label "$label" --state open --limit 50 --json number,body |
    jq -r --arg m "$marker" '.[] | select(.body | contains($m)) | .number' | sed -n 1p
}

case "$exitcode" in
  0)
    number="$(open_issue)"
    if [[ -n "$number" ]]; then
      gh issue close "$number" --comment "No difference any more ([run log]($RUN_URL))." >/dev/null
      echo "drift_issue: closed #$number"
    fi
    ;;
  2)
    plan_txt="${RUNNER_TEMP:-/tmp}/drift-$$.txt"
    body="${RUNNER_TEMP:-/tmp}/drift-$$.md"
    tofu show -no-color "$planfile" >"$plan_txt"
    summary="$(grep -m1 -E '^Plan: ' "$plan_txt" || echo 'Output changes only.')"
    limit=60000
    {
      echo "$marker"
      echo "The live infrastructure differs from \`$STACK\` on main. $summary"
      echo
      echo "Found by the drift check: [run log]($RUN_URL), $(date -u +%F)."
      echo "Either put the change into code (a PR) or undo it where it was made;"
      echo "the next check closes this issue once there is no difference."
      echo
      echo '<details><summary>Show plan</summary>'
      echo
      echo '```text'
      head -c "$limit" "$plan_txt"
      echo
      echo '```'
      echo
      echo '</details>'
    } >"$body"
    gh label create "$label" --color D93F0B --description 'The live infrastructure differs from the code' \
      --force >/dev/null
    number="$(open_issue)"
    if [[ -n "$number" ]]; then
      gh issue edit "$number" --body-file "$body" >/dev/null
      echo "::warning::Drift in $STACK: updated issue #$number."
    else
      url="$(gh issue create --title "Infrastructure drift: $STACK differs from the code" \
        --label "$label" --body-file "$body")"
      echo "::warning::Drift in $STACK: opened $url."
    fi
    rm -f "$plan_txt" "$body"
    ;;
  skip) echo "drift_issue: the plan was skipped (provider unavailable); the issue stays as it is." ;;
  *)
    echo "::error::drift_issue: unexpected exit code '$exitcode'" >&2
    exit 1
    ;;
esac
