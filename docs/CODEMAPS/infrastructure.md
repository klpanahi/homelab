<!-- Generated: 2026-09-13 | Files scanned: 8 | Token estimate: ~680 -->

# Terraform Infrastructure

## Files

```
terraform/
  main.tf                  provider config (proxmox default alias + proxmox.homelab1 alias + null)
  homelab2.tf              HAOS VM provisioning (null_resource, SSH remote-exec)
  nginx.tf                 nginx VM (bpg VM resource + cloud-init snippets)
  nginx-internal.tf        LAN-only nginx VM
  docker.tf                Docker host VM
  router.tf                lab subnet router/NAT VM (two IPs on one vNIC)
  backup.tf                backup VM on homelab1 (bpg VM resource + cloud-init snippets)
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

### backup VM (backup.tf)
Provisioned on **homelab1** — a separate, standalone Proxmox host from every
other VM in this repo (see Provider Config below), so a homelab2 failure
can't take the backups out along with the things they back up. Every resource
here carries `provider = proxmox.homelab1`; a resource that forgets it
silently targets homelab2 instead.
- `proxmox_download_file.ubuntu_noble_cloud_image_homelab1` — homelab1 needs
  its own copy of the Ubuntu 24.04 cloud image; the one in nginx.tf is bound
  to the default (homelab2) provider and can't be reused across the alias
  boundary.
- `proxmox_virtual_environment_file.backup_cloud_init` — cloud-init user-data:
  creates `ubuntu` user + installs `qemu-guest-agent` only. **The backup
  software itself is NOT installed here** — Ansible's `backup` role owns it,
  same division of labor as nginx.
- `proxmox_virtual_environment_file.backup_network_config` — cloud-init v2
  network-config, same NIC name-glob (`e*`) pattern as nginx.tf; static or
  DHCP per `backup_static_ip`.
- `proxmox_virtual_environment_vm.backup` — VM ID 300 (`var.backup_vm_id`),
  Q35, virtio disk on `local-lvm` sized by `backup_disk_gb` (this disk **is**
  the backup store — size against homelab1's free space), agent enabled (8m
  timeout). **`tags = ["ansible", "backup"]`** drive the Ansible dynamic
  inventory grouping (`tag_backup`).

### router VM (router.tf)
- `proxmox_virtual_environment_file.router_cloud_init` — ubuntu user +
  `qemu-guest-agent`. Forwarding/nftables are Ansible's (`roles/router`).
- `proxmox_virtual_environment_file.router_network_config` — cloud-init v2
  network-config putting **two addresses on one NIC** (`router_lan_ip` +
  `router_lab_ip`), single default route via the Deco.
- `proxmox_virtual_environment_vm.router` — VM ID 204,
  **`tags = ["ansible", "router"]`** → `tag_router` group. NIC MAC pinned
  (`router_mac_address`) so the Deco can reserve the LAN address.
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
| `router_lan_ip` | `192.168.68.100/22` | LAN-side address, inside the Deco pool + MAC-reserved |
| `router_mac_address` | `BC:24:11:00:02:04` | pinned NIC MAC for the Deco address reservation |
| `router_lab_ip` | `10.10.10.1/24` | lab-side gateway address, same vNIC |
| `router_lan_gateway` | `192.168.68.1` | router VM's only default route |
| `router_cpu_cores` / `router_memory_mb` / `router_disk_gb` | `1` / `1024` / `10` | sizing |
| `proxmox_homelab1_endpoint` | `https://192.168.68.75:8006` | API URL for standalone homelab1 host |
| `proxmox_homelab1_api_token` | — | sensitive; homelab1's OWN token — homelab1 and homelab2 are not clustered and don't share a user/token database |
| `proxmox_homelab1_node` | — | node name as reported by homelab1's own `/api2/json/nodes`; not knowable in advance, must be queried |
| `proxmox_homelab1_ssh_host` | `192.168.68.75` | SSH target for homelab1 root |
| `backup_vm_id` | `300` | Proxmox VM ID |
| `backup_cpu_cores` / `backup_memory_mb` / `backup_disk_gb` | `2` / `2048` / `100` | sizing; disk is the backup store itself |
| `backup_static_ip` / `_gateway` / `_nameserver` | `""` / `""` / `8.8.8.8` | empty = DHCP |

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

# homelab1 is a SEPARATE, standalone Proxmox install — not a cluster member
# with homelab2. Its /api2/json/nodes lists only itself, and homelab2's API
# token gets a 401 there, so it gets its own endpoint, token, and provider
# alias. Resources targeting it MUST set provider = proxmox.homelab1 —
# anything that forgets that argument silently lands on homelab2 instead.
provider "proxmox" {
  alias     = "homelab1"
  endpoint  = var.proxmox_homelab1_endpoint
  api_token = var.proxmox_homelab1_api_token
  insecure  = true
  ssh {
    username    = "root"
    private_key = file(pathexpand(var.proxmox_ssh_private_key_path))
    node { name = var.proxmox_homelab1_node; address = var.proxmox_homelab1_ssh_host }
  }
}
```

## Workaround Notes

- HAOS uses `null_resource` + SSH (not the bpg VM resource): bpg v0.78+ dropped
  xz decompression and HAOS ships only `.qcow2.xz`.
- nginx and backup VMs use the bpg VM resource with a custom cloud-init
  network-config snippet (NIC name-glob match) instead of Proxmox's auto
  ipconfig.
- The router VM carries both subnets on ONE vNIC because no host has a spare NIC
  and the switch is unmanaged (no VLANs) — see [`../lab-subnet.md`](../lab-subnet.md).
- cloud-init writes network config only on first boot: changing a `*_static_ip`
  does not re-address an already-running VM (fix netplan in-guest).
- homelab1 is standalone (not clustered with homelab2), discovered live by
  querying its own `/api2/json/nodes` — hence a second provider alias, a
  second SSH `node` block, and a second API token, all scoped to homelab1
  only.
