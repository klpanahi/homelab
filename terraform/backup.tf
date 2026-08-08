# The backup VM is deliberately provisioned on homelab1, a physically separate
# Proxmox host from homelab2 (where every other VM in this repo lives), so that
# a homelab2 failure — hardware, storage, or otherwise — cannot take out the
# backups along with the things they're backing up. Every resource below must
# carry `provider = proxmox.homelab1` and use var.proxmox_homelab1_node; a
# resource that forgets the provider argument silently targets homelab2
# instead and could disturb live production VMs there.
#
# The guest agent is required because the Ansible dynamic inventory resolves
# ansible_host from the agent-reported IP, same as every other VM here.

# homelab1 needs its own copy of the cloud image: proxmox_download_file.
# ubuntu_noble_cloud_image in nginx.tf is bound to homelab2's default provider
# and can't be reused across the provider boundary.
resource "proxmox_download_file" "ubuntu_noble_cloud_image_homelab1" {
  provider = proxmox.homelab1

  content_type = "iso"
  datastore_id = "local"
  node_name    = var.proxmox_homelab1_node

  url       = "https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img"
  file_name = "ubuntu-24.04-server-cloudimg-amd64.img"
  overwrite = false
}

# Cloud-init user-data: creates the ubuntu user and installs qemu-guest-agent.
# The backup software itself is intentionally NOT installed here — Ansible
# owns that so config is managed in one place. The guest agent stays because
# the Proxmox dynamic inventory relies on it to report the VM's IP to Ansible.
resource "proxmox_virtual_environment_file" "backup_cloud_init" {
  provider = proxmox.homelab1

  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_homelab1_node

  source_raw {
    data      = <<-EOF
      #cloud-config
      hostname: backup
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
    file_name = "backup-cloud-init.yaml"
  }
}

locals {
  backup_network_config = var.backup_static_ip != "" ? yamlencode({
    version = 2
    ethernets = {
      primary = {
        match       = { name = "e*" }
        dhcp4       = false
        addresses   = [var.backup_static_ip]
        routes      = [{ to = "default", via = var.backup_gateway }]
        nameservers = { addresses = [var.backup_nameserver] }
      }
    }
    }) : yamlencode({
    version = 2
    ethernets = {
      primary = {
        match       = { name = "e*" }
        dhcp4       = true
        nameservers = { addresses = [var.backup_nameserver] }
      }
    }
  })
}

resource "proxmox_virtual_environment_file" "backup_network_config" {
  provider = proxmox.homelab1

  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_homelab1_node

  source_raw {
    data      = local.backup_network_config
    file_name = "backup-network-config.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "backup" {
  provider = proxmox.homelab1

  name      = "backup"
  node_name = var.proxmox_homelab1_node
  vm_id     = var.backup_vm_id

  tags = ["ansible", "backup"]

  machine = "q35"
  on_boot = true
  started = true

  agent {
    enabled = true
    timeout = "8m"
  }

  cpu {
    cores = var.backup_cpu_cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.backup_memory_mb
  }

  network_device {
    bridge = var.vm_network_bridge
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_download_file.ubuntu_noble_cloud_image_homelab1.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = var.backup_disk_gb
  }

  operating_system {
    type = "l26"
  }

  initialization {
    user_data_file_id    = proxmox_virtual_environment_file.backup_cloud_init.id
    network_data_file_id = proxmox_virtual_environment_file.backup_network_config.id
  }
}
