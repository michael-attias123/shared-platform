# First setup

Run from the admin computer (WSL Ubuntu), in this repo. It reuses QuantumOps' setup: OCI login, the state bucket
and passphrase (`~/.config/qops/`), and the admin SSH key `~/.ssh/qops_oci`.

## 1. Before the first plan
```bash
make tools              # Vault CLI into ~/.local/bin
make cloudflare-login   # token: "Edit zone DNS" template, limited to your domain
```
Set your domain in [`vault-server/settings.auto.tfvars`](../../vault-server/settings.auto.tfvars)
(`vault_hostname`, `cloudflare_zone`) in a PR. Leave `expose_public = false`.

## 2. Server (not public yet)
```bash
make plan STACK=vault-server     # review: E2.1.Micro, only SSH-from-VCN ingress, DNS record proxied=false
make apply STACK=vault-server
make vault-bootstrap-status      # via Bastion; wait for "bootstrap done" (~5-10 min)
```

## 3. Initialize (while nothing can reach it from outside)
```bash
make vault-init
```
This writes `~/.config/platform/vault-init.json` (5 recovery keys + root token). **Copy it into your password
manager now.** With auto-unseal, the recovery keys are only needed to make a new root token or for disaster
recovery. Vault unseals itself after reboots.

## 4. Open it, configure it, lock it down
1. Set `expose_public = true` in `settings.auto.tfvars` (PR). Then `make plan STACK=vault-server` and
   `make apply STACK=vault-server`. Wait about a minute for Caddy's certificate, then `make vault-health`.
2. `make config-plan-root`, then `make config-apply-root`. This applies `vault-config` with the root token: KV,
   audit, rate limits, auth methods, projects.
3. `make vault-admin`: choose the admin password (hidden prompt) and save it in your password manager.
4. `make vault-login`.
5. `make vault-mfa-enroll`: scan the QR code with your authenticator app.
6. Set `enforce_admin_mfa = true` in `vault-config/settings.auto.tfvars` (PR). Then
   `make plan STACK=vault-config` and `make apply STACK=vault-config`. Log in again; it now asks for the code.
7. `make vault-revoke-root`.
8. `make vault-snapshot-setup`.
9. `make plan STACK=github` and `make apply STACK=github` (branch rules, `VAULT_ADDR` for Actions). Then run the
   **vault-smoke** workflow (Actions tab → Run workflow).

## Check
- `make vault-health` → `initialized: true`, `sealed: false`.
- In the OCI console, the `platform-vault` security list has exactly two rules: 443 from anywhere, 22 from
  `10.30.0.0/16`.
- A login without the TOTP code fails. `VAULT_TOKEN=<old root> vault token lookup` fails.
