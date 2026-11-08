# Gitea, the private git server (docs/gitea.md). An unprivileged LXC on homelab1,
# the same shape as the OpenBao guest (terraform/openbao.tf), whose template it
# shares.
resource "proxmox_virtual_environment_container" "gitea" {
  node_name = var.proxmox_homelab1_node
  vm_id     = var.gitea_vm_id

  tags = ["ansible", "gitea"]

  unprivileged  = true
  start_on_boot = true
  started       = true

  # systemd in Ubuntu 24.04 needs nesting to set up its service sandboxes
  # inside an unprivileged container.
  features {
    nesting = true
  }

  initialization {
    hostname = "gitea"

    ip_config {
      ipv4 {
        address = var.gitea_static_ip != "" ? var.gitea_static_ip : "dhcp"
        gateway = var.gitea_static_ip != "" ? var.gitea_gateway : null
      }
    }

    dns {
      servers = [var.gitea_nameserver]
    }

    user_account {
      keys = [trimspace(var.ssh_public_key)]
    }
  }

  cpu {
    cores = var.gitea_cpu_cores
  }

  memory {
    dedicated = var.gitea_memory_mb
    swap      = var.gitea_memory_mb
  }

  network_interface {
    name   = "eth0"
    bridge = var.vm_network_bridge
  }

  disk {
    datastore_id = "local-lvm"
    size         = var.gitea_disk_gb
  }

  operating_system {
    template_file_id = proxmox_download_file.ubuntu_noble_lxc_template_homelab1.id
    type             = "ubuntu"
  }

  # A new template or initialization block would make the provider REPLACE the
  # container, destroying every repository on it. Restore from vzdump instead
  # (docs/gitea.md).
  lifecycle {
    ignore_changes = [initialization, operating_system]
  }
}
