# How machines log in. Projects get roles on these mounts through modules/project.

# GitHub Actions: short-lived OIDC tokens, no stored secrets. Roles bind to `repository` (and optionally `ref`).
resource "vault_jwt_auth_backend" "github" {
  path               = "jwt-github"
  description        = "GitHub Actions OIDC"
  oidc_discovery_url = "https://token.actions.githubusercontent.com"
  bound_issuer       = "https://token.actions.githubusercontent.com"
}

# VMs and scripts: role ID + secret ID (issued with `make vault-approle-secret PROJECT=...`).
resource "vault_auth_backend" "approle" {
  type        = "approle"
  path        = "approle"
  description = "VMs and scripts"
}

# Kubernetes clusters: one JWT mount per cluster, validating service-account tokens with the cluster's public
# signing key (clusters/<name>.pub.pem). Vault never needs a network path to the cluster's API server.
locals {
  clusters = {
    for f in fileset("${path.module}/clusters", "*.pub.pem") :
    trimsuffix(f, ".pub.pem") => {
      pubkey = file("${path.module}/clusters/${f}")
    }
  }
}

resource "vault_jwt_auth_backend" "k8s" {
  for_each               = local.clusters
  path                   = "jwt-k8s-${each.key}"
  description            = "Kubernetes service accounts of cluster ${each.key}"
  jwt_validation_pubkeys = [each.value.pubkey]
}
