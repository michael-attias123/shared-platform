# One public subnet. Inbound: 443 from anywhere (only when expose_public), 22 only from inside the VCN
# (the OCI Bastion's private endpoint). Nothing else.

resource "oci_core_vcn" "platform" {
  compartment_id = oci_identity_compartment.platform.id
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "platform-vcn"
  dns_label      = "platform"
  freeform_tags  = local.tags
}

resource "oci_core_internet_gateway" "platform" {
  compartment_id = oci_identity_compartment.platform.id
  vcn_id         = oci_core_vcn.platform.id
  display_name   = "platform-igw"
  enabled        = true
  freeform_tags  = local.tags
}

resource "oci_core_route_table" "public" {
  compartment_id = oci_identity_compartment.platform.id
  vcn_id         = oci_core_vcn.platform.id
  display_name   = "platform-public"
  freeform_tags  = local.tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.platform.id
  }
}

# The VCN's default list allows SSH from anywhere; take it over and leave it empty (it's unused).
resource "oci_core_default_security_list" "default" {
  manage_default_resource_id = oci_core_vcn.platform.default_security_list_id
  display_name               = "platform-default-unused-empty"
  freeform_tags              = local.tags
}

resource "oci_core_security_list" "vault" {
  compartment_id = oci_identity_compartment.platform.id
  vcn_id         = oci_core_vcn.platform.id
  display_name   = "platform-vault"
  freeform_tags  = local.tags

  egress_security_rules {
    description = "all outbound (packages, Let's Encrypt, OCI APIs)"
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # SSH only from inside the VCN: that's the OCI Bastion's private endpoint. Never from the internet.
  ingress_security_rules {
    description = "SSH from OCI Bastion (inside the VCN)"
    source      = var.vcn_cidr
    protocol    = "6"
    tcp_options {
      min = 22
      max = 22
    }
  }

  dynamic "ingress_security_rules" {
    for_each = var.expose_public ? [1] : []
    content {
      description = "HTTPS to Vault (Caddy, Let's Encrypt TLS-ALPN)"
      source      = "0.0.0.0/0"
      protocol    = "6"
      tcp_options {
        min = 443
        max = 443
      }
    }
  }
}

resource "oci_core_subnet" "public" {
  compartment_id    = oci_identity_compartment.platform.id
  vcn_id            = oci_core_vcn.platform.id
  cidr_block        = cidrsubnet(var.vcn_cidr, 8, 1)
  display_name      = "platform-public"
  dns_label         = "public"
  route_table_id    = oci_core_route_table.public.id
  security_list_ids = [oci_core_security_list.vault.id]
  freeform_tags     = local.tags
}
