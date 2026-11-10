#!/usr/bin/env bash
# Run commands on the Vault VM through OCI Run Command: HTTPS to the OCI API only, so it works behind proxies
# that block SSH. Command text and output are stored by OCI, so never send or print secrets in clear: scripts/vault.sh
# encrypts them with age (to your SSH key for output, to the VM's host key for input).
#   Usage: vm.sh exec <<'EOF' ... EOF     run a bash script (stdin) as ocarun (sudo allowed); prints its output
#          vm.sh status                    first-boot progress
#          vm.sh console                   serial console tail (works even before the agent is up)
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need oci
need jq
ocij() { oci --profile "$OCI_CLI_PROFILE" --output json "$@"; }

INSTANCE_ID="$(STACK=vault-server bash "$PLATFORM_ROOT/scripts/tofu.sh" output -raw instance_id)" ||
  die "can't read the instance ID (vault-server applied?)"
COMPARTMENT_ID="$(ocij compute instance get --instance-id "$INSTANCE_ID" | jq -r '.data."compartment-id"')"

run_script() {
  local script="$1" timeout="${2:-900}" content target cmd_id state result
  content="$(jq -n --arg t "$script" '{source: {sourceType: "TEXT", text: $t}, output: {outputType: "TEXT"}}')"
  target="$(jq -n --arg i "$INSTANCE_ID" '{instanceId: $i}')"
  cmd_id="$(ocij instance-agent command create -c "$COMPARTMENT_ID" --display-name "platform-$(date +%s)" \
    --timeout-in-seconds "$timeout" --content "$content" --target "$target" | jq -r '.data.id')"
  [[ -n "$cmd_id" && "$cmd_id" != "null" ]] || die "Run Command was not created"
  for _ in $(seq 1 $(((timeout + 600) / 3))); do  # the agent may take minutes to pick a command up
    result="$(ocij instance-agent command-execution get --command-id "$cmd_id" --instance-id "$INSTANCE_ID" 2>/dev/null || true)"
    state="$(jq -r '.data."lifecycle-state" // empty' <<<"$result")"
    case "$state" in SUCCEEDED | FAILED | TIMED_OUT | CANCELED) break ;; esac
    sleep 3
  done
  jq -r '.data.content.text // ""' <<<"$result"
  [[ "$state" == "SUCCEEDED" && "$(jq -r '.data.content."exit-code" // 1' <<<"$result")" == "0" ]] ||
    die "command ended with state '${state:-unknown}' (exit $(jq -r '.data.content."exit-code" // "?"' <<<"$result"))"
}

console_tail() {
  local hid file
  file="$(mktemp)"
  hid="$(ocij compute console-history capture --instance-id "$INSTANCE_ID" --wait-for-state SUCCEEDED | jq -r '.data.id')"
  oci --profile "$OCI_CLI_PROFILE" compute console-history get-content --instance-console-history-id "$hid" \
    --length 1000000 --file "$file" >/dev/null
  oci --profile "$OCI_CLI_PROFILE" compute console-history delete --instance-console-history-id "$hid" --force >/dev/null
  grep -aE 'bootstrap|public name|vault status|Initialized|Sealed|Seal Type|Cloud-init .* finished|error|Error' "$file" | tail -n 30
  rm -f "$file"
}

CMD="${1:-status}"
shift || true
case "$CMD" in
  exec) run_script "$(cat)" "${1:-900}" ;;
  status) run_script 'cloud-init status || true; tail -n 15 /var/log/platform-bootstrap.log 2>/dev/null || echo "(no bootstrap log yet)"' 120 ;;
  console) console_tail ;;
  *) die "unknown command: $CMD (exec | status | console)" ;;
esac
