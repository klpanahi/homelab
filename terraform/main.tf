terraform {
  required_version = ">= 1.6"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.78"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = true # self-signed cert on LAN

  ssh {
    username = "root"

    # Read the key file directly rather than relying on ssh-agent, matching the
    # HAOS null_resource pattern.
    private_key = file(pathexpand(var.proxmox_ssh_private_key_path))

    # The provider uploads snippets (cloud-init) over SSH and needs to know how
    # to reach the node. It can't resolve "homelab2" on its own, so map it to
    # the known SSH host explicitly.
    node {
      name    = var.proxmox_node
      address = var.proxmox_ssh_host
    }
  }
}
