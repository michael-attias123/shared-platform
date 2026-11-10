#!/usr/bin/env bash
# Fills a project's Vault secrets from its declaration, from your laptop, as the admin (make vault-login).
#   Usage: seed.sh PROJECT [--from-sops FILE] [--from-env FILE]... [--check]
#
# PROJECT is a file in projects/: house-manager -> kv/house-manager/<path>, _shared -> kv/shared/<path>,
# _platform -> kv/platform/<path>. Its vault.secrets lists the keys per path. For each key, in order:
#   1. already in Vault        kept as it is (never overwritten; change a value with vault kv patch)
#   2. --from-sops FILE        that key of the decrypted SOPS file (house-manager's infra/secrets.enc.yaml)
#   3. --from-env FILE         vault.from_env.<path>.<key> names a variable in FILE (KEY=VALUE lines)
#   4. otherwise               a hidden prompt; type @/path/to/file to read a file, or nothing to skip
# --check reads only, and lists what is present and what is missing.
#
# Values never reach the command line, the terminal or the repo: they go through files in
# ~/.config/platform (0700) that are deleted at exit. Prints key names and their source only.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT="${1:-}"
[[ -n "$PROJECT" && "$PROJECT" != -* ]] || die "usage: seed.sh PROJECT [--from-sops FILE] [--from-env FILE]... [--check]"
shift
SOPS_FILE=""
ENV_FILES=()
CHECK=0
while (($#)); do
  case "$1" in
    --from-sops) SOPS_FILE="${2:?--from-sops needs a file}"; shift 2 ;;
    --from-env) ENV_FILES+=("${2:?--from-env needs a file}"); shift 2 ;;
    --check) CHECK=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

SPEC_FILE="$PLATFORM_ROOT/projects/$PROJECT.yaml"
[[ -f "$SPEC_FILE" ]] || die "no $SPEC_FILE"
case "$PROJECT" in
  _shared) PREFIX="shared" ;;
  _platform) PREFIX="platform" ;;
  _*) die "unknown special file $PROJECT" ;;
  *) PREFIX="$PROJECT" ;;
esac

need jq
need vault
need tofu
VAULT_ADDR="${VAULT_ADDR:-$(vault_addr_from_settings)}"
export VAULT_ADDR
vault token lookup >/dev/null 2>&1 || die "not logged in to $VAULT_ADDR. Run: make vault-login"

mkdir -p "$PLATFORM_CONFIG_DIR"
chmod 700 "$PLATFORM_CONFIG_DIR"
WORK="$(mktemp -d "$PLATFORM_CONFIG_DIR/seed.XXXXXX")"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

# The YAML, as JSON. tofu reads YAML without another tool; console prints the JSON as an HCL string.
spec="$(cd "$WORK" && printf 'jsonencode(yamldecode(file("%s")))\n' "$SPEC_FILE" | tofu console 2>/dev/null | jq -r 'fromjson | tojson')" ||
  die "cannot read $SPEC_FILE"
jq -e '.vault.secrets | type == "object"' <<<"$spec" >/dev/null || die "$SPEC_FILE has no vault.secrets"

# Sources, decrypted into files only.
if [[ -n "$SOPS_FILE" ]]; then
  need sops
  sops -d --output-type json "$SOPS_FILE" >"$WORK/sops.json" || die "sops could not decrypt $SOPS_FILE"
else
  echo '{}' >"$WORK/sops.json"
fi
env_value() { # NAME -> value from the first env file that has it
  local f
  for f in "${ENV_FILES[@]+"${ENV_FILES[@]}"}"; do
    [[ -f "$f" ]] || die "no $f"
    if grep -q "^$1=" "$f"; then
      env_file_get "$f" "$1"
      return
    fi
  done
}

missing=0
for path in $(jq -r '.vault.secrets | keys[]' <<<"$spec"); do
  kv="$PREFIX/$path"
  if ! vault kv get -mount=kv -format=json "$kv" 2>/dev/null | jq '.data.data // {}' >"$WORK/current.json"; then
    echo '{}' >"$WORK/current.json"
  fi
  cp "$WORK/current.json" "$WORK/new.json"
  changed=0
  info "kv/$kv"
  for key in $(jq -r --arg p "$path" '.vault.secrets[$p][]' <<<"$spec"); do
    if jq -e --arg k "$key" '(.[$k] // "") != ""' "$WORK/current.json" >/dev/null; then
      ok "  $key: in Vault"
      continue
    fi
    if ((CHECK)); then
      warn "  $key: missing"
      missing=$((missing + 1))
      continue
    fi
    source_name=""
    if jq -e --arg k "$key" '(.[$k] // "") != ""' "$WORK/sops.json" >/dev/null; then
      jq -j --arg k "$key" '.[$k] | tostring' "$WORK/sops.json" >"$WORK/value"
      source_name="sops"
    else
      envname="$(jq -r --arg p "$path" --arg k "$key" '.vault.from_env[$p][$k] // empty' <<<"$spec")"
      if [[ -n "$envname" ]] && value="$(env_value "$envname")" && [[ -n "$value" ]]; then
        printf '%s' "$value" >"$WORK/value"
        source_name="env $envname"
      else
        value=""
        # No terminal (a script, a test): nothing is typed, so the key is skipped.
        if { printf '  value for kv/%s %s (hidden; @file reads a file; empty skips): ' "$kv" "$key" >/dev/tty; } 2>/dev/null; then
          IFS= read -rs value </dev/tty || value=""
          printf '\n' >/dev/tty
        fi
        if [[ "$value" == @* ]]; then
          [[ -f "${value#@}" ]] || die "no file ${value#@}"
          cp "${value#@}" "$WORK/value"
          source_name="file"
        elif [[ -n "$value" ]]; then
          printf '%s' "$value" >"$WORK/value"
          source_name="typed"
        fi
        value=""
      fi
    fi
    if [[ -z "$source_name" ]]; then
      warn "  $key: skipped (still missing)"
      missing=$((missing + 1))
      continue
    fi
    jq --arg k "$key" --rawfile v "$WORK/value" '.[$k] = $v' "$WORK/new.json" >"$WORK/next.json"
    mv "$WORK/next.json" "$WORK/new.json"
    rm -f "$WORK/value"
    changed=1
    ok "  $key: added ($source_name)"
  done
  if ((changed)); then
    vault kv put -mount=kv "$kv" @"$WORK/new.json" >/dev/null || die "could not write kv/$kv"
    ok "  written (new version of kv/$kv)"
  fi
done

if ((missing > 0)); then
  warn "$missing key(s) still missing. Run this again once you have them."
  ((CHECK)) && exit 1
fi
ok "done"
