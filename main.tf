# Set the Azure Provider source and version being used for POC
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.x"
    }
  }
}

# Configure the Microsoft Azure provider
provider "azurerm" {
  features {}
}

# -------------------------
# Resource Group
# -------------------------
resource "azurerm_resource_group" "rg" {
  name     = "${var.prefix}-rg"
  location = var.location
}

# -------------------------
# Network (VPC equivalent)
# -------------------------
resource "azurerm_virtual_network" "vnet" {
  name                = "${var.prefix}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "subnet" {
  name                 = "${var.prefix}-subnet-web"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Security group – allow SSH and app traffic (8080) from internet
resource "azurerm_network_security_group" "nsg" {
  name                = "${var.prefix}-nsg-web"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "SSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "HTTP-App-8080"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# -------------------------
# Public Load Balancer
# -------------------------

resource "azurerm_public_ip" "lb_pip" {
  name                = "${var.prefix}-lb-pip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_lb" "lb" {
  name                = "${var.prefix}-lb"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "PublicFrontend"
    public_ip_address_id = azurerm_public_ip.lb_pip.id
  }
}

resource "azurerm_lb_backend_address_pool" "bepool" {
  name                = "web-backend-pool"
  loadbalancer_id     = azurerm_lb.lb.id
}

resource "azurerm_lb_probe" "http_probe" {
  name                = "http-8080-probe"
  loadbalancer_id     = azurerm_lb.lb.id
  protocol            = "Tcp"
  port                = 8080
}

# LB rule: Internet on port 80 -> backend 8080
resource "azurerm_lb_rule" "http_rule" {
  name                           = "http-80-to-8080"
  loadbalancer_id                = azurerm_lb.lb.id
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 8080
  frontend_ip_configuration_name = "PublicFrontend"
  probe_id                       = azurerm_lb_probe.http_probe.id
}

# -------------------------
# VM Scale Set (Auto scaling group + web servers)
# -------------------------

# simple cloud-init / custom_data to install nginx on 8080
locals {
  web_cloud_init = <<-CLOUDINIT
    #!/bin/bash
    apt-get update -y
    apt-get install -y nginx
    sed -i 's/listen 80 default_server;/listen 8080 default_server;/g' /etc/nginx/sites-available/default
    sed -i 's/listen \\[::\\]:80 default_server;/listen [::]:8080 default_server;/g' /etc/nginx/sites-available/default
    systemctl restart nginx
  CLOUDINIT
}

resource "azurerm_linux_virtual_machine_scale_set" "vmss" {
  name                = "${var.prefix}-vmss"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  sku       = "Standard_B2s"
  instances = 2

  admin_username                  = var.vm_admin_username
  admin_password                  = var.vm_admin_password
  disable_password_authentication = false

  upgrade_mode = "Automatic"

  custom_data = base64encode(local.web_cloud_init)

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  network_interface {
    name                      = "${var.prefix}-vmss-nic"
    primary                   = true
    network_security_group_id = azurerm_network_security_group.nsg.id

    ip_configuration {
      name      = "vmss-ipconfig"
      primary   = true
      subnet_id = azurerm_subnet.subnet.id

      load_balancer_backend_address_pool_ids = [
        azurerm_lb_backend_address_pool.bepool.id
      ]
    }
  }

  # Optional tags
  tags = {
    environment = "poc"
    project     = "zantac-migration"
  }
}

# -------------------------
# Autoscale – scale between 1 and 4 instances on CPU
# -------------------------
resource "azurerm_monitor_autoscale_setting" "vmss_autoscale" {
  name                = "${var.prefix}-vmss-autoscale"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  target_resource_id  = azurerm_linux_virtual_machine_scale_set.vmss.id

  profile {
    name = "cpu-based-autoscale"

    capacity {
      default = 2
      minimum = 1
      maximum = 4
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.vmss.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 75
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.vmss.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = 25
      }

      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }
  }
}

# -------------------------
# RBAC – operator can restart only this VMSS (web server)
# -------------------------
resource "azurerm_role_assignment" "vmss_operator" {
  scope                = azurerm_linux_virtual_machine_scale_set.vmss.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = var.operator_object_id
}
