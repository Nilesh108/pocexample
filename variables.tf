variable "prefix" {
  description = "Name prefix for all resources"
  type        = string
  default     = "zantac"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "vm_admin_username" {
  description = "Admin username for scale set VMs"
  type        = string
  default     = "azureuser"
}

variable "vm_admin_password" {
  description = "Admin password (demo only – prefer SSH in real use)"
  type        = string
  sensitive   = true
}

variable "operator_object_id" {
  description = <<EOT
Azure AD object ID of the operator who should be able to restart
the web servers (Virtual Machine Contributor on the VMSS).
EOT
  type = string
}
