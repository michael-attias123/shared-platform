locals {
  # sslip.io answers <anything>.<a-b-c-d>.sslip.io with a.b.c.d, so the name follows the reserved IP.
  # The VM derives the same name at first boot (cloud-init), so both always agree.
  vault_hostname = "${var.hostname_prefix}.${replace(oci_core_public_ip.vault.ip_address, ".", "-")}.sslip.io"
}

output "vault_hostname" {
  description = "Public name of Vault."
  value       = local.vault_hostname
}

output "vault_addr" {
  description = "VAULT_ADDR for every client."
  value       = "https://${local.vault_hostname}"
}

output "public_ip" {
  description = "Reserved public IP."
  value       = oci_core_public_ip.vault.ip_address
}

output "exposed" {
  description = "Whether 443 is open to the internet."
  value       = var.expose_public
}

output "instance_id" {
  description = "Vault VM OCID (for Bastion sessions)."
  value       = oci_core_instance.vault.id
}

output "private_ip" {
  description = "Vault VM private IP (Bastion target)."
  value       = local.vault_private_ip
}

output "bastion_id" {
  description = "OCI Bastion OCID."
  value       = oci_bastion_bastion.platform.id
}

output "snapshot_bucket" {
  description = "Object Storage bucket with daily Raft snapshots."
  value       = oci_objectstorage_bucket.snapshots.name
}
