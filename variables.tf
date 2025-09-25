variable "tenancy_ocid" {
  description = "OCID of your tenancy (root)."
  type        = string
}

variable "home_region" {
  description = "Your tenancy's home region (e.g., ap-hyderabad-1)."
  type        = string
}

variable "region" {
  description = "Deployment region (e.g., ap-hyderabad-1)."
  type        = string
}

variable "create_compartment" {
  description = "Whether to create a new project compartment."
  type        = bool
  default     = true
}

variable "parent_compartment_ocid" {
  description = "Parent compartment OCID for new project compartment. Leave blank to use tenancy root."
  type        = string
  default     = ""
}

variable "project_compartment_ocid" {
  description = "Existing compartment OCID when create_compartment=false."
  type        = string
  default     = ""
}

variable "compartment_name" {
  description = "Project compartment name."
  type        = string
  default     = "genai-oneclick-project"
}

variable "ssh_public_key" {
  description = "Your SSH public key (ssh-rsa ...)."
  type        = string
}

variable "instance_shape" {
  description = "Compute shape."
  type        = string
  default     = "VM.Standard.E5.Flex"
}

variable "instance_ocpus" {
  description = "OCPUs for Flex shape."
  type        = number
  default     = 2
}

variable "instance_memory_gbs" {
  description = "Memory (GB) for Flex shape."
  type        = number
  default     = 24
}

variable "boot_volume_size_gbs" {
  description = "Boot volume size (GB)."
  type        = number
  default     = 100
}

variable "open_tcp_ports_csv" {
  description = "TCP ports to open (CSV), e.g. 22,8888,8501,1521"
  type        = string
  default     = "22,8888,8501,1521"
}

variable "create_policies" {
  description = "Create instance-principal DG and Policies for Generative AI?"
  type        = bool
  default     = true
}