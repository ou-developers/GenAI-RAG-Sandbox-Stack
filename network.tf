resource "oci_core_vcn" "vcn" {
  compartment_id = local.project_compartment_ocid
  display_name   = "GENAILABS-VCN"
  cidr_blocks    = ["10.0.0.0/16"]
  dns_label      = "genailabs"
}

resource "oci_core_internet_gateway" "igw" {
  compartment_id = local.project_compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  enabled        = true
  display_name   = "GENAILABS-IGW"
}

resource "oci_core_route_table" "rt" {
  compartment_id = local.project_compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "GENAILABS-RT"

  route_rules {
    network_entity_id = oci_core_internet_gateway.igw.id
    description       = "Default route"
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
  }
}

resource "oci_core_subnet" "public" {
  compartment_id      = local.project_compartment_ocid
  vcn_id              = oci_core_vcn.vcn.id
  display_name        = "GENAILABS-SNET"
  cidr_block          = "10.0.10.0/24"
  prohibit_public_ip_on_vnic = false
  route_table_id      = oci_core_route_table.rt.id
  security_list_ids   = [oci_core_security_list.public.id]
  dns_label           = "genailabs"
}

resource "oci_core_security_list" "public" {
  compartment_id = local.project_compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "GENAILABS-SL"

  # All egress
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    description = "All egress"
  }

  # Ingress for each TCP port
  dynamic "ingress_security_rules" {
    for_each = local.open_tcp_ports
    content {
      protocol    = "6"
      source      = "0.0.0.0/0"
      description = "Allow TCP port ${ingress_security_rules.value}"
      tcp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
    }
  }
}