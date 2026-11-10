#!/usr/bin/env bash
# Secret scanning and push protection on every repo with the platform baseline. The GitHub provider can
# only set them through the whole github_repository resource, which this stack does not own, so this
# script does it: tofu-stack.yml's post-apply hook for stacks/github (turns them on where they are off)
# and its post-drift hook (DRIFT_EXITCODE is set: only checks, and fails when one is off).
# Run in stacks/github after init. Env: GITHUB_TOKEN (platform-bot's installation token).
# Both are free on public repos. A private repo without GitHub Advanced Security gets a warning.
set -euo pipefail

: "${GITHUB_TOKEN:?repo-security: needs the GitHub App token (tofu-stack.yml github-app)}"
check_only=0
if [[ -n "${DRIFT_EXITCODE:-}" ]]; then
  [[ "$DRIFT_EXITCODE" == skip ]] && exit 0
  check_only=1
fi
api() { GH_TOKEN="$GITHUB_TOKEN" gh api "$@"; }

off=0
while IFS= read -r repo; do
  [[ -n "$repo" ]] || continue
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
    echo "::error::repo-security: bad repository name" >&2
    exit 1
  }
  # </dev/null: the loop reads the repo list from stdin.
  info="$(api "repos/$repo" </dev/null)"
  state="$(jq -r '[.security_and_analysis.secret_scanning.status // "unknown",
                   .security_and_analysis.secret_scanning_push_protection.status // "unknown"] | join(" ")' <<<"$info")"
  if [[ "$state" == "enabled enabled" ]]; then
    echo "repo-security: $repo: secret scanning and push protection are on"
    continue
  fi
  if ((check_only)); then
    echo "::error::repo-security: $repo: secret scanning or push protection is off ($state)"
    off=$((off + 1))
    continue
  fi
  if api -X PATCH "repos/$repo" --input - >/dev/null 2>&1 <<<'{"security_and_analysis":
      {"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}'; then
    echo "repo-security: $repo: turned secret scanning and push protection on"
  elif [[ "$(jq -r '.private' <<<"$info")" == true ]]; then
    echo "::warning::repo-security: $repo is private: secret scanning needs GitHub Advanced Security there."
  else
    echo "::error::repo-security: $repo: GitHub refused the change"
    off=$((off + 1))
  fi
done < <(tofu output -json baseline_repositories | jq -r '.[]')

((off == 0)) || exit 1
