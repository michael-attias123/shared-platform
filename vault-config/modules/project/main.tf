# One project on the shared Vault: its own KV prefix, read/write policies, and login roles.

terraform {
  required_providers {
    vault = {
      source = "hashicorp/vault"
    }
  }
}

variable "name" {
  description = "Project name; secrets live under kv/<name>/."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}$", var.name))
    error_message = "name must be lowercase letters, digits and dashes."
  }
}

variable "kv_mount" {
  description = "KV v2 mount path."
  type        = string
  default     = "kv"
}

variable "kubernetes" {
  description = "Service accounts that may read: JWT mount (jwt-k8s-<cluster>), namespace, service account."
  type = list(object({
    mount           = string
    namespace       = string
    service_account = string
  }))
  default = []
}

variable "github" {
  description = "GitHub repositories (owner/name) whose Actions may read; optionally only from one ref."
  type = list(object({
    repository = string
    ref        = optional(string)
  }))
  default = []
}

variable "github_mount" {
  description = "GitHub Actions JWT mount path."
  type        = string
  default     = "jwt-github"
}

variable "approle" {
  description = "Create an AppRole for VMs/scripts."
  type        = bool
  default     = false
}

variable "approle_mount" {
  description = "AppRole mount path."
  type        = string
  default     = "approle"
}

locals {
  data_path = "${var.kv_mount}/data/${var.name}/*"
  meta_path = "${var.kv_mount}/metadata/${var.name}/*"
  # Every machine login asks for audience "vault" (ESO: serviceAccountRef.audiences; vault-action: jwtGithubAudience).
  audience = "vault"
}

resource "vault_policy" "read" {
  name   = "${var.name}-read"
  policy = <<-EOT
    path "${local.data_path}" {
      capabilities = ["read"]
    }
    path "${local.meta_path}" {
      capabilities = ["read", "list"]
    }
  EOT
}

resource "vault_policy" "write" {
  name   = "${var.name}-write"
  policy = <<-EOT
    path "${local.data_path}" {
      capabilities = ["create", "read", "update", "patch", "delete"]
    }
    path "${local.meta_path}" {
      capabilities = ["read", "list", "delete"]
    }
  EOT
}

resource "vault_jwt_auth_backend_role" "kubernetes" {
  for_each        = { for k in var.kubernetes : "${k.mount}/${k.namespace}/${k.service_account}" => k }
  backend         = each.value.mount
  role_name       = "${var.name}-${each.value.namespace}-${each.value.service_account}"
  role_type       = "jwt"
  user_claim      = "sub"
  bound_subject   = "system:serviceaccount:${each.value.namespace}:${each.value.service_account}"
  bound_audiences = [local.audience]
  token_policies  = [vault_policy.read.name]
  token_ttl       = 3600
  token_max_ttl   = 3600
}

resource "vault_jwt_auth_backend_role" "github" {
  for_each        = { for g in var.github : "${g.repository}@${coalesce(g.ref, "*")}" => g }
  backend         = var.github_mount
  role_name       = "${var.name}-${replace(each.value.repository, "/", "-")}"
  role_type       = "jwt"
  user_claim      = "repository"
  bound_audiences = [local.audience]
  bound_claims = merge(
    { repository = each.value.repository },
    each.value.ref == null ? {} : { ref = each.value.ref },
  )
  token_policies = [vault_policy.read.name]
  token_ttl      = 900
  token_max_ttl  = 900
}

resource "vault_approle_auth_backend_role" "this" {
  count          = var.approle ? 1 : 0
  backend        = var.approle_mount
  role_name      = var.name
  token_policies = [vault_policy.read.name]
  token_ttl      = 3600
  token_max_ttl  = 14400
  secret_id_ttl  = 7776000 # 90 days; issue a new one with make vault-approle-secret
}

output "read_policy" {
  description = "Policy that reads kv/<name>/*."
  value       = vault_policy.read.name
}

output "write_policy" {
  description = "Policy that manages kv/<name>/*."
  value       = vault_policy.write.name
}

output "kubernetes_roles" {
  description = "JWT roles for Kubernetes service accounts."
  value       = [for r in vault_jwt_auth_backend_role.kubernetes : "${r.backend}/${r.role_name}"]
}

output "github_roles" {
  description = "JWT roles for GitHub Actions."
  value       = [for r in vault_jwt_auth_backend_role.github : r.role_name]
}

output "approle" {
  description = "AppRole name (null if none)."
  value       = var.approle ? var.name : null
}
