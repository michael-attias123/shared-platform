# Auto-unseal key and the VM's permissions. The VM authenticates as an instance principal: no API keys on it.

resource "oci_kms_vault" "platform" {
  compartment_id = oci_identity_compartment.platform.id
  display_name   = "platform-vault-seal"
  vault_type     = "DEFAULT"
  freeform_tags  = local.tags
}

resource "oci_kms_key" "seal" {
  compartment_id      = oci_identity_compartment.platform.id
  display_name        = "vault-auto-unseal"
  management_endpoint = oci_kms_vault.platform.management_endpoint
  protection_mode     = "HSM"
  freeform_tags       = local.tags

  key_shape {
    algorithm = "AES"
    length    = 32
  }

  # A new KMS vault's endpoint can answer 503 for a few minutes after creation; retry instead of failing.
  timeouts {
    create = "20m"
  }
}

resource "oci_objectstorage_bucket" "snapshots" {
  compartment_id = oci_identity_compartment.platform.id
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = "vault-snapshots"
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  versioning     = "Disabled"
  freeform_tags  = local.tags
}

# Object Storage's own service principal must be allowed to delete objects before a lifecycle rule can be set.
resource "oci_identity_policy" "objectstorage_lifecycle" {
  compartment_id = oci_identity_compartment.platform.id
  name           = "platform-objectstorage-lifecycle"
  description    = "Let Object Storage apply lifecycle rules (snapshot expiry) in this compartment"
  freeform_tags  = local.tags
  statements = [
    "Allow service objectstorage-${var.region} to manage object-family in compartment ${oci_identity_compartment.platform.name}",
  ]
}

resource "oci_objectstorage_object_lifecycle_policy" "snapshots" {
  namespace  = data.oci_objectstorage_namespace.ns.namespace
  bucket     = oci_objectstorage_bucket.snapshots.name
  depends_on = [oci_identity_policy.objectstorage_lifecycle]

  rules {
    name        = "expire-old-snapshots"
    action      = "DELETE"
    is_enabled  = true
    time_amount = var.snapshot_retention_days
    time_unit   = "DAYS"
    target      = "objects"
  }
}

resource "oci_identity_dynamic_group" "vault" {
  compartment_id = var.tenancy_ocid
  name           = "platform-vault"
  description    = "The shared Vault VM (instances in the platform compartment)"
  matching_rule  = "ALL {instance.compartment.id = '${oci_identity_compartment.platform.id}'}"
  freeform_tags  = local.tags
}

resource "oci_identity_policy" "vault" {
  compartment_id = oci_identity_compartment.platform.id
  name           = "platform-vault"
  description    = "Vault VM: use only its unseal key; write only snapshot objects"
  freeform_tags  = local.tags
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.vault.name} to use vaults in compartment ${oci_identity_compartment.platform.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.vault.name} to use keys in compartment ${oci_identity_compartment.platform.name} where target.key.id = '${oci_kms_key.seal.id}'",
    # Run Command: the agent on the VM fetches commands created by an admin, and returns their output.
    "Allow dynamic-group ${oci_identity_dynamic_group.vault.name} to use instance-agent-command-execution-family in compartment ${oci_identity_compartment.platform.name} where request.instance.id = target.instance.id",
    "Allow dynamic-group ${oci_identity_dynamic_group.vault.name} to manage objects in compartment ${oci_identity_compartment.platform.name} where all {target.bucket.name = '${oci_objectstorage_bucket.snapshots.name}', any {request.permission = 'OBJECT_CREATE', request.permission = 'OBJECT_INSPECT'}}",
  ]
}
