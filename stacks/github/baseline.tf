# The platform's baseline on every project repo that asks for it in projects/<name>.yaml:
#
#   github:
#     baseline: true
#     allowed_actions: [denoland/*]   # on top of what the shared building blocks use
#     adopt_vault_addr: true          # VAULT_ADDR was set by hand before the baseline: import it
#
# This repo keeps its own rules (main.tf).

locals {
  project_dir   = "${path.module}/../../projects"
  project_files = [for f in fileset(local.project_dir, "*.yaml") : f if !startswith(f, "_")]
  projects = {
    for f in local.project_files :
    trimsuffix(f, ".yaml") => yamldecode(file("${local.project_dir}/${f}"))
  }

  baselines = {
    for name, p in local.projects : name => {
      repository       = trimprefix(p.repo, "${var.github_owner}/")
      allowed_actions  = try(p.github.allowed_actions, [])
      adopt_vault_addr = try(p.github.adopt_vault_addr, false)
    } if try(p.github.baseline, false)
  }

  # What the shared building blocks themselves use (.github/workflows and .github/actions here), so a
  # project that calls them needs to list nothing. trivy-action pulls in aquasecurity/setup-trivy.
  platform_actions = [
    "${var.github_owner}/*",
    "opentofu/setup-opentofu@*",
    "hashicorp/setup-terraform@*",
    "terraform-linters/setup-tflint@*",
    "gitleaks/gitleaks-action@*",
    "aquasecurity/*",
  ]
}

check "baselines" {
  assert {
    condition     = alltrue([for n, p in local.projects : startswith(p.repo, "${var.github_owner}/") if try(p.github.baseline, false)])
    error_message = "projects/*.yaml: repo must be one of ${var.github_owner}'s repositories."
  }
  assert {
    condition     = length(distinct([for b in local.baselines : b.repository])) == length(local.baselines)
    error_message = "projects/*.yaml: two projects ask for a baseline on the same repo."
  }
}

module "baseline" {
  source   = "./modules/baseline"
  for_each = local.baselines

  repository      = each.value.repository
  vault_addr      = var.vault_addr
  allowed_actions = concat(local.platform_actions, each.value.allowed_actions)
}

# A VAULT_ADDR variable set by hand before the baseline existed is taken over, not created again.
# Once imported the block is a no-op. take_over = false skips it (the mocked tests can't import).
import {
  for_each = { for name, b in local.baselines : name => b if var.take_over && b.adopt_vault_addr }
  to       = module.baseline[each.key].github_actions_variable.vault_addr
  id       = "${each.value.repository}:VAULT_ADDR"
}

output "baseline_repositories" {
  description = "owner/name of every repo with the baseline (scripts/repo-security.sh reads it)."
  value       = sort([for b in local.baselines : "${var.github_owner}/${b.repository}"])
}
