# The consumer side of the shared Vault: reads a project's KV v2 secrets into
# one flat, sensitive map, the `values` interface house-manager's
# modules/secrets/* share (any store returning the same map is a drop-in).
#
#   module "secrets" {
#     source = "git::https://github.com/michael-attias123/shared-platform.git//modules/secrets-vault?ref=main"
#     paths  = ["house-manager/app", "house-manager/monitoring"]
#   }
#   module.secrets.values["vapid_public_key"]
#
# The provider is configured by the caller (address from VAULT_ADDR, token from
# VAULT_TOKEN, which the vault-env action exports, skip_child_token = true).
# Values read here are stored in the caller's state: keep it encrypted.
#
# The provider marks this data source deprecated in favour of the ephemeral
# vault_kv_secret_v2. That one is kept out of state, but its values may only
# go to write-only attributes and provider configs, and projects pass secrets
# to ordinary attributes (function secrets, contact points). Move a value to
# the ephemeral form once every place it goes is write-only.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.13"
    }
  }
}

variable "paths" {
  description = "KV v2 secret names under the mount, e.g. house-manager/app. Later paths win on a duplicate key."
  type        = list(string)

  validation {
    # A name, not the API path: no mount prefix, no data/ or metadata/ segment.
    condition = length(var.paths) > 0 && alltrue([
      for p in var.paths : can(regex("^[a-z0-9][a-z0-9-]*(/[a-z0-9][a-z0-9_-]*)+$", p))
      && !can(regex("^kv/|(^|/)(data|metadata)(/|$)", p))
    ])
    error_message = "paths must be one or more KV names like <project>/<name> (not kv/data/<project>/<name>)."
  }
}

variable "mount" {
  description = "KV v2 mount path."
  type        = string
  default     = "kv"
}

data "vault_kv_secret_v2" "this" {
  for_each = toset(var.paths)
  mount    = var.mount
  name     = each.value
}

output "values" {
  description = "Every key of every path, as strings."
  sensitive   = true
  value       = merge([for p in var.paths : data.vault_kv_secret_v2.this[p].data]...)
}
