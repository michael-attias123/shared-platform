# One project on the shared Vault: its own KV prefix, read/write policies, and login roles.
# Called once per projects/<name>.yaml (see ../../projects.tf).

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
  description = <<-EOT
    GitHub Actions logins of this project. Each entry is one role, named
    <project>-<owner>-<repo>[-<role>]:
      repository  owner/name
      ref         the git ref the job runs on; a glob (refs/pull/*) is allowed. Null: any ref.
      role        a suffix, so one repo can have several roles (main, pr). Null: none.
      write       KV sub-paths under kv/<name>/ the role may also write (e.g. generated).
  EOT
  type = list(object({
    repository = string
    ref        = optional(string)
    role       = optional(string)
    write      = optional(list(string), [])
  }))
  default = []

  validation {
    condition     = alltrue([for g in var.github : g.role == null || can(regex("^[a-z0-9][a-z0-9-]{0,20}$", g.role))])
    error_message = "github[].role must be a short lowercase suffix (main, pr)."
  }
  validation {
    condition     = alltrue(flatten([for g in var.github : [for w in g.write : can(regex("^[a-z0-9][a-z0-9_-]*$", w)) && w != "platform"]]))
    error_message = "github[].write lists sub-path names under kv/<name>/; platform/ is written by the platform only."
  }
}

variable "github_mount" {
  description = "GitHub Actions JWT mount path."
  type        = string
  default     = "jwt-github"
}

variable "shared_credentials" {
  description = "Names under kv/shared/ every role of this project may read (account-wide credentials that can't be scoped)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for s in var.shared_credentials : can(regex("^[a-z0-9][a-z0-9_-]*$", s))])
    error_message = "shared_credentials are names under kv/shared/."
  }
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

  github_roles = {
    for g in var.github :
    join("-", compact([var.name, replace(g.repository, "/", "-"), g.role])) => g
  }
  writers = { for name, g in local.github_roles : name => g if length(g.write) > 0 }

  # Attached to every machine login of the project.
  machine_policies = concat([vault_policy.read.name], vault_policy.shared[*].name)
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

# The account-wide credentials this project declared (kv/shared/<name>).
resource "vault_policy" "shared" {
  count = length(var.shared_credentials) > 0 ? 1 : 0
  name  = "${var.name}-shared"
  policy = join("\n", [for s in var.shared_credentials : <<-EOT
    path "${var.kv_mount}/data/shared/${s}" {
      capabilities = ["read"]
    }
  EOT
  ])
}

# A role's own write sub-paths, e.g. kv/<name>/generated (values its apply mints for scheduled jobs).
resource "vault_policy" "role_write" {
  for_each = local.writers
  name     = "${each.key}-write"
  policy = join("\n", [for w in each.value.write : <<-EOT
    path "${var.kv_mount}/data/${var.name}/${w}" {
      capabilities = ["create", "read", "update", "patch"]
    }
    path "${var.kv_mount}/data/${var.name}/${w}/*" {
      capabilities = ["create", "read", "update", "patch"]
    }
  EOT
  ])
}

resource "vault_jwt_auth_backend_role" "kubernetes" {
  for_each        = { for k in var.kubernetes : "${k.mount}/${k.namespace}/${k.service_account}" => k }
  backend         = each.value.mount
  role_name       = "${var.name}-${each.value.namespace}-${each.value.service_account}"
  role_type       = "jwt"
  user_claim      = "sub"
  bound_subject   = "system:serviceaccount:${each.value.namespace}:${each.value.service_account}"
  bound_audiences = [local.audience]
  token_policies  = local.machine_policies
  token_ttl       = 3600
  token_max_ttl   = 3600
}

resource "vault_jwt_auth_backend_role" "github" {
  for_each        = local.github_roles
  backend         = var.github_mount
  role_name       = each.key
  role_type       = "jwt"
  user_claim      = "repository"
  bound_audiences = [local.audience]
  # glob: refs/pull/* matches any PR; a plain value (refs/heads/main) still matches only itself.
  bound_claims_type = "glob"
  bound_claims = merge(
    { repository = each.value.repository },
    each.value.ref == null ? {} : { ref = each.value.ref },
  )
  token_policies = concat(local.machine_policies, try([vault_policy.role_write[each.key].name], []))
  token_ttl      = 900
  token_max_ttl  = 900
}

resource "vault_approle_auth_backend_role" "this" {
  count          = var.approle ? 1 : 0
  backend        = var.approle_mount
  role_name      = var.name
  token_policies = local.machine_policies
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

output "github_role_details" {
  description = "Each GitHub role's bound claims and policies (for the tests and the plan review)."
  value = {
    for name, r in vault_jwt_auth_backend_role.github : name => {
      bound_claims      = r.bound_claims
      bound_claims_type = r.bound_claims_type
      token_policies    = r.token_policies
    }
  }
}

output "policies" {
  description = "The text of every policy this project gets, by name."
  value = merge(
    { (vault_policy.read.name) = vault_policy.read.policy, (vault_policy.write.name) = vault_policy.write.policy },
    { for p in vault_policy.shared : p.name => p.policy },
    { for k, p in vault_policy.role_write : p.name => p.policy },
  )
}
