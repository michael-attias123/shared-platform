# The tenancy-level things every stack and project leans on, which therefore belong to no project:
# the OpenTofu state bucket and the $0 budget guard. QuantumOps' infra/bootstrap/oci.sh created them
# with the OCI CLI before shared-platform existed; imports.tf takes them over unchanged.
#
# Laptop-only, like vault-server: this is what everything else (Vault included) stands on, so it must
# never depend on Vault or CI. Changes: make plan STACK=oci-foundation, then make apply.
#
# The S3-compatible key that reads and writes the bucket stays outside OpenTofu (oci.sh secret-key):
# its secret would otherwise sit in state.

provider "oci" {
  region              = var.region
  config_file_profile = var.oci_profile
}

data "oci_objectstorage_namespace" "ns" {
  compartment_id = var.tenancy_ocid
}

data "oci_identity_user" "me" {
  user_id = var.user_ocid
}

locals {
  alert_email = coalesce(var.alert_email, data.oci_identity_user.me.email)

  # Exactly what oci.sh created, so the takeover changes nothing. Absolute thresholds above the $1 budget
  # are accepted by OCI; they tracked Free Trial credit spend (QuantumOps ADR 0010).
  alerts = {
    "any-spend"   = { threshold_type = "PERCENTAGE", threshold = 1 }
    "credits-50"  = { threshold_type = "ABSOLUTE", threshold = 50 }
    "credits-150" = { threshold_type = "ABSOLUTE", threshold = 150 }
    "credits-250" = { threshold_type = "ABSOLUTE", threshold = 250 }
  }
}

# Every stack's state, each under its own key (platform/<stack>/..., oci/..., github/...), encrypted
# by the stacks themselves. Versioned, so a bad write can be rolled back.
resource "oci_objectstorage_bucket" "state" {
  compartment_id = var.tenancy_ocid
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = var.state_bucket
  access_type    = "NoPublicAccess"
  versioning     = "Enabled"

  lifecycle {
    prevent_destroy = true
  }
}

# OCI allows one budget per target compartment, so every alert hangs off this $1 budget on the tenancy.
resource "oci_budget_budget" "always_free" {
  compartment_id = var.tenancy_ocid
  display_name   = var.budget_name
  description    = "Always Free guard: any spend at all is a surprise"
  amount         = 1
  reset_period   = "MONTHLY"
  target_type    = "COMPARTMENT"
  targets        = [var.tenancy_ocid]

  lifecycle {
    prevent_destroy = true
  }
}

resource "oci_budget_alert_rule" "this" {
  for_each = local.alerts

  budget_id      = oci_budget_budget.always_free.id
  display_name   = each.key
  type           = "ACTUAL"
  threshold_type = each.value.threshold_type
  threshold      = each.value.threshold
  recipients     = local.alert_email
  message        = "QuantumOps: OCI spend crossed ${each.key}. Check Billing -> Cost Analysis."
}
