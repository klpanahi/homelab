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

# ── nginx VM ─────────────────────────────────────────────────────────────────

variable "nginx_vm_id" {
  description = "Proxmox VM ID for the nginx VM"
  type        = number
  default     = 201
}

variable "nginx_cpu_cores" {
  description = "Number of vCPU cores for the nginx VM"
  type        = number
  default     = 1
}

variable "nginx_memory_mb" {
  description = "RAM in MB for the nginx VM"
  type        = number
  default     = 1024
}

variable "nginx_disk_gb" {
  description = "Root disk size in GB for the nginx VM"
  type        = number
  default     = 20
}

variable "ssh_public_key" {
  description = "SSH public key injected into the nginx VM (ubuntu user)"
  type        = string
}

variable "nginx_ssh_public_key" {
  description = "SSH public key injected into the nginx VM (ubuntu user)"
  type        = string
}

variable "nginx_static_ip" {
  description = "Static IP with CIDR for the nginx VM, e.g. 192.168.68.101/24. Leave empty for DHCP."
  type        = string
  default     = ""
}

variable "nginx_gateway" {
  description = "Gateway for nginx VM static IP (required when nginx_static_ip is set)"
  type        = string
  default     = ""
}

variable "nginx_nameserver" {
  description = "DNS nameserver for the nginx VM"
  type        = string
  default     = "8.8.8.8"
}

# ── docker VM ─────────────────────────────────────────────────────────────────

variable "docker_vm_id" {
  description = "Proxmox VM ID for the docker VM"
  type        = number
  default     = 202
}

variable "docker_cpu_cores" {
  description = "Number of vCPU cores for the docker VM"
  type        = number
  default     = 2
}

variable "docker_memory_mb" {
  description = "RAM in MB for the docker VM"
  type        = number
  default     = 2048
}

variable "docker_disk_gb" {
  description = "Root disk size in GB for the docker VM"
  type        = number
  default     = 20
}

variable "docker_ssh_public_key" {
  description = "SSH public key injected into the docker VM (ubuntu user)"
  type        = string
}

variable "docker_static_ip" {
  description = "Static IP with CIDR for the docker VM, e.g. 192.168.68.102/24. Leave empty for DHCP."
  type        = string
  default     = ""
}

variable "docker_gateway" {
  description = "Gateway for docker VM static IP (required when docker_static_ip is set)"
  type        = string
  default     = ""
}

variable "docker_nameserver" {
  description = "DNS nameserver for the docker VM"
  type        = string
  default     = "8.8.8.8"
}

# ── nginx-internal VM ────────────────────────────────────────────────────────

variable "nginx_internal_vm_id" {
  description = "Proxmox VM ID for the nginx-internal VM"
  type        = number
  default     = 203
}

variable "nginx_internal_cpu_cores" {
  description = "Number of vCPU cores for the nginx-internal VM"
  type        = number
  default     = 1
}

variable "nginx_internal_memory_mb" {
  description = "RAM in MB for the nginx-internal VM"
  type        = number
  default     = 1024
}

variable "nginx_internal_disk_gb" {
  description = "Root disk size in GB for the nginx-internal VM"
  type        = number
  default     = 20
}

variable "nginx_internal_static_ip" {
  description = "Static IP with CIDR for the nginx-internal VM, e.g. 192.168.68.103/24. Leave empty for DHCP."
  type        = string
  default     = ""
}

variable "nginx_internal_gateway" {
  description = "Gateway for nginx-internal VM static IP (required when nginx_internal_static_ip is set)"
  type        = string
  default     = ""
}

variable "nginx_internal_nameserver" {
  description = "DNS nameserver for the nginx-internal VM"
  type        = string
  default     = "8.8.8.8"
}
