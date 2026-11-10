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

resource "vault_quota_rate_limit" "login" {
  name           = "login"
  path           = "auth/"
  rate           = 5
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
