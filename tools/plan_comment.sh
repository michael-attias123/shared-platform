#!/usr/bin/env bash
# Posts (or updates) one PR comment with a stack's plan, for tofu-stack.yml.
# Run in the stack directory.
#   Usage: plan_comment.sh PLANFILE OUTCOME     (OUTCOME: the plan step's outcome)
#   Env: STACK (the label in the title and marker), PR, SHA, RUN_URL, GH_REPO, GH_TOKEN.
# A failed plan gets a short comment: the error stays in the run log, since it
# may quote configuration. One comment per stack, found by its marker.
set -euo pipefail

planfile="${1:?usage: plan_comment.sh PLANFILE OUTCOME}"
outcome="${2:?}"
: "${STACK:?}" "${PR:?}" "${SHA:?}" "${RUN_URL:?}" "${GH_REPO:?}"
marker="<!-- tofu-plan:$STACK -->"
comment="${RUNNER_TEMP:-/tmp}/comment-$$.md"
plan_txt="${RUNNER_TEMP:-/tmp}/plan-$$.txt"
# A comment holds 65536 characters; the rest is in the run log.
limit=60000

if [[ "$outcome" == success && -f "$planfile" ]]; then
  tofu show -no-color "$planfile" >"$plan_txt"
  summary="$(grep -m1 -E '^(Plan: |No changes\.)' "$plan_txt" || echo 'Only output changes.')"
  summary="${summary#Plan: }"
  {
    echo "$marker"
    echo "### OpenTofu plan · \`$STACK\`: $summary"
    echo
    echo "Commit ${SHA:0:7} · [run log]($RUN_URL)"
    echo
    echo '<details><summary>Show plan</summary>'
    echo
    echo '```text'
    head -c "$limit" "$plan_txt"
    echo
    echo '```'
    if (($(wc -c <"$plan_txt") > limit)); then
      echo
      echo "_Cut at $limit characters: the full plan is in the [run log]($RUN_URL)._"
    fi
    echo
    echo '</details>'
  } >"$comment"
  rm -f "$plan_txt"
elif [[ "$outcome" == skipped-outage ]]; then
  # shellcheck disable=SC2016 # markdown backticks, not a command
  printf '%s\n### OpenTofu plan · `%s`: skipped, a provider was unavailable\n\nCommit %s · [run log](%s).\n' \
    "$marker" "$STACK" "${SHA:0:7}" "$RUN_URL" >"$comment"
else
  # shellcheck disable=SC2016 # markdown backticks, not a command
  printf '%s\n### OpenTofu plan · `%s` failed\n\nCommit %s · see the [run log](%s).\n' \
    "$marker" "$STACK" "${SHA:0:7}" "$RUN_URL" >"$comment"
fi

id="$(gh api --paginate "repos/$GH_REPO/issues/$PR/comments" |
  jq -r --arg m "$marker" '.[] | select(.user.login == "github-actions[bot]" and (.body | startswith($m))) | .id' |
  sed -n 1p)"
if [[ -n "$id" ]]; then
  jq -Rs '{body: .}' "$comment" | gh api -X PATCH "repos/$GH_REPO/issues/comments/$id" --input - >/dev/null
else
  jq -Rs '{body: .}' "$comment" | gh api "repos/$GH_REPO/issues/$PR/comments" --input - >/dev/null
fi
rm -f "$comment"
echo "plan_comment: posted the plan of $STACK on #$PR"
