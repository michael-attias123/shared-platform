#!/usr/bin/env bash
# The vault-env action: GitHub OIDC token -> Vault JWT login -> KV values ->
# masked variables in $GITHUB_ENV. Prints names only, never a value.
#
# Env (set by action.yml): VE_ADDR, VE_ROLE, VE_SECRETS, VE_EXPORT_TOKEN,
# VE_MOUNT, VE_AUDIENCE; from the runner: ACTIONS_ID_TOKEN_REQUEST_URL,
# ACTIONS_ID_TOKEN_REQUEST_TOKEN, GITHUB_ENV.
# A Vault that is waking up or briefly down (5xx, no connection) gets 4 tries
# 5, 10 and 20 seconds apart; a 4xx (wrong role, missing path) fails at once.
set -euo pipefail

die() {
  echo "::error::vault-env: $*" >&2
  exit 1
}

: "${GITHUB_ENV:?runs in GitHub Actions only}"
addr="${VE_ADDR%/}"
# Tests (tools/tests/test_vault_env.py) use a local http server.
[[ "$addr" == https://* || -n "${VE_INSECURE_TEST_ONLY:-}" ]] ||
  die "addr must be an https:// URL (set the VAULT_ADDR Actions variable)"
[[ -n "${VE_ROLE:-}" ]] || die "role is required"
[[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]] || die "no OIDC token: add 'permissions: id-token: write' to the job"
mount="${VE_MOUNT:-jwt-github}"
audience="${VE_AUDIENCE:-vault}"
first_delay="${VE_RETRY_DELAY:-5}"

body="$(mktemp)"
trap 'rm -f "$body"' EXIT

# request METHOD URL [curl args...]: the body in $body, the HTTP status echoed.
request() {
  local method="$1" url="$2" status delay="$first_delay" try
  shift 2
  for try in 1 2 3 4; do
    status="$(curl -sS -o "$body" -w '%{http_code}' -X "$method" --max-time 30 "$@" "$url" 2>/dev/null)" ||
      status=000
    if [[ "$status" != 5* && "$status" != 000 ]]; then
      echo "$status"
      return 0
    fi
    if ((try < 4)); then
      echo "vault-env: $url answered ${status/000/no connection}; retrying in ${delay}s" >&2
      sleep "$delay"
      delay=$((delay * 2))
    fi
  done
  echo "$status"
}

# Vault's error list, without values (they never contain secrets, but stay short).
vault_errors() { jq -r '(.errors // []) | join("; ")' "$body" 2>/dev/null | head -c 300; }

export_var() {
  local name="$1" value="$2" delim line
  while IFS= read -r line; do
    [[ -n "$line" ]] && echo "::add-mask::$line"
  done <<<"$value"
  delim="EOF_$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  printf '%s<<%s\n%s\n%s\n' "$name" "$delim" "$value" "$delim" >>"$GITHUB_ENV"
}

# 1. The job's OIDC token for audience "vault".
status="$(request GET "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${audience}" \
  -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}")"
[[ "$status" == 200 ]] || die "GitHub did not issue an OIDC token (HTTP $status)"
jwt="$(jq -r '.value // empty' "$body")"
[[ -n "$jwt" ]] || die "GitHub's OIDC answer has no token"
echo "::add-mask::$jwt"

# 2. Vault login.
status="$(request POST "$addr/v1/auth/$mount/login" -H 'Content-Type: application/json' \
  --data-binary "$(jq -cn --arg role "$VE_ROLE" --arg jwt "$jwt" '{role: $role, jwt: $jwt}')")"
[[ "$status" == 200 ]] || die "Vault login as role '$VE_ROLE' on $mount failed (HTTP $status: $(vault_errors))"
token="$(jq -r '.auth.client_token // empty' "$body")"
[[ -n "$token" ]] || die "Vault's login answer has no token"
echo "::add-mask::$token"
echo "vault-env: logged in as $VE_ROLE"

if [[ "${VE_EXPORT_TOKEN:-false}" == true ]]; then
  export_var VAULT_ADDR "$addr"
  export_var VAULT_TOKEN "$token"
  echo "vault-env: exported VAULT_ADDR, VAULT_TOKEN"
fi

# 3. The values. Each path is read once.
declare -A cache=()
count=0
while IFS= read -r raw; do
  line="${raw%%#*}"
  line="$(sed -E 's/^[[:space:]]+|[[:space:]]+$//g' <<<"$line")"
  [[ -n "$line" ]] || continue
  [[ "$line" == *"|"* ]] || die "bad line (want '<path> <key> | <ENV>'): $line"
  left="$(sed -E 's/[[:space:]]*\|.*$//' <<<"$line")"
  name="$(sed -E 's/^.*\|[[:space:]]*//' <<<"$line")"
  read -r path key extra <<<"$left"
  [[ -n "$path" && -n "$key" && -z "${extra:-}" ]] || die "bad line (want '<path> <key> | <ENV>'): $line"
  # Lower case too: OpenTofu's input variables are TF_VAR_<name>, with the variable's own spelling.
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "bad variable name '$name'"
  [[ "$path" =~ ^[A-Za-z0-9_./-]+$ && "$path" != *..* ]] || die "bad path '$path'"
  if [[ -z "${cache[$path]+x}" ]]; then
    status="$(request GET "$addr/v1/$path" -H "X-Vault-Token: $token")"
    [[ "$status" == 200 ]] || die "cannot read $path (HTTP $status: $(vault_errors))"
    # KV v2 nests the values under .data.data; other engines under .data.
    cache[$path]="$(jq -c 'if (.data.data | type) == "object" then .data.data else .data end' "$body")"
  fi
  value="$(jq -r --arg k "$key" 'if has($k) then .[$k] | if type == "string" then . else tojson end else empty end' \
    <<<"${cache[$path]}")"
  [[ -n "$value" ]] || die "$path has no value for '$key'"
  export_var "$name" "$value"
  echo "vault-env: exported $name"
  count=$((count + 1))
done <<<"${VE_SECRETS:-}"
echo "vault-env: $count value(s) from Vault"
