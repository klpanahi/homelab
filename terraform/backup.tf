# The backup guest is deliberately provisioned on homelab1, a physically
# separate Proxmox host from homelab2 (where most guests in this repo live), so
# that a homelab2 failure — hardware, storage, or otherwise — cannot take out
# the backups along with the things they're backing up. The two hosts are one
# Proxmox cluster, so the default provider reaches homelab1 too; every resource
# below picks it with node_name = var.proxmox_homelab1_node. Don't migrate this
# container to homelab2 — that would defeat the point.
#
# It runs as an unprivileged LXC, the same shape as the nginx guests
# (terraform/nginx.tf): the backup role is only Python, ssh and the Postgres
# client on systemd timers, so a VM spent most of its RAM on Ubuntu itself.

# homelab1 needs its own copy of the LXC template: the "local" datastore is
# per-node, so ubuntu_noble_lxc_template in nginx.tf only exists on homelab2.
resource "proxmox_download_file" "ubuntu_noble_lxc_template_homelab1" {
  content_type = "vztmpl"
  datastore_id = "local"
  node_name    = var.proxmox_homelab1_node

  url       = "http://download.proxmox.com/images/system/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
  file_name = "ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
  overwrite = false
}

resource "proxmox_virtual_environment_container" "backup" {
  node_name = var.proxmox_homelab1_node
  vm_id     = var.backup_vm_id

  tags = ["ansible", "backup"]

  unprivileged  = true
  start_on_boot = true
  started       = true

  # systemd in Ubuntu 24.04 needs nesting to set up its service sandboxes
  # inside an unprivileged container.
  features {
    nesting = true
  }

  initialization {
    hostname = "backup"

    ip_config {
      ipv4 {
        address = var.backup_static_ip != "" ? var.backup_static_ip : "dhcp"
        gateway = var.backup_static_ip != "" ? var.backup_gateway : null
      }
    }

    dns {
      servers = [var.backup_nameserver]
    }

    # Proxmox installs this key for root; LXCs are reached as root
    # (ansible/inventory/proxmox.yml).
    user_account {
      keys = [trimspace(var.ssh_public_key)]
    }
  }

  cpu {
    cores = var.backup_cpu_cores
  }

  memory {
    dedicated = var.backup_memory_mb
    swap      = var.backup_memory_mb
  }

  network_interface {
    name   = "eth0"
    bridge = var.vm_network_bridge
  }

  # The rootfs is the backup store itself (/var/backups/homelab), so size it
  # against homelab1's free space.
  disk {
    datastore_id = "local-lvm"
    size         = var.backup_disk_gb
  }

  operating_system {
    template_file_id = proxmox_download_file.ubuntu_noble_lxc_template_homelab1.id
    type             = "ubuntu"
  }

  # A new template or initialization block would make the provider REPLACE the
  # container, wiping every backup on it. Rebuild deliberately with
  # terraform apply -replace=<this resource>, after copying
  # /var/backups/homelab off.
  lifecycle {
    ignore_changes = [initialization, operating_system]
  }
}
