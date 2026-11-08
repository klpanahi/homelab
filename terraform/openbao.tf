# OpenBao, the homelab's credential manager (docs/openbao.md). An unprivileged
# LXC on homelab1, the same shape as the backup guest (terraform/backup.tf),
# whose template it shares. Terraform and Ansible on the operator's Mac are its
# only clients: guests get their secrets rendered at deploy time, so nothing at
# runtime depends on it being up or unsealed.
resource "proxmox_virtual_environment_container" "openbao" {
  node_name = var.proxmox_homelab1_node
  vm_id     = var.openbao_vm_id

  tags = ["ansible", "openbao"]

  unprivileged  = true
  start_on_boot = true
  started       = true

  # systemd in Ubuntu 24.04 needs nesting to set up its service sandboxes
  # inside an unprivileged container.
  features {
    nesting = true
  }

  initialization {
    hostname = "openbao"

    ip_config {
      ipv4 {
        address = var.openbao_static_ip != "" ? var.openbao_static_ip : "dhcp"
        gateway = var.openbao_static_ip != "" ? var.openbao_gateway : null
      }
    }

    dns {
      servers = [var.openbao_nameserver]
    }

    user_account {
      keys = [trimspace(var.ssh_public_key)]
    }
  }

  cpu {
    cores = var.openbao_cpu_cores
  }

  memory {
    dedicated = var.openbao_memory_mb
    swap      = var.openbao_memory_mb
  }

  network_interface {
    name   = "eth0"
    bridge = var.vm_network_bridge
  }

  disk {
    datastore_id = "local-lvm"
    size         = var.openbao_disk_gb
  }

  operating_system {
    template_file_id = proxmox_download_file.ubuntu_noble_lxc_template_homelab1.id
    type             = "ubuntu"
  }

  # A new template or initialization block would make the provider REPLACE the
  # container, destroying the encrypted store. Restore from vzdump instead
  # (docs/openbao.md).
  lifecycle {
    ignore_changes = [initialization, operating_system]
  }
}
