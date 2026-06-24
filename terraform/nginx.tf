# Prerequisites:
#   1. Enable "Snippets" on local storage in Proxmox:
#      Datacenter → Storage → local → Edit → Content → check Snippets
#   2. Set nginx_ssh_public_key in terraform.tfvars

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

# Cloud-init user-data: creates the ubuntu user and installs qemu-guest-agent.
# nginx itself is intentionally NOT installed here — Ansible (geerlingguy.nginx)
# owns nginx so config is managed in one place. The guest agent stays because the
# Proxmox dynamic inventory relies on it to report the VM's IP to Ansible.
resource "proxmox_virtual_environment_file" "nginx_cloud_init" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    data      = <<-EOF
      #cloud-config
      package_update: true
      users:
        - name: ubuntu
          groups: sudo
          shell: /bin/bash
          sudo: ALL=(ALL) NOPASSWD:ALL
          ssh_authorized_keys:
            - ${var.nginx_ssh_public_key}
      packages:
        - qemu-guest-agent
      runcmd:
        - systemctl enable --now qemu-guest-agent
      EOF
    file_name = "nginx-cloud-init.yaml"
  }
}

# Cloud-init network-config (v2). Proxmox's auto-generated network data forces
# the NIC to rename to "eth0" via cloud-init v1; on Ubuntu 24.04 the interface
# enumerates as ens18/enp0s18 and that rename silently fails, leaving the guest
# with no network (and therefore no apt, no qemu-guest-agent). Matching by
# interface-name glob instead binds DHCP/static to whatever the real name is.
locals {
  nginx_network_config = var.nginx_static_ip != "" ? yamlencode({
    version = 2
    ethernets = {
      primary = {
        match       = { name = "e*" }
        dhcp4       = false
        addresses   = [var.nginx_static_ip]
        routes      = [{ to = "default", via = var.nginx_gateway }]
        nameservers = { addresses = [var.nginx_nameserver] }
      }
    }
    }) : yamlencode({
    version = 2
    ethernets = {
      primary = {
        match       = { name = "e*" }
        dhcp4       = true
        nameservers = { addresses = [var.nginx_nameserver] }
      }
    }
  })
}

resource "proxmox_virtual_environment_file" "nginx_network_config" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    data      = local.nginx_network_config
    file_name = "nginx-network-config.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "nginx" {
  name      = "nginx"
  node_name = var.proxmox_node
  vm_id     = var.nginx_vm_id

  # Tags drive the Ansible dynamic inventory: the community.proxmox.proxmox
  # plugin reads these into proxmox_tags_parsed and keys groups off them
  # (the "nginx" tag becomes the tag_nginx group that site.yml targets).
  tags = ["ansible", "nginx"]

  machine = "q35"
  on_boot = true
  started = true

  agent {
    enabled = true
    # Bound the wait. Once networking works the agent comes up within a few
    # minutes of first boot; if it doesn't, fail fast instead of blocking 15m.
    timeout = "8m"
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
    file_id      = proxmox_download_file.ubuntu_noble_cloud_image.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = var.nginx_disk_gb
  }

  operating_system {
    type = "l26"
  }

  initialization {
    # Networking is fully owned by the custom network-config snippet below
    # (matches the NIC by name glob to dodge the eth0 rename failure). Do not
    # also set ip_config here — Proxmox would emit a conflicting ipconfig0.
    user_data_file_id    = proxmox_virtual_environment_file.nginx_cloud_init.id
    network_data_file_id = proxmox_virtual_environment_file.nginx_network_config.id
  }
}
