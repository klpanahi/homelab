# The Immich VM runs on homelab1 because homelab2 has no RAM left (see the
# Hardware section in agent.md). Like backup.tf, every resource here picks that
# cluster node with node_name = var.proxmox_homelab1_node; the default provider
# reaches it through the cluster API (docs/cluster.md).
#
# Photos and Immich's databases live on a second disk (virtio1), so the root
# disk can be rebuilt without touching the library. Ansible formats and mounts
# it at /srv/immich (ansible/roles/immich). Its backups go off this host, to
# the restic server on the docker VM (homelab2).
#

# homelab1 needs its own copy of the cloud image: the "local" datastore is
# per-node, so ubuntu_noble_cloud_image in nginx.tf only exists on homelab2.
resource "proxmox_download_file" "ubuntu_noble_cloud_image_homelab1" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = var.proxmox_homelab1_node

  url       = "https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img"
  file_name = "ubuntu-24.04-server-cloudimg-amd64.img"
  overwrite = false
}

resource "proxmox_virtual_environment_file" "immich_cloud_init" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_homelab1_node

  source_raw {
    data      = <<-EOF
      #cloud-config
      hostname: immich
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
    file_name = "immich-cloud-init.yaml"
  }
}

resource "proxmox_virtual_environment_file" "immich_network_config" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_homelab1_node

  source_raw {
    data = yamlencode({
      version = 2
      ethernets = {
        primary = {
          match       = { name = "e*" }
          dhcp4       = false
          addresses   = [var.immich_static_ip]
          routes      = [{ to = "default", via = var.immich_gateway }]
          nameservers = { addresses = [var.immich_nameserver] }
        }
      }
    })
    file_name = "immich-network-config.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "immich" {
  name      = "immich"
  node_name = var.proxmox_homelab1_node
  vm_id     = var.immich_vm_id

  tags = ["ansible", "immich"]

  machine = "q35"
  on_boot = true
  started = true

  agent {
    enabled = true
    timeout = "8m"
  }

  cpu {
    cores = var.immich_cpu_cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.immich_memory_mb
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
    size         = var.immich_disk_gb
  }

  # Photo libraries and Postgres data for every Immich instance.
  disk {
    datastore_id = "local-lvm"
    interface    = "virtio1"
    iothread     = true
    discard      = "on"
    file_format  = "raw"
    size         = var.immich_data_disk_gb
  }

  operating_system {
    type = "l26"
  }

  initialization {
    user_data_file_id    = proxmox_virtual_environment_file.immich_cloud_init.id
    network_data_file_id = proxmox_virtual_environment_file.immich_network_config.id
  }

  # Same reason as the other VMs: a changed cloud-init snippet would REPLACE the
  # VM, and with it the data disk.
  lifecycle {
    ignore_changes = [initialization]
  }
}
