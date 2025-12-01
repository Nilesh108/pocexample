output "lb_public_ip" {
  description = "Public IP address of the load balancer – browse http://IP/"
  value       = azurerm_public_ip.lb_pip.ip_address
}
