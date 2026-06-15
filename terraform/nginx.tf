# Prerequisites:
#   1. Enable "Snippets" on local storage in Proxmox:
#      Datacenter → Storage → local → Edit → Content → check Snippets
#   2. Set nginx_ssh_public_key in terraform.tfvars

# Downloads Ubuntu 24.04 minimal cloud image to Proxmox ISO store.
resource "proxmox_virtual_environment_download_file" "ubuntu_noble_cloud_image" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = var.proxmox_node

  url       = "https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64.img"
  file_name = "ubuntu-24.04-minimal-cloudimg-amd64.img"
  overwrite = false
}

# Cloud-init user-data: creates ubuntu user, installs nginx + qemu-guest-agent.
resource "proxmox_virtual_environment_file" "nginx_cloud_init" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    data = <<-EOF
      #cloud-config
      users:
        - name: ubuntu
          groups: sudo
          shell: /bin/bash
          sudo: ALL=(ALL) NOPASSWD:ALL
          ssh_authorized_keys:
            - ${var.nginx_ssh_public_key}
      packages:
        - nginx
        - qemu-guest-agent
      runcmd:
        - systemctl enable --now qemu-guest-agent
        - systemctl enable --now nginx
      EOF
    file_name = "nginx-cloud-init.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "nginx" {
  name      = "nginx"
  node_name = var.proxmox_node
  vm_id     = var.nginx_vm_id

  machine = "q35"
  on_boot = true
  started = true

  agent {
    enabled = true
  }

  cpu {
    cores = var.nginx_cpu_cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.nginx_memory_mb
  }

  network_device {
    bridge = var.vm_network_bridge
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_download_file.ubuntu_noble_cloud_image.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = var.nginx_disk_gb
  }

  operating_system {
    type = "l26"
  }

  initialization {
    ip_config {
      ipv4 {
        address = var.nginx_static_ip != "" ? var.nginx_static_ip : "dhcp"
        gateway = var.nginx_static_ip != "" ? var.nginx_gateway : null
      }
    }

    dns {
      servers = [var.nginx_nameserver]
    }

    user_data_file_id = proxmox_virtual_environment_file.nginx_cloud_init.id
  }
}
