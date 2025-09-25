resource "oci_identity_compartment" "project" {
  count          = var.create_compartment ? 1 : 0
  provider       = oci.home
  compartment_id = local.parent_for_project
  description    = "GenAI one-click project compartment"
  name           = var.compartment_name
}

resource "oci_identity_dynamic_group" "dg" {
  count      = var.create_policies ? 1 : 0
  provider   = oci.home
  compartment_id = var.tenancy_ocid
  description = "GenAI OneClick DG"
  name        = "oneclick-genai-dg-${substr(replace(local.project_compartment_ocid, "ocid1.compartment.oc1..", ""), 0, 8)}"
  matching_rule = "ANY {instance.compartment.id = '${local.project_compartment_ocid}'}"
}

resource "oci_identity_policy" "dg_policies" {
  count      = var.create_policies ? 1 : 0
  provider   = oci.home
  compartment_id = var.tenancy_ocid
  description = "Allow DG to use Generative AI and related services"
  name        = "oneclick-genai-dg-policies-${substr(replace(local.project_compartment_ocid, "ocid1.compartment.oc1..", ""), 0, 8)}"
  statements = [
    "allow dynamic-group ${oci_identity_dynamic_group.dg[0].name} to use generative-ai-family in tenancy",
    "allow dynamic-group ${oci_identity_dynamic_group.dg[0].name} to read compartments in tenancy",
    "allow dynamic-group ${oci_identity_dynamic_group.dg[0].name} to manage object-family in compartment id ${local.project_compartment_ocid}"
  ]
}