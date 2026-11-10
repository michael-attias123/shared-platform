# Core of the shared Vault: one KV store for all projects, audit log, and rate limits (it's on the internet).

resource "vault_mount" "kv" {
  path        = "kv"
  type        = "kv"
  options     = { version = "2" }
  description = "Secrets for every project, under kv/<project>/"
}

resource "vault_audit" "file" {
  type        = "file"
  description = "Every request (secrets HMAC'd), rotated daily by logrotate on the VM"
  options = {
    file_path = "/var/log/vault/audit.log"
  }
}

# Per client IP. Generous for normal use, tight on login endpoints against password guessing
# (userpass also locks a user after 5 failed attempts by default).
resource "vault_quota_rate_limit" "global" {
  name     = "global"
  path     = ""
  rate     = 100
  interval = 1
}

# Vault quotas need a concrete mount, so each login method gets its own limit (per client IP).
# The human login is the strictest; machines log in a few times an hour at most.
locals {
  login_quotas = {
    userpass   = { path = "auth/${vault_auth_backend.userpass.path}/", rate = 2 }
    approle    = { path = "auth/${vault_auth_backend.approle.path}/", rate = 5 }
    jwt-github = { path = "auth/${vault_jwt_auth_backend.github.path}/", rate = 10 }
  }
}

resource "vault_quota_rate_limit" "login" {
  for_each       = local.login_quotas
  name           = "login-${each.key}"
  path           = each.value.path
  rate           = each.value.rate
  interval       = 1
  block_interval = 60
}

# For the VM's daily snapshot timer (a periodic token made by `make vault-snapshot-setup`).
resource "vault_policy" "snapshot" {
  name   = "snapshot"
  policy = <<-EOT
    path "sys/storage/raft/snapshot" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_policy" "admin" {
  name   = "admin"
  policy = <<-EOT
    path "*" {
      capabilities = ["create", "read", "update", "patch", "delete", "list", "sudo"]
    }
  EOT
}
