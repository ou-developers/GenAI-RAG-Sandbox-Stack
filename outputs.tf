output "project_compartment_ocid" { value = local.project_compartment_ocid }
output "vcn_id"                   { value = oci_core_vcn.vcn.id }
output "public_subnet_id"         { value = oci_core_subnet.public.id }
output "dev_vm_public_ip"         { value = oci_core_instance.dev.public_ip }