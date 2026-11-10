#!/usr/bin/env bash
# Run OpenTofu for a stack with credentials from local files (never from the repo).
#   Usage: STACK=vault-server|vault-config|github tofu.sh plan | apply | check | output | <tofu cmd> [args]
#
#   plan   save a plan to review; nothing changes yet
#   apply  apply the saved plan (and only that plan)
#   check  offline, all stacks: fmt, validate, tests with mocked providers (same as CI)
#
# Shared with QuantumOps: the state bucket + S3 key (~/.config/qops/oci.env) and the state passphrase
# (~/.config/qops/tofu.env). Platform-only: your Vault token (make vault-login).
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACKS=(vault-server vault-config github)
STACK_NAME="${STACK:-vault-server}"
STACK_DIR="$REPO_ROOT/stacks/$STACK_NAME"
PLAN_FILE="$STACK_DIR/.terraform/platform.tfplan"
QOPS_DIR="${QOPS_CONFIG_DIR:-$HOME/.config/qops}"
OCI_ENV="$QOPS_DIR/oci.env"
TOFU_ENV="$QOPS_DIR/tofu.env"
BACKEND_FILE="$PLATFORM_CONFIG_DIR/backend.hcl"
SSH_PUB="${PLATFORM_SSH_PUBLIC_KEY:-$HOME/.ssh/qops_oci.pub}"

tf() { tofu -chdir="$STACK_DIR" "$@"; }

offline_check() {
  local dir dirs=()
  tofu fmt -check -recursive "$REPO_ROOT"
  # Every stack, then every shared module.
  dirs=("${STACKS[@]/#/stacks/}")
  while IFS= read -r dir; do dirs+=("$dir"); done < <(cd "$REPO_ROOT" && find modules -mindepth 1 -maxdepth 1 -type d | sort)
  for dir in "${dirs[@]}"; do
    info "$dir"
    tofu -chdir="$REPO_ROOT/$dir" init -backend=false -input=false >/dev/null
    tofu -chdir="$REPO_ROOT/$dir" validate
    if [[ -d "$REPO_ROOT/$dir/tests" ]]; then tofu -chdir="$REPO_ROOT/$dir" test; fi
  done
}

github_token() {
  local gh
  for gh in gh gh.exe; do
    if have "$gh" && "$gh" auth token 2>/dev/null | tr -d '\r'; then return; fi
  done
  return 1
}

load_common() {
  [[ -f "$OCI_ENV" ]] || die "missing $OCI_ENV (state bucket credentials). Run QuantumOps' make oci-bootstrap"
  [[ -f "$TOFU_ENV" ]] || die "missing $TOFU_ENV (state passphrase). Restore it from your password manager"
  set -a
  # shellcheck disable=SC1090
  source "$OCI_ENV"
  # shellcheck disable=SC1090
  source "$TOFU_ENV"
  set +a
  mkdir -p "$PLATFORM_CONFIG_DIR"
  chmod 700 "$PLATFORM_CONFIG_DIR"
  cat >"$BACKEND_FILE" <<EOF
bucket    = "$QOPS_STATE_BUCKET"
region    = "$QOPS_OCI_REGION"
endpoints = { s3 = "https://$QOPS_OCI_NAMESPACE.compat.objectstorage.$QOPS_OCI_REGION.oci.customer-oci.com" }
EOF
}

load_stack() {
  case "$STACK_NAME" in
    vault-server)
      [[ -f "$SSH_PUB" ]] || die "missing $SSH_PUB (admin SSH key)"
      export TF_VAR_region="$QOPS_OCI_REGION" TF_VAR_oci_profile="$OCI_CLI_PROFILE"
      TF_VAR_tenancy_ocid="$(oci_cfg tenancy)"
      TF_VAR_ssh_public_key="$(cat "$SSH_PUB")"
      export TF_VAR_tenancy_ocid TF_VAR_ssh_public_key
      ;;
    vault-config)
      export VAULT_ADDR="${VAULT_ADDR:-$(vault_addr_from_settings)}"
      if [[ -z "${VAULT_TOKEN:-}" ]]; then
        [[ -s "$HOME/.vault-token" ]] || die "no Vault token. Run: make vault-login"
        VAULT_TOKEN="$(cat "$HOME/.vault-token")"
        export VAULT_TOKEN
      fi
      ;;
    github)
      [[ -n "${GITHUB_TOKEN:-}" ]] || GITHUB_TOKEN="$(github_token)" || die "no GitHub token. Run: gh auth login"
      export GITHUB_TOKEN
      TF_VAR_vault_addr="$(vault_addr_from_settings)"
      export TF_VAR_vault_addr
      ;;
  esac
}

init() { tf init -input=false -reconfigure -backend-config="$BACKEND_FILE" "$@"; }
ensure_init() { [[ -f "$STACK_DIR/.terraform/terraform.tfstate" ]] || init >/dev/null; }

need tofu
need jq
[[ " ${STACKS[*]} " == *" $STACK_NAME "* ]] || die "unknown STACK '$STACK_NAME' (one of: ${STACKS[*]})"
CMD="${1:-plan}"
shift || true
if [[ "$CMD" == "check" ]]; then
  offline_check
  exit
fi

load_common
load_stack
case "$CMD" in
  init) init "$@" ;;
  plan)
    ensure_init
    tf plan -input=false -out="$PLAN_FILE" "$@"
    info "review the plan above; if it's right: make apply STACK=$STACK_NAME"
    ;;
  apply)
    [[ -f "$PLAN_FILE" ]] || die "no saved plan. Run: make plan STACK=$STACK_NAME (and review it)"
    ensure_init
    tf apply -input=false "$PLAN_FILE"
    rm -f "$PLAN_FILE"
    # The public name follows the reserved IP; refresh the cached address after server changes.
    if [[ "$STACK_NAME" == "vault-server" ]]; then rm -f "$PLATFORM_CONFIG_DIR/vault_addr"; fi
    ;;
  *)
    ensure_init
    tf "$CMD" "$@"
    ;;
esac
