#!/usr/bin/env bash
# Posts a PR comment, or updates the one this workflow posted before.
#   Usage: pr_comment.sh MARKER FILE
#   Env: PR, GH_REPO, GH_TOKEN (pull-requests: write).
# The comment is found by MARKER, the first line of FILE (an HTML comment such
# as <!-- downstream-check -->), among the comments github-actions[bot] wrote.
set -euo pipefail

marker="${1:?usage: pr_comment.sh MARKER FILE}"
file="${2:?}"
: "${PR:?}" "${GH_REPO:?}"
[[ "$PR" =~ ^[0-9]+$ ]] || {
  echo "::error::pr_comment: PR must be a number" >&2
  exit 1
}
[[ "$(head -n1 "$file")" == "$marker" ]] || {
  echo "::error::pr_comment: $file must start with the marker" >&2
  exit 1
}

id="$(gh api --paginate "repos/$GH_REPO/issues/$PR/comments" |
  jq -r --arg m "$marker" '.[] | select(.user.login == "github-actions[bot]" and (.body | startswith($m))) | .id' |
  sed -n 1p)"
if [[ -n "$id" ]]; then
  jq -Rs '{body: .}' "$file" | gh api -X PATCH "repos/$GH_REPO/issues/comments/$id" --input - >/dev/null
  echo "pr_comment: updated the comment on #$PR"
else
  jq -Rs '{body: .}' "$file" | gh api "repos/$GH_REPO/issues/$PR/comments" --input - >/dev/null
  echo "pr_comment: posted a comment on #$PR"
fi
