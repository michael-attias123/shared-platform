# The platform's own CI logins (wired into workflows in SP4, docs/ROADMAP.md). Both are bound to this repo:
#   platform-plan   pull requests: plan the CI-applied stacks (vault-config, grafana, github). Reads only.
#   platform-apply  main: apply them. Manages Vault's configuration, like the admin, but not projects' secrets.
# Neither reads kv/<project>/* (the projects' own secrets): in Vault the most specific path rule wins, so the
# kv/data/* deny below holds except where a longer path is allowed.

locals {
  platform_repo = "${var.github_owner}/shared-platform"

  # Secrets the platform itself reads or writes: its own credentials, the account-wide ones (to check
  # them), what it mints into projects' platform/ folders, and the smoke value.
  platform_kv_read = [
    "kv/data/platform/*", "kv/metadata/platform/*",
    "kv/data/shared/*", "kv/metadata/shared/*",
    "kv/data/+/platform", "kv/data/+/platform/*", "kv/metadata/+/platform", "kv/metadata/+/platform/*",
    "kv/data/smoke/*", "kv/metadata/smoke/*",
  ]
}

resource "vault_policy" "platform_plan" {
  name   = "platform-plan"
  policy = <<-EOT
    # Read Vault's configuration, as a plan of vault-config does.
    path "*" {
      capabilities = ["read", "list"]
    }
    # The audit devices are listed with sudo.
    path "sys/audit" {
      capabilities = ["read", "sudo"]
    }
    # No project secrets, and no token tricks.
    path "kv/data/*" {
      capabilities = ["deny"]
    }
    path "kv/metadata/*" {
      capabilities = ["deny"]
    }
    path "sys/raw/*" {
      capabilities = ["deny"]
    }
    %{for p in local.platform_kv_read~}
    path "${p}" {
      capabilities = ["read", "list"]
    }
    %{endfor~}
  EOT
}

resource "vault_policy" "platform_apply" {
  name   = "platform-apply"
  policy = <<-EOT
    # Manage Vault's configuration: mounts, auth methods and roles, policies, audit, quotas, MFA.
    path "*" {
      capabilities = ["create", "read", "update", "patch", "delete", "list", "sudo"]
    }
    # Never read or change projects' secrets, and never the raw storage or the root of trust.
    path "kv/data/*" {
      capabilities = ["deny"]
    }
    path "kv/metadata/*" {
      capabilities = ["deny"]
    }
    path "sys/raw/*" {
      capabilities = ["deny"]
    }
    path "sys/generate-root/*" {
      capabilities = ["deny"]
    }
    path "sys/rekey/*" {
      capabilities = ["deny"]
    }
    # The admin user is written by `make vault-admin` only: CI can't set its password and take over.
    path "auth/userpass/users/*" {
      capabilities = ["deny"]
    }
    %{for p in local.platform_kv_read~}
    path "${p}" {
      capabilities = ["create", "read", "update", "patch", "delete", "list"]
    }
    %{endfor~}
  EOT
}

resource "vault_jwt_auth_backend_role" "platform_plan" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "platform-plan"
  role_type         = "jwt"
  user_claim        = "repository"
  bound_audiences   = ["vault"]
  bound_claims_type = "glob"
  bound_claims      = { repository = local.platform_repo, ref = "refs/pull/*" }
  token_policies    = [vault_policy.platform_plan.name]
  token_ttl         = 1800
  token_max_ttl     = 1800
}

resource "vault_jwt_auth_backend_role" "platform_apply" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "platform-apply"
  role_type         = "jwt"
  user_claim        = "repository"
  bound_audiences   = ["vault"]
  bound_claims_type = "glob"
  bound_claims      = { repository = local.platform_repo, ref = "refs/heads/main" }
  token_policies    = [vault_policy.platform_apply.name]
  token_ttl         = 1800
  token_max_ttl     = 1800
}
