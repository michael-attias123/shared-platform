# Admin shell without opening SSH to the internet: short-lived OCI Bastion sessions (free).
resource "oci_bastion_bastion" "platform" {
  compartment_id               = oci_identity_compartment.platform.id
  bastion_type                 = "STANDARD"
  name                         = "platformbastion"
  target_subnet_id             = oci_core_subnet.public.id
  client_cidr_block_allow_list = ["0.0.0.0/0"] # sessions still need your OCI API key; your IP changes too often to pin
  max_session_ttl_in_seconds   = 10800
  freeform_tags                = local.tags
}
