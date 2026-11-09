#!/usr/bin/env bash
# Admin shell on the Vault VM through OCI Bastion (port 22 is never open to the internet).
#   Usage: bastion.sh ssh [command...] | status
#
# Opens (or reuses) a short-lived port-forwarding session to the VM's private IP, then SSHes through it with
# your admin key. Needs outbound TCP 22 to host.bastion.<region>.oci.oraclecloud.com; if your network blocks
# it, use OCI Cloud Shell in the browser (docs/runbooks/bastion.md).
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need oci
need jq
need ssh
SSH_KEY="${PLATFORM_SSH_KEY:-$HOME/.ssh/qops_oci}"
SESSION_FILE="$PLATFORM_CONFIG_DIR/bastion-session"
[[ -f "$SSH_KEY" && -f "$SSH_KEY.pub" ]] || die "missing admin SSH key $SSH_KEY"

outputs="$(STACK=vault-server bash "$PLATFORM_ROOT/scripts/tofu.sh" output -json)" || die "can't read vault-server outputs"
BASTION_ID="$(jq -r .bastion_id.value <<<"$outputs")"
TARGET_IP="$(jq -r .private_ip.value <<<"$outputs")"
REGION="$(oci_cfg region)"
ocij() { oci --profile "$OCI_CLI_PROFILE" --output json "$@"; }

session_state() { ocij bastion session get --session-id "$1" 2>/dev/null | jq -r '.data."lifecycle-state" // empty'; }

session_id() {
  local id state
  if [[ -s "$SESSION_FILE" ]]; then
    id="$(cat "$SESSION_FILE")"
    [[ "$(session_state "$id")" == "ACTIVE" ]] && { printf '%s\n' "$id"; return; }
  fi
  info "opening a Bastion session (valid 3 hours)" >&2
  id="$(ocij bastion session create-port-forwarding --bastion-id "$BASTION_ID" \
    --ssh-public-key-file "$SSH_KEY.pub" --target-private-ip "$TARGET_IP" --target-port 22 \
    --session-ttl 10800 --display-name "admin-$(date +%s)" | jq -r '.data.id')"
  [[ -n "$id" && "$id" != "null" ]] || die "Bastion session was not created"
  for _ in $(seq 1 40); do
    state="$(session_state "$id")"
    [[ "$state" == "ACTIVE" ]] && break
    sleep 3
  done
  [[ "$state" == "ACTIVE" ]] || die "Bastion session stuck in state '$state'"
  mkdir -p "$PLATFORM_CONFIG_DIR"
  printf '%s\n' "$id" >"$SESSION_FILE"
  printf '%s\n' "$id"
}

SID="$(session_id)"
PROXY="ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -W %h:%p -p 22 $SID@host.bastion.$REGION.oci.oraclecloud.com"
SSH=(ssh -i "$SSH_KEY" -o "ProxyCommand=$PROXY" -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR "ubuntu@$TARGET_IP")

CMD="${1:-ssh}"
shift || true
case "$CMD" in
  ssh) exec "${SSH[@]}" "$@" ;;
  status)
    "${SSH[@]}" 'cloud-init status || true; tail -n 15 /var/log/platform-bootstrap.log 2>/dev/null || echo "(no bootstrap log yet)"'
    ;;
  *) die "unknown command: $CMD (ssh | status)" ;;
esac
