# nginx-internal runs as an unprivileged LXC from the same template as
# nginx-cloudflared (terraform/nginx.tf).
resource "proxmox_virtual_environment_container" "nginx_internal" {
  node_name = var.proxmox_node
  vm_id     = var.nginx_internal_vm_id

  tags = ["ansible", "nginx-internal"]

  unprivileged  = true
  start_on_boot = true
  started       = true

  features {
    nesting = true
  }

  initialization {
    hostname = "nginx-internal"

    ip_config {
      ipv4 {
        address = var.nginx_internal_static_ip != "" ? var.nginx_internal_static_ip : "dhcp"
        gateway = var.nginx_internal_static_ip != "" ? var.nginx_internal_gateway : null
      }
    }

    dns {
      servers = [var.nginx_internal_nameserver]
    }

    user_account {
      keys = [trimspace(var.ssh_public_key)]
    }
  }

  cpu {
    cores = var.nginx_internal_cpu_cores
  }

  memory {
    dedicated = var.nginx_internal_memory_mb
    swap      = var.nginx_internal_memory_mb
  }

  network_interface {
    name   = "eth0"
    bridge = var.vm_network_bridge
  }

  disk {
    datastore_id = "local-lvm"
    size         = var.nginx_internal_disk_gb
  }

  operating_system {
    template_file_id = proxmox_download_file.ubuntu_noble_lxc_template.id
    type             = "ubuntu"
  }

  lifecycle {
    ignore_changes = [initialization, operating_system]
  }
}
