#!/usr/bin/env bash
# One-time local setup for this repo.
#   tools            install the Vault CLI and age into ~/.local/bin (other tools come from QuantumOps' make tools-admin)
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VAULT_CLI_VERSION="2.2.1"
AGE_VERSION="v1.3.2"
declare -A AGE_SHA256=(
  [linux-amd64]=cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10
  [linux-arm64]=6b8dc4333c53a5a57c9e5834e3a48f92605d7154014cd07269ff3327db5d37f4
  [darwin-arm64]=e2020b073c44f692685a24d6abc378817eb81ffaaf49fd0531ef8565f767f2f5
)

install_age() {
  if have age; then
    ok "age $(age --version)"
    return
  fi
  local os=linux arch dir
  [[ "$(uname -s)" == "Darwin" ]] && os=darwin
  case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64 | arm64) arch=arm64 ;; *) die "unsupported CPU" ;; esac
  [[ -n "${AGE_SHA256[$os-$arch]:-}" ]] || die "no pinned age build for $os-$arch"
  info "installing age $AGE_VERSION ($os/$arch) into ~/.local/bin"
  dir="$(mktemp -d)"
  curl -fsSL "https://github.com/FiloSottile/age/releases/download/$AGE_VERSION/age-$AGE_VERSION-$os-$arch.tar.gz" -o "$dir/age.tgz"
  echo "${AGE_SHA256[$os-$arch]}  $dir/age.tgz" | sha256sum --check --quiet
  tar -xzf "$dir/age.tgz" -C "$dir"
  mkdir -p "$HOME/.local/bin"
  install -m 0755 "$dir/age/age" "$HOME/.local/bin/age"
  rm -rf "$dir"
  ok "age $(age --version)"
}

cmd_tools() {
  local have_ver arch zip dir
  for c in tofu oci jq curl ssh; do have "$c" || warn "'$c' missing (QuantumOps: make tools-admin)"; done
  install_age
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

case "${1:-}" in
  tools) cmd_tools ;;
  *) die "usage: setup.sh tools" ;;
esac
