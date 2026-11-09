#!/usr/bin/env bash
# Vault admin tasks. Secrets go to ~/.config/platform (0600) or straight into Vault; none is echoed by these scripts
# except the TOTP enrollment QR code, which is meant for your eyes (scan it, then clear the terminal).
#
#   init            vault operator init over Bastion (refuses if already initialized) -> vault-init.json
#   with-root CMD   run CMD (e.g. a make target) with the root token from vault-init.json (first setup only)
#   admin           create/rotate the userpass "admin" user (hidden password prompt)
#   login           vault login as admin (password + TOTP once MFA is enforced) -> ~/.vault-token
#   mfa-enroll      show the TOTP QR code for the admin entity (once)
#   revoke-root     revoke the root token and delete it from vault-init.json (keeps the recovery keys)
#   snapshot-setup  install a periodic snapshot-only token on the VM and run one snapshot
#   approle-secret  PROJECT=<name>: new role/secret ID -> ~/.config/platform/approle-<name>.env
#   health          public health check
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INIT_FILE="$PLATFORM_CONFIG_DIR/vault-init.json"
BASTION=(bash "$PLATFORM_ROOT/scripts/bastion.sh" ssh)
LOCAL_VAULT='VAULT_ADDR=http://127.0.0.1:8200 vault'

need jq
need vault
VAULT_ADDR="${VAULT_ADDR:-$(vault_addr_from_settings)}"
export VAULT_ADDR

config_output() { STACK=vault-config bash "$PLATFORM_ROOT/scripts/tofu.sh" output -raw "$1"; }

cmd_init() {
  local status
  status="$("${BASTION[@]}" "$LOCAL_VAULT status -format=json" || true)"
  [[ -n "$status" ]] || die "can't reach Vault on the VM. Check: make vault-bootstrap-status"
  if [[ "$(jq -r .initialized <<<"$status")" == "true" ]]; then
    ok "Vault is already initialized (seal: $(jq -r .type <<<"$status"), sealed: $(jq -r .sealed <<<"$status"))"
    return
  fi
  info "initializing Vault (auto-unseal: 5 recovery keys, threshold 3) -> $INIT_FILE"
  "${BASTION[@]}" "$LOCAL_VAULT operator init -format=json -recovery-shares=5 -recovery-threshold=3" |
    write_secret_file "$INIT_FILE"
  jq -e '.root_token and (.recovery_keys_b64 | length == 5)' "$INIT_FILE" >/dev/null || die "init output looks wrong; see $INIT_FILE"
  ok "initialized. NOW copy $INIT_FILE into your password manager (recovery keys + root token)."
  "${BASTION[@]}" "$LOCAL_VAULT status" | grep -E 'Initialized|Sealed|Seal Type' || true
}

root_token() {
  jq -er '.root_token // empty' "$INIT_FILE" 2>/dev/null || die "no root token in $INIT_FILE (already revoked?)"
}

cmd_with_root() {
  VAULT_TOKEN="$(root_token)"
  export VAULT_TOKEN
  "$@"
}

token_or_root() {
  if [[ -n "${VAULT_TOKEN:-}" ]]; then return; fi
  if [[ -s "$HOME/.vault-token" ]]; then VAULT_TOKEN="$(cat "$HOME/.vault-token")"; else VAULT_TOKEN="$(root_token)"; fi
  export VAULT_TOKEN
}

cmd_admin() {
  token_or_root
  local p1 p2
  read -r -s -p "New Vault admin password (16+ chars): " p1
  echo
  read -r -s -p "Again: " p2
  echo
  [[ "$p1" == "$p2" ]] || die "passwords differ"
  ((${#p1} >= 16)) || die "use at least 16 characters"
  printf '%s' "$p1" | vault write auth/userpass/users/admin password=- \
    token_policies=admin token_ttl=1h token_max_ttl=8h >/dev/null
  unset p1 p2
  ok "admin user set. Save the password in your password manager, then: make vault-login"
}

cmd_login() {
  vault login -method=userpass username=admin >/dev/null
  ok "logged in; token in ~/.vault-token (expires in 1h)"
}

cmd_mfa_enroll() {
  token_or_root
  local method entity url
  method="$(config_output admin_totp_method_id)"
  entity="$(config_output admin_entity_id)"
  url="$(vault write -format=json identity/mfa/method/totp/admin-generate method_id="$method" entity_id="$entity" |
    jq -r '.data.url // empty')"
  [[ -n "$url" ]] || die "no TOTP secret returned (already enrolled? destroy it first: vault write identity/mfa/method/totp/admin-destroy ...)"
  if have qrencode; then qrencode -t ANSIUTF8 "$url"; else printf '%s\n' "$url"; fi
  warn "scan this in your authenticator app, then clear the terminal. Next: set enforce_admin_mfa = true in vault-config"
}

cmd_revoke_root() {
  local token
  token="$(root_token)"
  VAULT_TOKEN="$token" vault token revoke -self
  jq 'del(.root_token)' "$INIT_FILE" | write_secret_file "$INIT_FILE"
  ok "root token revoked and removed from $INIT_FILE (make a new one only with the recovery keys: vault operator generate-root)"
}

cmd_snapshot_setup() {
  token_or_root
  vault token create -policy=snapshot -period=768h -orphan -display-name=vault-snapshot -field=token |
    "${BASTION[@]}" 'sudo install -m 0600 -o root -g root /dev/stdin /etc/vault.d/snapshot.token'
  "${BASTION[@]}" 'sudo systemctl start vault-snapshot.service && sudo journalctl -u vault-snapshot.service -n 3 --no-pager'
  ok "snapshot token installed; the timer runs daily at ~02:30 UTC"
}

cmd_approle_secret() {
  local project="${PROJECT:-}" role_id secret_id
  [[ -n "$project" ]] || die "usage: make vault-approle-secret PROJECT=<name>"
  token_or_root
  role_id="$(vault read -field=role_id "auth/approle/role/$project/role-id")"
  secret_id="$(vault write -f -field=secret_id "auth/approle/role/$project/secret-id")"
  printf 'VAULT_ADDR=%s\nVAULT_ROLE_ID=%s\nVAULT_SECRET_ID=%s\n' "$VAULT_ADDR" "$role_id" "$secret_id" |
    write_secret_file "$PLATFORM_CONFIG_DIR/approle-$project.env"
  ok "saved $PLATFORM_CONFIG_DIR/approle-$project.env (secret ID valid 90 days); copy it to the VM that needs it"
}

cmd_health() {
  curl -fsS --max-time 15 "$VAULT_ADDR/v1/sys/health" | jq '{initialized, sealed, version, cluster_name}'
}

CMD="${1:-health}"
shift || true
case "$CMD" in
  init) cmd_init ;;
  with-root) cmd_with_root "$@" ;;
  admin) cmd_admin ;;
  login) cmd_login ;;
  mfa-enroll) cmd_mfa_enroll ;;
  revoke-root) cmd_revoke_root ;;
  snapshot-setup) cmd_snapshot_setup ;;
  approle-secret) cmd_approle_secret ;;
  health) cmd_health ;;
  *) die "unknown command: $CMD" ;;
esac
