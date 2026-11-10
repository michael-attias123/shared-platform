# Offline checks with a mocked Vault provider (CI; no Vault needed).

mock_provider "vault" {}

variables {
  state_passphrase = "test-passphrase-not-secret"
}

run "hardened_defaults" {
  command = apply
  variables {
    enforce_admin_mfa = false
  }

  assert {
    condition     = vault_mount.kv.options["version"] == "2"
    error_message = "Secrets must live in a KV v2 mount."
  }
  assert {
    condition     = vault_quota_rate_limit.login["userpass"].path == "auth/userpass/" && vault_quota_rate_limit.login["userpass"].rate <= 2
    error_message = "The human login must have the strictest rate limit."
  }
  assert {
    condition     = vault_identity_mfa_totp.admin.algorithm == "SHA1"
    error_message = "TOTP must use SHA1: common authenticator apps ignore other algorithms and every code fails."
  }
  assert {
    condition     = length(vault_identity_mfa_login_enforcement.admin) == 0
    error_message = "MFA enforcement stays off until enrollment (enforce_admin_mfa)."
  }
  assert {
    condition     = vault_jwt_auth_backend.github.bound_issuer == "https://token.actions.githubusercontent.com"
    error_message = "GitHub logins must be bound to GitHub's OIDC issuer."
  }
}

run "mfa_enforced_when_enabled" {
  command = apply
  variables {
    enforce_admin_mfa = true
  }

  assert {
    condition     = length(vault_identity_mfa_login_enforcement.admin) == 1
    error_message = "enforce_admin_mfa must create the TOTP login enforcement."
  }
}

run "project_module_is_least_privilege" {
  command = apply

  assert {
    condition     = strcontains(module.smoke.read_policy, "smoke-read")
    error_message = "Each project gets its own read policy."
  }
  assert {
    condition     = module.smoke.github_roles == ["smoke-michael-attias123-shared-platform"]
    error_message = "The smoke project gets exactly one GitHub role for this repo."
  }
}
