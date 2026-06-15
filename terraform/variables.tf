variable "proxmox_endpoint" {
  description = "Proxmox API URL, e.g. https://192.168.68.65:8006"
  type        = string
}

variable "proxmox_api_token" {
  description = "API token in format 'user@realm!token_id=secret'"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Proxmox node name to deploy VMs on"
  type        = string
  default     = "homelab2"
}

variable "vm_network_bridge" {
  description = "Proxmox bridge for VM NICs"
  type        = string
  default     = "vmbr0"
}

variable "haos_version" {
  description = "Home Assistant OS version to deploy. Find releases at https://github.com/home-assistant/operating-system/releases"
  type        = string
}

variable "proxmox_ssh_host" {
  description = "IP or hostname used to SSH into the Proxmox node (root). Needed to download HAOS image since provider dropped xz support."
  type        = string
  default     = "192.168.68.65"
}

variable "proxmox_ssh_private_key_path" {
  description = "Path to the SSH private key for root on Proxmox nodes"
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "haos_mac_address" {
  description = "Fixed MAC address for the Home Assistant VM NIC. Keeps the VM's L2 identity stable across reboots and re-creation. Uses Proxmox's BC:24:11 OUI by convention."
  type        = string
  default     = "BC:24:11:00:02:00"
}

variable "haos_static_ip" {
  description = "Static IP with CIDR prefix for Home Assistant VM, e.g. 192.168.68.100/24. Leave empty to keep DHCP."
  type        = string
  default     = ""
}

variable "haos_gateway" {
  description = "Gateway IP for Home Assistant VM static IP config"
  type        = string
  default     = ""
}

variable "haos_nameserver" {
  description = "DNS nameserver for Home Assistant VM static IP config"
  type        = string
  default     = "8.8.8.8"
}

variable "haos_network_iface" {
  description = "Network interface name inside HAOS (enp0s18 for Q35 machine with virtio NIC)"
  type        = string
  default     = "enp0s18"
}
