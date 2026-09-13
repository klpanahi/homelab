<!-- Generated: 2026-09-13 | Files scanned: 8 | Token estimate: ~680 -->

# Terraform Infrastructure

## Files

```
terraform/
  main.tf                  provider config (proxmox bpg + null)
  homelab2.tf              HAOS VM provisioning (null_resource, SSH remote-exec)
  nginx.tf                 nginx VM (bpg VM resource + cloud-init snippets)
  nginx-internal.tf        LAN-only nginx VM
  docker.tf                Docker host VM
  router.tf                lab subnet router/NAT VM (two IPs on one vNIC)
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

### router VM (router.tf)
- `proxmox_virtual_environment_file.router_cloud_init` — ubuntu user +
  `qemu-guest-agent`. Forwarding/nftables are Ansible's (`roles/router`).
- `proxmox_virtual_environment_file.router_network_config` — cloud-init v2
  network-config putting **two addresses on one NIC** (`router_lan_ip` +
  `router_lab_ip`), single default route via the Deco.
- `proxmox_virtual_environment_vm.router` — VM ID 204,
  **`tags = ["ansible", "router"]`** → `tag_router` group.
  Gateway for the routed lab subnet; see [`../lab-subnet.md`](../lab-subnet.md).

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
| `docker_*` / `nginx_internal_*` | see file | same sizing + static-IP pattern per VM |
| `router_vm_id` | `204` | lab router VM |
| `router_lan_ip` | `192.168.68.50/22` | LAN-side address (Deco LAN is a /22) |
| `router_lab_ip` | `10.10.10.1/24` | lab-side gateway address, same vNIC |
| `router_lan_gateway` | `192.168.68.1` | router VM's only default route |
| `router_cpu_cores` / `router_memory_mb` / `router_disk_gb` | `1` / `1024` / `10` | sizing |

A VM joins the lab subnet by pointing its existing `*_static_ip` / `*_gateway`
at the lab range — no new Terraform resources.

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
- The router VM carries both subnets on ONE vNIC because no host has a spare NIC
  and the switch is unmanaged (no VLANs) — see [`../lab-subnet.md`](../lab-subnet.md).
- cloud-init writes network config only on first boot: changing a `*_static_ip`
  does not re-address an already-running VM (fix netplan in-guest).
