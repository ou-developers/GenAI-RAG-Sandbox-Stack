locals {
  parent_for_project = trimspace(var.parent_compartment_ocid) != "" ? var.parent_compartment_ocid : var.tenancy_ocid
  project_compartment_ocid = var.create_compartment ? oci_identity_compartment.project[0].id : var.project_compartment_ocid

  # CSV -> numbers
  ports_strings  = [for p in split(",", var.open_tcp_ports_csv) : trimspace(p)]
  open_tcp_ports = [for p in local.ports_strings : tonumber(p)]
}