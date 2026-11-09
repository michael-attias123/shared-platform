provider "oci" {
  region              = var.region
  config_file_profile = var.oci_profile
}

# CLOUDFLARE_API_TOKEN (DNS edit on one zone) comes from ~/.config/platform/cloudflare.env.
provider "cloudflare" {}

locals {
  tags = {
    "platform-managed-by" = "opentofu"
    "platform-stack"      = "shared-platform/vault-server"
  }
  availability_domain = coalesce(var.availability_domain, try(data.oci_identity_availability_domains.all.availability_domains[0].name, null))
  image_id            = coalesce(var.image_ocid, try(data.oci_core_images.ubuntu.images[0].id, null))
}

# Everything shared between projects lives in its own compartment, separate from QuantumOps ("qops").
resource "oci_identity_compartment" "platform" {
  compartment_id = var.tenancy_ocid
  name           = "platform"
  description    = "Shared platform services (Vault), managed by github.com/michael-attias123/shared-platform"
  enable_delete  = true
  freeform_tags  = local.tags
}

data "oci_identity_availability_domains" "all" {
  compartment_id = var.tenancy_ocid
}

data "oci_objectstorage_namespace" "ns" {
  compartment_id = var.tenancy_ocid
}

data "oci_core_images" "ubuntu" {
  compartment_id           = var.tenancy_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04 Minimal"
  shape                    = var.shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
  state                    = "AVAILABLE"
}
