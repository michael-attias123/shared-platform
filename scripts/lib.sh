# shellcheck shell=bash
# Shared helpers for the P2 bootstrap scripts. Sourced, never executed.
#
# Conventions
# - Every script is idempotent: it looks before it creates, so reruns are safe.
# - QOPS_DRY_RUN=1 (or --dry-run) prints mutating commands instead of running them; reads still run.
# - Secrets go only to $QOPS_CONFIG_DIR/*.env (chmod 600, outside the repo) and are never printed.

set -euo pipefail

QOPS_CONFIG_DIR="${QOPS_CONFIG_DIR:-$HOME/.config/qops}"
QOPS_DRY_RUN="${QOPS_DRY_RUN:-0}"
OCI_CONFIG_FILE="${OCI_CONFIG_FILE:-$HOME/.oci/config}"
OCI_CLI_PROFILE="${OCI_CLI_PROFILE:-DEFAULT}"

# Tailnet traffic must never go through a corporate HTTP proxy: the proxy can't reach 100.x addresses and answers
# "Forbidden" (seen with kubectl behind a proxy in WSL). Go and curl both understand CIDRs in NO_PROXY.
QOPS_TAILNET_NO_PROXY="100.64.0.0/10,.ts.net"
case ",${NO_PROXY:-}," in
  *",100.64.0.0/10,"*) ;;
  *)
    export NO_PROXY="$QOPS_TAILNET_NO_PROXY${NO_PROXY:+,$NO_PROXY}"
    export no_proxy="$QOPS_TAILNET_NO_PROXY${no_proxy:+,$no_proxy}"
    ;;
esac

if [[ -t 1 ]]; then
  _c_info=$'\033[36m' _c_ok=$'\033[32m' _c_warn=$'\033[33m' _c_err=$'\033[31m' _c_off=$'\033[0m'
else
  _c_info='' _c_ok='' _c_warn='' _c_err='' _c_off=''
fi

info() { printf '%s==>%s %s\n' "$_c_info" "$_c_off" "$*"; }
ok() { printf '%s ok%s  %s\n' "$_c_ok" "$_c_off" "$*"; }
warn() { printf '%s !!%s  %s\n' "$_c_warn" "$_c_off" "$*" >&2; }
die() {
  printf '%serror:%s %s\n' "$_c_err" "$_c_off" "$*" >&2
  exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }
need() { have "$1" || die "'$1' is not installed. Run: make tools"; }

# Strip --dry-run from the arguments; the rest is returned in ARGS.
parse_common_args() {
  ARGS=()
  local a
  for a in "$@"; do
    case "$a" in
      --dry-run) QOPS_DRY_RUN=1 ;;
      *) ARGS+=("$a") ;;
    esac
  done
}

# Run a command that changes something; in dry-run mode only print it.
run() {
  if [[ "$QOPS_DRY_RUN" == "1" ]]; then
    printf '   [dry-run] %s\n' "$*" >&2
  else
    "$@"
  fi
}

# Read a key from the active profile of ~/.oci/config (empty if absent).
oci_cfg() {
  local key="$1"
  [[ -f "$OCI_CONFIG_FILE" ]] || return 0
  awk -v want="[$OCI_CLI_PROFILE]" -v key="$key" '
    /^[[:space:]]*\[/ { gsub(/[[:space:]]/, ""); in_profile = ($0 == want); next }
    in_profile {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (index(line, key "=") == 1 || index(line, key " =") == 1) {
        sub(/^[^=]*=[[:space:]]*/, "", line)
        sub(/[[:space:]]+$/, "", line)
        print line
        exit
      }
    }' "$OCI_CONFIG_FILE"
}

# Write a secrets file atomically with 0600 permissions. Content comes from stdin.
write_secret_file() {
  local path="$1" tmp
  if [[ "$QOPS_DRY_RUN" == "1" ]]; then
    cat >/dev/null
    printf '   [dry-run] write %s (0600)\n' "$path" >&2
    return
  fi
  mkdir -p "$(dirname "$path")"
  chmod 700 "$(dirname "$path")"
  tmp="$(mktemp "$path.XXXXXX")"
  chmod 600 "$tmp"
  cat >"$tmp"
  mv -f "$tmp" "$path"
}

# Read one KEY=value from an env file without sourcing it (empty if absent).
env_file_get() {
  local path="$1" key="$2"
  [[ -f "$path" ]] || return 0
  sed -n "s/^${key}=//p" "$path" | head -n1
}

os_name() {
  local os
  case "$(uname -s)" in
    Darwin) os="macOS $(sw_vers -productVersion 2>/dev/null || true)" ;;
    Linux)
      # shellcheck disable=SC1091
      os="$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-Linux}")"
      if grep -qi microsoft /proc/version 2>/dev/null; then os="$os (WSL2)"; fi
      ;;
    *) os="$(uname -s)" ;;
  esac
  printf '%s\n' "${os:-unknown}"
}

is_wsl() { grep -qi microsoft /proc/version 2>/dev/null; }

# The tailscale CLI: native, or the Windows one through WSL interop. Empty if neither exists.
ts_cmd() {
  if have tailscale; then
    printf 'tailscale\n'
  elif is_wsl && have tailscale.exe; then
    printf 'tailscale.exe\n'
  elif is_wsl && [[ -x "/mnt/c/Program Files/Tailscale/tailscale.exe" ]]; then
    # The Windows installer doesn't add Tailscale to PATH; use its default location.
    printf '%s\n' "/mnt/c/Program Files/Tailscale/tailscale.exe"
  fi
}

# --- shared-platform additions ---------------------------------------------------------------------------------------
PLATFORM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM_CONFIG_DIR="${PLATFORM_CONFIG_DIR:-$HOME/.config/platform}"
export PATH="$HOME/.local/bin:$PATH"

# https://<vault_hostname> from vault-server/settings.auto.tfvars (the public, committed setting).
vault_addr_from_settings() {
  local host
  host="$(sed -n "s/^vault_hostname *= *\"\(.*\)\"/\1/p" "$PLATFORM_ROOT/vault-server/settings.auto.tfvars")"
  [[ -n "$host" && "$host" != "vault.example.com" ]] || die "set vault_hostname in vault-server/settings.auto.tfvars first"
  printf "https://%s\n" "$host"
}
