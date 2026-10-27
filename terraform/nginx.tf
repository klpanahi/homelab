# nginx-cloudflared runs as an unprivileged LXC, not a VM: nginx and cloudflared
# need a few MB each, and a VM spent ~300 MB of its 1 GB on Ubuntu itself.
# Set nginx_ssh_public_key in terraform.tfvars.

# Downloads the Ubuntu 24.04 *standard server* cloud image to Proxmox's ISO store.
# Do NOT use the "minimal" image: its stripped-down cloud-init does not detect the
# Proxmox NoCloud (cidata ISO) datasource, so cloud-init never runs — leaving the
# guest with no network, no qemu-guest-agent, and the provider's agent wait hangs.
resource "proxmox_download_file" "ubuntu_noble_cloud_image" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = var.proxmox_node

  url       = "https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img"
  file_name = "ubuntu-24.04-server-cloudimg-amd64.img"
  overwrite = false
}

# Ubuntu 24.04 system container template for the LXC guests (nginx-cloudflared,
# nginx-internal). A system container, not an OCI app container: it runs systemd
# and sshd, so Ansible and party-time's deploy manage it exactly like a VM. OCI
# app containers are tracked on the homelab to-do list until PVE 9.
resource "proxmox_download_file" "ubuntu_noble_lxc_template" {
  content_type = "vztmpl"
  datastore_id = "local"
  node_name    = var.proxmox_node

  url       = "http://download.proxmox.com/images/system/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
  file_name = "ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
  overwrite = false
}

resource "proxmox_virtual_environment_container" "nginx" {
  node_name = var.proxmox_node
  vm_id     = var.nginx_vm_id

  # Tags drive the Ansible dynamic inventory: the community.proxmox.proxmox
  # plugin reads these into proxmox_tags_parsed and keys groups off them
  # (the "nginx" tag becomes the tag_nginx group that site.yml targets).
  tags = ["ansible", "nginx", "cloudflared"]

  unprivileged  = true
  start_on_boot = true
  started       = true

  # systemd in Ubuntu 24.04 needs nesting to set up its service sandboxes
  # inside an unprivileged container.
  features {
    nesting = true
  }

  initialization {
    hostname = "nginx-cloudflared"

    ip_config {
      ipv4 {
        address = var.nginx_static_ip != "" ? var.nginx_static_ip : "dhcp"
        gateway = var.nginx_static_ip != "" ? var.nginx_gateway : null
      }
    }

    dns {
      servers = [var.nginx_nameserver]
    }

    # Proxmox installs this key for root. LXC guests have no ubuntu user, so
    # Ansible connects as root (group_vars/proxmox_all_lxc.yml).
    user_account {
      keys = [trimspace(var.nginx_ssh_public_key)]
    }
  }

  cpu {
    cores = var.nginx_cpu_cores
  }

  memory {
    dedicated = var.nginx_memory_mb
    swap      = var.nginx_memory_mb
  }

  network_interface {
    name   = "eth0"
    bridge = var.vm_network_bridge
  }

  disk {
    datastore_id = "local-lvm"
    size         = var.nginx_disk_gb
  }

  operating_system {
    template_file_id = proxmox_download_file.ubuntu_noble_lxc_template.id
    type             = "ubuntu"
  }

  # A new template or initialization block would make the provider REPLACE the
  # container, wiping it. Rebuild deliberately with
  # terraform apply -replace=<this resource>.
  lifecycle {
    ignore_changes = [initialization, operating_system]
  }
}
