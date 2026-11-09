# Public settings (no secrets). Set your domain before the first plan.
vault_hostname  = "vault.example.com"
cloudflare_zone = "example.com"

# Flip to true only after `make vault-init` (see docs/runbooks/vault-init.md).
expose_public = false
