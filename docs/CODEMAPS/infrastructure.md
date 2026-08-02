<!-- Generated: 2026-06-23 | Files scanned: 5 | Token estimate: ~560 -->

# Terraform Infrastructure

## Files

```
terraform/
  main.tf                  provider config (proxmox bpg + null)
  homelab2.tf              HAOS VM provisioning (null_resource, SSH remote-exec)
  nginx.tf                 nginx VM (bpg VM resource + cloud-init snippets)
  variables.tf             all input variables
  terraform.tfvars         live values (gitignored)
  terraform.tfvars.example documented example values
  .terraform.lock.hcl      provider lock file
```

## Resources

### `null_resource.homeassistant` (homelab2.tf:4)
Manages HAOS VM lifecycle (VM ID 200) via SSH remote-exec to Proxmox root —
downloads/decompresses the `.qcow2.xz`, creates a Q35 VM, imports the disk,
boots it. Destroy = `qm stop && qm destroy --purge`. Idempotent.

### `null_resource.homeassistant_network` (homelab2.tf:75)
Sets HAOS static IP via the QEMU guest agent CLI; only when `haos_static_ip != ""`.

### nginx VM (nginx.tf)
- `proxmox_download_file.ubuntu_noble_cloud_image` — Ubuntu 24.04 **standard**
  cloud image (not minimal — minimal's cloud-init misses the NoCloud datasource).
- `proxmox_virtual_environment_file.nginx_cloud_init` — cloud-init user-data:
  creates `ubuntu` user + installs `qemu-guest-agent` only. **nginx is NOT
  installed here** — Ansible owns it.
- `proxmox_virtual_environment_file.nginx_network_config` — cloud-init v2
  network-config matching NIC by name glob (`e*`) to dodge the eth0-rename
  failure on Ubuntu 24.04; static or DHCP per `nginx_static_ip`.
- `proxmox_virtual_environment_vm.nginx` (nginx.tf:88) — VM ID 201, Q35,
  virtio disk on `local-lvm`, agent enabled (8m timeout).
  **`tags = ["ansible", "nginx"]`** drive the Ansible dynamic inventory grouping.

## Key Variables (variables.tf)

| Variable | Default | Notes |
|---|---|---|
| `proxmox_endpoint` | — | `https://<host>:8006` |
| `proxmox_api_token` | — | sensitive; `user@realm!token_id=secret` (root@pam!terraform) |
| `proxmox_node` | `homelab2` | Proxmox node name |
| `proxmox_ssh_host` | `192.168.68.65` | SSH target for remote-exec |
| `proxmox_ssh_private_key_path` | `~/.ssh/id_ed25519` | SSH key for root |
| `vm_network_bridge` | `vmbr0` | Proxmox bridge |
| `haos_version` | — | e.g. `17.3`; from HAOS releases |
| `haos_static_ip` / `_gateway` / `_nameserver` / `_network_iface` | see file | HAOS net |
| `haos_mac_address` | `BC:24:11:00:02:00` | pinned NIC MAC for DHCP reservation |
| `nginx_vm_id` | `201` | Proxmox VM ID |
| `nginx_cpu_cores` / `nginx_memory_mb` / `nginx_disk_gb` | `1` / `1024` / `20` | sizing |
| `nginx_ssh_public_key` | — | injected into ubuntu user |
| `nginx_static_ip` / `_gateway` / `_nameserver` | `""` / `""` / `8.8.8.8` | empty = DHCP |

## Provider Config (main.tf)

```hcl
provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = true  # self-signed cert on LAN
  ssh {
    username    = "root"
    private_key = file(pathexpand(var.proxmox_ssh_private_key_path))
    node { name = var.proxmox_node; address = var.proxmox_ssh_host }
  }
}
```

## Workaround Notes

- HAOS uses `null_resource` + SSH (not the bpg VM resource): bpg v0.78+ dropped
  xz decompression and HAOS ships only `.qcow2.xz`.
- nginx VM uses the bpg VM resource with a custom cloud-init network-config
  snippet (NIC name-glob match) instead of Proxmox's auto ipconfig.
