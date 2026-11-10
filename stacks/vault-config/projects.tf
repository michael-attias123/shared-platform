# One project per projects/<name>.yaml at the repo root (files starting with _ are not projects: they only
# list secrets for scripts/seed.sh). To onboard a project: add its file in a PR; after the merge the platform
# applies it. Format and client examples: docs/runbooks/onboard-project.md.

locals {
  project_dir   = "${path.module}/../../projects"
  project_files = [for f in fileset(local.project_dir, "*.yaml") : f if !startswith(f, "_")]
  projects = {
    for f in local.project_files :
    trimsuffix(f, ".yaml") => yamldecode(file("${local.project_dir}/${f}"))
  }

  # Normalized: every key present, so a file only says what it uses.
  project_specs = {
    for name, p in local.projects : name => {
      repo               = p.repo
      roles              = try(p.vault.roles, [])
      kubernetes         = try(p.vault.kubernetes, [])
      shared_credentials = try(p.vault.shared_credentials, [])
      approle            = try(p.vault.approle, false)
    }
  }
}

# A project file may only grant logins to repos of this account, and to clusters this stack knows.
check "project_files" {
  assert {
    condition     = alltrue([for n, p in local.project_specs : startswith(p.repo, "${var.github_owner}/")])
    error_message = "projects/*.yaml: repo must be one of ${var.github_owner}'s repositories."
  }
  assert {
    condition     = alltrue(flatten([for n, p in local.project_specs : [for k in p.kubernetes : contains(keys(local.clusters), k.cluster)]]))
    error_message = "projects/*.yaml: vault.kubernetes[].cluster needs stacks/vault-config/clusters/<cluster>.pub.pem."
  }
}

module "project" {
  source   = "./modules/project"
  for_each = local.project_specs

  name               = each.key
  shared_credentials = each.value.shared_credentials
  approle            = each.value.approle
  github = [
    for r in each.value.roles : {
      repository = each.value.repo
      ref        = try(r.ref, null)
      role       = try(r.role, null)
      write      = try(r.write, [])
    }
  ]
  kubernetes = [
    for k in each.value.kubernetes : {
      mount           = vault_jwt_auth_backend.k8s[k.cluster].path
      namespace       = k.namespace
      service_account = k.service_account
    }
  ]
}

# Before projects/*.yaml, smoke was its own module block.
moved {
  from = module.smoke
  to   = module.project["smoke"]
}

resource "vault_kv_secret_v2" "smoke_hello" {
  mount = vault_mount.kv.path
  name  = "smoke/hello"
  data_json = jsonencode({
    message = "hello from the shared Vault" # not a secret: proves the read path works
  })
}

output "projects" {
  description = "Policies and roles per project."
  value = {
    for name, m in module.project : name => {
      read_policy      = m.read_policy
      github_roles     = m.github_roles
      kubernetes_roles = m.kubernetes_roles
      approle          = m.approle
    }
  }
}
