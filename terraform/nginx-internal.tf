resource "proxmox_virtual_environment_file" "nginx_internal_cloud_init" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    data      = <<-EOF
      #cloud-config
      hostname: nginx-internal
      package_update: true
      users:
        - name: ubuntu
          groups: sudo
          shell: /bin/bash
          sudo: ALL=(ALL) NOPASSWD:ALL
          ssh_authorized_keys:
            - ${var.ssh_public_key}
      packages:
        - qemu-guest-agent
      runcmd:
        - systemctl enable --now qemu-guest-agent
      EOF
    file_name = "nginx-internal-cloud-init.yaml"
  }
}

locals {
  nginx_internal_network_config = var.nginx_internal_static_ip != "" ? yamlencode({
    version = 2
    ethernets = {
      primary = {
        match       = { name = "e*" }
        dhcp4       = false
        addresses   = [var.nginx_internal_static_ip]
        routes      = [{ to = "default", via = var.nginx_internal_gateway }]
        nameservers = { addresses = [var.nginx_internal_nameserver] }
      }
    }
    }) : yamlencode({
    version = 2
    ethernets = {
      primary = {
        match       = { name = "e*" }
        dhcp4       = true
        nameservers = { addresses = [var.nginx_internal_nameserver] }
      }
    }
  })
}

resource "proxmox_virtual_environment_file" "nginx_internal_network_config" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    data      = local.nginx_internal_network_config
    file_name = "nginx-internal-network-config.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "nginx_internal" {
  name      = "nginx-internal"
  node_name = var.proxmox_node
  vm_id     = var.nginx_internal_vm_id

  tags = ["ansible", "nginx-internal"]

  machine = "q35"
  on_boot = true
  started = true

  agent {
    enabled = true
    timeout = "8m"
  }

  cpu {
    cores = var.nginx_internal_cpu_cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.nginx_internal_memory_mb
  }

  network_device {
    bridge = var.vm_network_bridge
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_download_file.ubuntu_noble_cloud_image.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = var.nginx_internal_disk_gb
  }

  operating_system {
    type = "l26"
  }

  initialization {
    user_data_file_id    = proxmox_virtual_environment_file.nginx_internal_cloud_init.id
    network_data_file_id = proxmox_virtual_environment_file.nginx_internal_network_config.id
  }
}
