#!/usr/bin/env bash
# Creates a GitHub App from a manifest and stores its id and private key in Vault, from your laptop, as the
# admin (make vault-login). GitHub Apps replace personal access tokens: short-lived installation tokens, no
# yearly expiry.
#   Usage: github-app.sh platform-bot             -> kv/platform/github-app       (install on every repo)
#          github-app.sh <project>-bot             -> kv/<project>/providers      (install on that repo only)
#
# 1. It writes an HTML page that posts the manifest to GitHub; open it and click "Create GitHub App".
# 2. GitHub redirects to this repo's docs with ?code=... in the address bar; paste that address (hidden).
# 3. It exchanges the code (valid one hour) for the app's id and private key and writes them to Vault.
#    Nothing is printed but the app's name, its granted permissions and the install link.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APP="${1:-}"
[[ "$APP" =~ ^[a-z0-9][a-z0-9-]*-bot$ ]] || die "usage: github-app.sh platform-bot | <project>-bot"
OWNER="${GITHUB_OWNER:-michael-attias123}"

# Repository permissions. The project bot covers what its OpenTofu github stack manages (branch rules,
# Actions variables and secrets); the platform bot also starts workflows in the projects' repos
# (actions: write), reads the plan notices on those runs (checks: read) and sends repository_dispatch
# events, which GitHub ties to contents: write.
case "$APP" in
  platform-bot)
    KV_PATH="platform/github-app"
    ID_KEY="app_id" KEY_KEY="private_key"
    PERMS='{"metadata":"read","contents":"write","actions":"write","checks":"read","administration":"write","actions_variables":"write","issues":"write","pull_requests":"write"}'
    ;;
  *)
    project="${APP%-bot}"
    [[ -f "$PLATFORM_ROOT/projects/$project.yaml" ]] || die "no projects/$project.yaml"
    KV_PATH="$project/providers"
    ID_KEY="github_app_id" KEY_KEY="github_app_private_key"
    PERMS='{"metadata":"read","contents":"read","administration":"write","actions_variables":"write","secrets":"write"}'
    ;;
esac

need jq
need curl
need vault
VAULT_ADDR="${VAULT_ADDR:-$(vault_addr_from_settings)}"
export VAULT_ADDR
vault token lookup >/dev/null 2>&1 || die "not logged in to $VAULT_ADDR. Run: make vault-login"
if vault kv get -mount=kv -format=json "$KV_PATH" 2>/dev/null | jq -e --arg k "$KEY_KEY" '.data.data[$k] // empty' >/dev/null; then
  die "kv/$KV_PATH already has $KEY_KEY. To replace the app, delete that key first (vault kv patch)."
fi

mkdir -p "$PLATFORM_CONFIG_DIR"
chmod 700 "$PLATFORM_CONFIG_DIR"
WORK="$(mktemp -d "$PLATFORM_CONFIG_DIR/github-app.XXXXXX")"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

state="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
redirect="https://github.com/$OWNER/shared-platform/blob/main/docs/runbooks/github-apps.md"
manifest="$(jq -cn --arg name "$APP" --arg url "https://github.com/$OWNER/shared-platform" \
  --arg redirect "$redirect" --argjson perms "$PERMS" '{
    name: $name, url: $url, redirect_url: $redirect, public: false,
    hook_attributes: {url: $url, active: false},
    default_permissions: $perms, default_events: []
  }')"
page="$WORK/create-$APP.html"
jq -rn --arg m "$manifest" --arg state "$state" '
  "<!doctype html><meta charset=utf-8><title>Create the GitHub App</title>",
  "<form method=post action=\"https://github.com/settings/apps/new?state=\($state)\">",
  "<input type=hidden name=manifest value=\"\($m | @html)\">",
  "<button>Create the GitHub App on GitHub</button></form>"' >"$page"

info "1. open this page in your browser and click the button, then \"Create GitHub App\" on GitHub:"
printf '   %s\n' "$page"
if is_wsl && have wslpath; then printf '   (Windows: %s)\n' "$(wslpath -w "$page")"; fi
info "2. GitHub then shows this repo's github-apps runbook; copy the whole address from the address bar."
printf '   paste it here (hidden): '
IFS= read -rs url </dev/tty
printf '\n'
code="$(sed -n 's/.*[?&]code=\([A-Za-z0-9_-]*\).*/\1/p' <<<"$url")"
got_state="$(sed -n 's/.*[?&]state=\([A-Za-z0-9]*\).*/\1/p' <<<"$url")"
url=""
[[ -n "$code" ]] || die "no ?code= in that address"
[[ "$got_state" == "$state" ]] || die "the address is from another attempt (state mismatch); run this again"

curl -sS --fail-with-body -X POST -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/app-manifests/$code/conversions" -o "$WORK/app.json" ||
  die "GitHub refused the code (it is valid for one hour, once): $(jq -r '.message // empty' "$WORK/app.json" 2>/dev/null)"

jq -n --slurpfile a "$WORK/app.json" --arg id "$ID_KEY" --arg key "$KEY_KEY" \
  '{($id): ($a[0].id | tostring), ($key): $a[0].pem}' >"$WORK/kv.json"
if vault kv get -mount=kv "$KV_PATH" >/dev/null 2>&1; then
  vault kv patch -mount=kv "$KV_PATH" @"$WORK/kv.json" >/dev/null
else
  vault kv put -mount=kv "$KV_PATH" @"$WORK/kv.json" >/dev/null
fi
ok "created $(jq -r .slug "$WORK/app.json"); id and private key are in kv/$KV_PATH"

granted="$(jq -c '.permissions // {}' "$WORK/app.json")"
info "granted permissions: $granted"
jq -n --argjson want "$PERMS" --argjson got "$granted" -r '$want | keys[] | select($got[.] == null)' |
  while read -r p; do warn "GitHub did not grant '$p': add it on the app's settings page (Permissions)"; done

slug="$(jq -r .slug "$WORK/app.json")"
info "3. install it: https://github.com/apps/$slug/installations/new"
if [[ "$APP" == platform-bot ]]; then
  printf '   choose: All repositories, or each project repo plus shared-platform\n'
else
  printf '   choose: Only select repositories -> %s\n' "$OWNER/${APP%-bot}"
fi
