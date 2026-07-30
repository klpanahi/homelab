# Cloud-init user-data: creates the ubuntu user and installs qemu-guest-agent.
# Docker itself is intentionally NOT installed here — Ansible (geerlingguy.docker)
# owns Docker so config is managed in one place. The guest agent stays because the
# Proxmox dynamic inventory relies on it to report the VM's IP to Ansible.
resource "proxmox_virtual_environment_file" "docker_cloud_init" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    data      = <<-EOF
      #cloud-config
      hostname: docker
      package_update: true
      users:
        - name: ubuntu
          groups: sudo
          shell: /bin/bash
          sudo: ALL=(ALL) NOPASSWD:ALL
          ssh_authorized_keys:
            - ${var.docker_ssh_public_key}
      packages:
        - qemu-guest-agent
      runcmd:
        - systemctl enable --now qemu-guest-agent
      EOF
    file_name = "docker-cloud-init.yaml"
  }
}

locals {
  docker_network_config = var.docker_static_ip != "" ? yamlencode({
    version = 2
    ethernets = {
      primary = {
        match       = { name = "e*" }
        dhcp4       = false
        addresses   = [var.docker_static_ip]
        routes      = [{ to = "default", via = var.docker_gateway }]
        nameservers = { addresses = [var.docker_nameserver] }
      }
    }
    }) : yamlencode({
    version = 2
    ethernets = {
      primary = {
        match       = { name = "e*" }
        dhcp4       = true
        nameservers = { addresses = [var.docker_nameserver] }
      }
    }
  })
}

resource "proxmox_virtual_environment_file" "docker_network_config" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    data      = local.docker_network_config
    file_name = "docker-network-config.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "docker" {
  name      = "docker"
  node_name = var.proxmox_node
  vm_id     = var.docker_vm_id

  tags = ["ansible", "docker"]

  machine = "q35"
  on_boot = true
  started = true

  agent {
    enabled = true
    timeout = "8m"
  }

  cpu {
    cores = var.docker_cpu_cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.docker_memory_mb
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
    size         = var.docker_disk_gb
  }

  operating_system {
    type = "l26"
  }

  initialization {
    user_data_file_id    = proxmox_virtual_environment_file.docker_cloud_init.id
    network_data_file_id = proxmox_virtual_environment_file.docker_network_config.id
  }
}
