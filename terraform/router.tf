# Lab router / NAT gateway ("router on a stick").
#
# Gives lab VMs addresses from a private CIDR (10.10.10.0/24) that is distinct
# from the range the home router hands out (192.168.68.0/22), without VLANs or
# new hardware — the unmanaged switch cannot trunk, and neither Proxmox host has
# a spare NIC.
#
# The VM has ONE vNIC on the existing vmbr0 bridge carrying TWO addresses:
#   - router_lan_ip  (e.g. 192.168.68.100/22) — reachable from the Deco and the LAN,
#     held by a Deco address reservation bound to router_mac_address
#   - router_lab_ip  (e.g. 10.10.10.1/24)    — default gateway for lab VMs
# Lab VMs on EITHER Proxmox host reach it over the shared broadcast domain.
#
# Forwarding, the nftables masquerade ruleset and the firewall policy are owned
# by Ansible (roles/router), matching the repo split: Terraform owns VM lifecycle
# and addressing, Ansible owns in-guest config. See docs/lab-subnet.md.
#
# NOTE: this is address-space separation, NOT isolation — lab VMs stay on the
# same L2 segment as the rest of the LAN.

resource "proxmox_virtual_environment_file" "router_cloud_init" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    data      = <<-EOF
      #cloud-config
      hostname: router
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
    file_name = "router-cloud-init.yaml"
  }
}

# Both addresses live on the same NIC (single interface, two subnets). The NIC is
# matched by name glob for the same reason as the other VMs: Ubuntu 24.04
# enumerates it as ens18/enp0s18 and cloud-init's eth0 rename silently fails.
#
# Only ONE default route — via the Deco. The lab side is a connected route, so
# no static routes are needed on the router itself.
locals {
  router_network_config = yamlencode({
    version = 2
    ethernets = {
      primary = {
        match       = { name = "e*" }
        dhcp4       = false
        addresses   = [var.router_lan_ip, var.router_lab_ip]
        routes      = [{ to = "default", via = var.router_lan_gateway }]
        nameservers = { addresses = [var.router_nameserver] }
      }
    }
  })
}

resource "proxmox_virtual_environment_file" "router_network_config" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    data      = local.router_network_config
    file_name = "router-network-config.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "router" {
  name      = "router"
  node_name = var.proxmox_node
  vm_id     = var.router_vm_id

  # The "router" tag becomes the tag_router Ansible group that site.yml targets.
  tags = ["ansible", "router"]

  machine = "q35"
  on_boot = true
  started = true

  agent {
    enabled = true
    timeout = "8m"
  }

  cpu {
    cores = var.router_cpu_cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.router_memory_mb
  }

  # The MAC is pinned so the Deco can hold an address reservation for
  # router_lan_ip. The address has to sit inside the DHCP pool (the Deco refuses
  # reservations outside its own range), so the reservation is the only thing
  # keeping it — and losing it takes the whole lab subnet offline. Create the
  # reservation before applying.
  network_device {
    bridge      = var.vm_network_bridge
    mac_address = var.router_mac_address
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_download_file.ubuntu_noble_cloud_image.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = var.router_disk_gb
  }

  operating_system {
    type = "l26"
  }

  initialization {
    user_data_file_id    = proxmox_virtual_environment_file.router_cloud_init.id
    network_data_file_id = proxmox_virtual_environment_file.router_network_config.id
  }
}
