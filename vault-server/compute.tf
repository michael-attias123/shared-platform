resource "oci_core_instance" "vault" {
  compartment_id      = oci_identity_compartment.platform.id
  availability_domain = local.availability_domain
  display_name        = "vault-1"
  shape               = var.shape
  freeform_tags       = merge(local.tags, { "platform-role" = "vault" })

  source_details {
    source_type             = "image"
    source_id               = local.image_id
    boot_volume_size_in_gbs = var.boot_volume_gb
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = false # the reserved IP below is attached instead, so DNS never changes
    hostname_label   = "vault-1"
  }

  metadata = {
    ssh_authorized_keys = trimspace(var.ssh_public_key)
    user_data = base64encode(templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
      vault_version       = var.vault_version
      vault_hostname      = var.vault_hostname
      seal_key_id         = oci_kms_key.seal.id
      crypto_endpoint     = oci_kms_vault.platform.crypto_endpoint
      management_endpoint = oci_kms_vault.platform.management_endpoint
      os_namespace        = data.oci_objectstorage_namespace.ns.namespace
      snapshot_bucket     = oci_objectstorage_bucket.snapshots.name
    }))
  }

  agent_config {
    are_all_plugins_disabled = false
    is_management_disabled   = false
    is_monitoring_disabled   = false

    plugins_config {
      name          = "Bastion"
      desired_state = "ENABLED"
    }
  }

  lifecycle {
    # Don't rebuild Vault when Canonical publishes a newer image or cloud-init text changes; upgrades happen in place.
    ignore_changes = [source_details[0].source_id, metadata["user_data"]]
  }

  # The instance principal needs the policy before first boot (unseal + snapshots).
  depends_on = [oci_identity_policy.vault]
}

data "oci_core_vnic_attachments" "vault" {
  compartment_id = oci_identity_compartment.platform.id
  instance_id    = oci_core_instance.vault.id
}

data "oci_core_private_ips" "vault" {
  vnic_id = try(data.oci_core_vnic_attachments.vault.vnic_attachments[0].vnic_id, null)
}

locals {
  vault_private_ip    = try(data.oci_core_private_ips.vault.private_ips[0].ip_address, null)
  vault_private_ip_id = try(data.oci_core_private_ips.vault.private_ips[0].id, null)
}

# A reserved IP survives instance rebuilds, so the DNS record and clients never change.
resource "oci_core_public_ip" "vault" {
  compartment_id = oci_identity_compartment.platform.id
  lifetime       = "RESERVED"
  display_name   = "vault-public"
  private_ip_id  = local.vault_private_ip_id
  freeform_tags  = local.tags
}
