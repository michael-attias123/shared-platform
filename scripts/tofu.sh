#!/usr/bin/env bash
# Run OpenTofu for a stack with credentials from local files (never from the repo).
#   Usage: STACK=vault-server|vault-config|github tofu.sh plan | apply | check | output | <tofu cmd> [args]
#
#   plan   save a plan to review; nothing changes yet
#   apply  apply the saved plan (and only that plan)
#   check  offline, all stacks: fmt, validate, tests with mocked providers (same as CI)
#
# Shared with QuantumOps: the state bucket + S3 key (~/.config/qops/oci.env) and the state passphrase
# (~/.config/qops/tofu.env). Platform-only: ~/.config/platform/cloudflare.env, and your Vault token.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACKS=(vault-server vault-config github)
STACK_NAME="${STACK:-vault-server}"
STACK_DIR="$REPO_ROOT/$STACK_NAME"
PLAN_FILE="$STACK_DIR/.terraform/platform.tfplan"
QOPS_DIR="${QOPS_CONFIG_DIR:-$HOME/.config/qops}"
OCI_ENV="$QOPS_DIR/oci.env"
TOFU_ENV="$QOPS_DIR/tofu.env"
CF_ENV="$PLATFORM_CONFIG_DIR/cloudflare.env"
BACKEND_FILE="$PLATFORM_CONFIG_DIR/backend.hcl"
SSH_PUB="${PLATFORM_SSH_PUBLIC_KEY:-$HOME/.ssh/qops_oci.pub}"

tf() { tofu -chdir="$STACK_DIR" "$@"; }

offline_check() {
  local s
  tofu fmt -check -recursive "$REPO_ROOT"
  for s in "${STACKS[@]}"; do
    info "$s"
    tofu -chdir="$REPO_ROOT/$s" init -backend=false -input=false >/dev/null
    tofu -chdir="$REPO_ROOT/$s" validate
    tofu -chdir="$REPO_ROOT/$s" test
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
      [[ -f "$CF_ENV" ]] || die "missing $CF_ENV. Run: make cloudflare-login"
      [[ -f "$SSH_PUB" ]] || die "missing $SSH_PUB (admin SSH key)"
      set -a
      # shellcheck disable=SC1090
      source "$CF_ENV"
      set +a
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
    ;;
  *)
    ensure_init
    tf "$CMD" "$@"
    ;;
esac
