#!/usr/bin/env bash
# One-time local setup for this repo.
#   tools            install the Vault CLI into ~/.local/bin (other tools come from QuantumOps' make tools-admin)
#   cloudflare-login hidden prompt for a Cloudflare API token (Zone DNS edit, one zone) -> ~/.config/platform/cloudflare.env
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VAULT_CLI_VERSION="2.2.1"

cmd_tools() {
  local have_ver arch zip dir
  for c in tofu oci jq curl ssh; do have "$c" || warn "'$c' missing (QuantumOps: make tools-admin)"; done
  have_ver="$(vault version 2>/dev/null | awk '{print $2}' | tr -d v || true)"
  if [[ "$have_ver" == "$VAULT_CLI_VERSION" ]]; then
    ok "vault $have_ver"
    return
  fi
  case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64 | arm64) arch=arm64 ;; *) die "unsupported CPU" ;; esac
  local os=linux base
  [[ "$(uname -s)" == "Darwin" ]] && os=darwin
  base="https://releases.hashicorp.com/vault/$VAULT_CLI_VERSION"
  info "installing vault $VAULT_CLI_VERSION ($os/$arch) into ~/.local/bin"
  dir="$(mktemp -d)"
  zip="vault_${VAULT_CLI_VERSION}_${os}_${arch}.zip"
  curl -fsSL "$base/$zip" -o "$dir/$zip"
  (cd "$dir" && curl -fsSL "$base/vault_${VAULT_CLI_VERSION}_SHA256SUMS" | grep " $zip\$" | sha256sum --check --quiet)
  python3 -m zipfile -e "$dir/$zip" "$dir/out"
  mkdir -p "$HOME/.local/bin"
  install -m 0755 "$dir/out/vault" "$HOME/.local/bin/vault"
  rm -rf "$dir"
  ok "vault $(vault version | awk '{print $2}')"
  have qrencode || warn "optional: sudo apt install qrencode (shows the MFA QR code in the terminal)"
}

cmd_cloudflare_login() {
  local file="$PLATFORM_CONFIG_DIR/cloudflare.env" token
  if [[ -n "$(env_file_get "$file" CLOUDFLARE_API_TOKEN)" ]]; then
    ok "token already saved in $file (delete the file to replace it)"
    return
  fi
  cat <<'EOF'
Create it at https://dash.cloudflare.com/profile/api-tokens -> Create Token -> "Edit zone DNS" template,
Zone Resources: Include -> Specific zone -> your domain. Paste it below (hidden). Never paste it in chat.
EOF
  read -r -s -p "Cloudflare API token: " token
  echo
  printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl -fsS -K - https://api.cloudflare.com/client/v4/user/tokens/verify | jq -e '.success' >/dev/null ||
    die "Cloudflare rejected the token"
  printf '# Cloudflare token (DNS edit, one zone) for shared-platform. Secret.\nCLOUDFLARE_API_TOKEN=%s\n' "$token" |
    write_secret_file "$file"
  ok "saved $file"
}

case "${1:-}" in
  tools) cmd_tools ;;
  cloudflare-login) cmd_cloudflare_login ;;
  *) die "usage: setup.sh tools | cloudflare-login" ;;
esac
