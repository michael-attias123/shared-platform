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
    condition     = strcontains(module.project["smoke"].read_policy, "smoke-read")
    error_message = "Each project gets its own read policy."
  }
  assert {
    condition     = module.project["smoke"].github_roles == ["smoke-michael-attias123-shared-platform"]
    error_message = "The smoke project keeps its one GitHub role name (vault-smoke.yml logs in with it)."
  }
}

run "projects_come_from_yaml" {
  command = apply

  assert {
    condition     = !contains(keys(module.project), "_shared") && !contains(keys(module.project), "_platform")
    error_message = "Files starting with _ list secrets only; they are not projects."
  }
  assert {
    condition = toset(module.project["house-manager"].github_roles) == toset([
      "house-manager-michael-attias123-house-manager-main",
      "house-manager-michael-attias123-house-manager-pr",
    ])
    error_message = "house-manager gets a main and a pr role."
  }
  assert {
    condition     = module.project["house-manager"].github_role_details["house-manager-michael-attias123-house-manager-pr"].bound_claims["ref"] == "refs/pull/*"
    error_message = "The pr role is bound to pull request refs."
  }
}

run "roles_are_scoped" {
  command = apply

  assert {
    condition     = alltrue([for r in values(module.project["house-manager"].github_role_details) : r.bound_claims_type == "glob" && r.bound_claims["repository"] == "michael-attias123/house-manager"])
    error_message = "Every GitHub role is bound to its project's repo."
  }
  assert {
    condition     = contains(module.project["house-manager"].github_role_details["house-manager-michael-attias123-house-manager-main"].token_policies, "house-manager-michael-attias123-house-manager-main-write")
    error_message = "The main role may write kv/house-manager/generated."
  }
  assert {
    condition     = !anytrue([for p in module.project["house-manager"].github_role_details["house-manager-michael-attias123-house-manager-pr"].token_policies : endswith(p, "-write")])
    error_message = "The pr role writes nothing."
  }
  assert {
    condition     = strcontains(module.project["house-manager"].policies["house-manager-michael-attias123-house-manager-main-write"], "kv/data/house-manager/generated")
    error_message = "The write policy covers only the declared sub-path."
  }
  assert {
    condition     = strcontains(module.project["house-manager"].policies["house-manager-shared"], "kv/data/shared/supabase")
    error_message = "Declared shared credentials are readable."
  }
  assert {
    condition     = !strcontains(module.project["house-manager"].policies["house-manager-shared"], "kv/data/shared/*")
    error_message = "Only the declared shared credentials, not all of kv/shared."
  }
}

run "platform_ci_roles" {
  command = apply

  assert {
    condition     = vault_jwt_auth_backend_role.platform_apply.bound_claims["ref"] == "refs/heads/main" && vault_jwt_auth_backend_role.platform_plan.bound_claims["ref"] == "refs/pull/*"
    error_message = "platform-apply runs from main only; platform-plan from pull requests."
  }
  assert {
    condition     = alltrue([for r in [vault_jwt_auth_backend_role.platform_apply, vault_jwt_auth_backend_role.platform_plan] : r.bound_claims["repository"] == "michael-attias123/shared-platform"])
    error_message = "The platform roles belong to this repo."
  }
  assert {
    condition     = strcontains(vault_policy.platform_apply.policy, "path \"kv/data/+/*\" {\n  capabilities = [\"deny\"]") && strcontains(vault_policy.platform_apply.policy, "path \"kv/data/+\" {\n  capabilities = [\"deny\"]")
    error_message = "platform-apply never reads projects' secrets."
  }
  assert {
    # Vault ranks kv/data/* above kv/data/+/platform/* (fewer + segments), so that deny would win.
    condition     = !strcontains(vault_policy.platform_apply.policy, "path \"kv/data/*\"") && !strcontains(vault_policy.platform_plan.policy, "path \"kv/data/*\"")
    error_message = "A kv/data/* deny would also lock the platform out of kv/<project>/platform/*."
  }
  assert {
    condition     = strcontains(vault_policy.platform_apply.policy, "path \"auth/userpass/users/*\" {\n  capabilities = [\"deny\"]")
    error_message = "platform-apply can't set the admin's password."
  }
  assert {
    condition     = !strcontains(vault_policy.platform_plan.policy, "create") && !strcontains(vault_policy.platform_plan.policy, "update")
    error_message = "platform-plan only reads."
  }
  assert {
    condition     = strcontains(vault_policy.platform_plan.policy, "path \"sys/mounts/auth/+/tune\" {\n  capabilities = [\"read\", \"sudo\"]")
    error_message = "A plan reads every auth mount's tuning, which Vault only shows with sudo."
  }
  assert {
    condition     = vault_jwt_auth_backend_role.platform_drift.bound_claims["ref"] == "refs/heads/main" && vault_jwt_auth_backend_role.platform_drift.token_policies == toset(["platform-plan"])
    error_message = "The scheduled drift check runs from main with the read-only policy."
  }
}
