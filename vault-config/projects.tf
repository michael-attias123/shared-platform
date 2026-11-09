# One module call per project. To onboard a project: add a block here, open a PR, then `make config-plan/apply`.
# See docs/runbooks/onboard-project.md for client examples (Kubernetes ESO, GitHub Actions, AppRole).

# End-to-end check of this repo itself: GitHub Actions on main reads kv/smoke/hello (vault-smoke.yml).
module "smoke" {
  source = "./modules/project"
  name   = "smoke"
  github = [{ repository = "${var.github_owner}/shared-platform", ref = "refs/heads/main" }]
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
    smoke = {
      read_policy  = module.smoke.read_policy
      github_roles = module.smoke.github_roles
    }
  }
}
