# First setup

Run from the admin computer (WSL Ubuntu), in this repo. It reuses QuantumOps' setup: OCI login, the state bucket
and passphrase (`~/.config/qops/`), and the admin SSH key `~/.ssh/qops_oci`.

## 1. Before the first plan
```bash
make tools              # Vault CLI into ~/.local/bin
```
There's no domain to set up. Vault's name is `vault.<public-ip-with-dashes>.sslip.io`. [sslip.io](https://sslip.io)
is free public DNS that answers such names with the embedded IP. The IP is reserved, so the name never changes.
Leave `expose_public = false` in [`vault-server/settings.auto.tfvars`](../../vault-server/settings.auto.tfvars).

## 2. Server (not public yet)
```bash
make plan STACK=vault-server     # review: E2.1.Micro, only SSH-from-VCN ingress, reserved IP
make apply STACK=vault-server
make vault-bootstrap-status      # via Bastion; wait for "bootstrap done" (~5-10 min)
```

## 3. Initialize (while nothing can reach it from outside)
This runs over OCI Run Command (HTTPS), which also works behind proxies that block SSH. The VM encrypts the
result to your SSH key with `age` and keeps it in a root-only file. The file is fetched in chunks, because Run
Command returns at most about 1 KB of output, and it's deleted only after it decrypts on your computer.
```bash
make vault-init
```
This writes `~/.config/platform/vault-init.json` (5 recovery keys + root token). **Copy it into your password
manager now.** With auto-unseal, the recovery keys are only needed to make a new root token or for disaster
recovery. Vault unseals itself after reboots.

## 4. Open it, configure it, lock it down
1. Set `expose_public = true` in `settings.auto.tfvars` (PR). Then `make plan STACK=vault-server` and
   `make apply STACK=vault-server`. Then run `make vault-tls-retry`: Caddy already tried to get the certificate
   while 443 was closed and is backing off, so the restart makes it ask again now. Finally `make vault-health`.
2. `make config-plan-root`, then `make config-apply-root`. This applies `vault-config` with the root token: KV,
   audit, rate limits, auth methods, projects.
3. `make vault-admin`: sets a random 32-character admin password and puts it on your clipboard (never shown).
   Paste it into your password manager. To type your own instead: `PROMPT=1 make vault-admin`.
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
