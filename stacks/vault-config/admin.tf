# You: one userpass login with TOTP MFA. Machines never use passwords (see auth.tf).

resource "vault_auth_backend" "userpass" {
  type        = "userpass"
  path        = "userpass"
  description = "Human admin login (with TOTP MFA)"

  tune {
    default_lease_ttl = "1h"
    max_lease_ttl     = "8h"
  }
}

# The user itself (username "admin", policy "admin") is written by `make vault-admin`, which reads the password
# from a hidden prompt. That keeps the password out of OpenTofu entirely (the provider would need it on every plan).
locals {
  admin_username = "admin"
}

resource "vault_identity_entity" "admin" {
  name     = "admin"
  metadata = { role = "platform-admin" }
}

resource "vault_identity_entity_alias" "admin" {
  name           = local.admin_username
  mount_accessor = vault_auth_backend.userpass.accessor
  canonical_id   = vault_identity_entity.admin.id
}

resource "vault_identity_mfa_totp" "admin" {
  issuer                  = "shared-platform Vault"
  period                  = 30
  digits                  = 6
  algorithm               = "SHA256"
  max_validation_attempts = 5
}

resource "vault_identity_mfa_login_enforcement" "admin" {
  count                 = var.enforce_admin_mfa ? 1 : 0
  name                  = "admin-totp"
  mfa_method_ids        = [vault_identity_mfa_totp.admin.method_id]
  auth_method_accessors = [vault_auth_backend.userpass.accessor]
}

output "admin_entity_id" {
  description = "Entity of the admin user (used by make vault-mfa-enroll)."
  value       = vault_identity_entity.admin.id
}

output "admin_totp_method_id" {
  description = "TOTP method ID (used by make vault-mfa-enroll)."
  value       = vault_identity_mfa_totp.admin.method_id
}
