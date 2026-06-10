<!-- Generated: 2026-06-10 | Files scanned: 4 | Token estimate: ~400 -->

# Terraform Infrastructure

## Files

```
terraform/
  main.tf                  provider config (proxmox bpg + null)
  homelab2.tf              HAOS VM provisioning (null_resource, SSH remote-exec)
  variables.tf             all input variables
  terraform.tfvars         live values (gitignored)
  terraform.tfvars.example documented example values
  .terraform.lock.hcl      provider lock file
```

## Resources

### `null_resource.homeassistant` (homelab2.tf:4)
Manages full HAOS VM lifecycle (VM ID 200) via SSH remote-exec to Proxmox root.
- **create**: downloads `haos_ova-<version>.qcow2.xz` from GitHub, decompresses, creates Q35 VM, imports disk, sets boot order, starts VM
- **destroy**: `qm stop 200 && qm destroy 200 --purge`
- Idempotent: skips steps if VM/disk already exists

### `null_resource.homeassistant_network` (homelab2.tf:63)
Configures static IP inside HAOS via QEMU guest agent CLI.
- Only created when `haos_static_ip != ""`
- Depends on `null_resource.homeassistant`
- Waits up to 3 min for guest agent, then calls `ha network update`

## Key Variables (variables.tf)

| Variable | Default | Notes |
|---|---|---|
| `proxmox_endpoint` | — | `https://<host>:8006` |
| `proxmox_api_token` | — | sensitive; `user@realm!token_id=secret` |
| `proxmox_node` | `homelab2` | Proxmox node name |
| `proxmox_ssh_host` | `192.168.68.65` | SSH target for remote-exec |
| `proxmox_ssh_private_key_path` | `~/.ssh/id_ed25519` | SSH key for root |
| `vm_network_bridge` | `vmbr0` | Proxmox bridge |
| `haos_version` | — | e.g. `17.3`; from HAOS releases |
| `haos_static_ip` | `""` | CIDR e.g. `192.168.68.100/24`; empty = DHCP |
| `haos_gateway` | `""` | Required if static IP set |
| `haos_nameserver` | `8.8.8.8` | DNS for HAOS |
| `haos_network_iface` | `enp0s18` | Q35 + virtio NIC interface name |

## Provider Config (main.tf)

```hcl
provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = true  # self-signed cert on LAN
  ssh { agent = true; username = "root" }
}
```

## Workaround Notes

HAOS is managed via `null_resource` + SSH instead of the bpg/proxmox VM resource because:
1. bpg/proxmox v0.78+ dropped xz decompression support
2. HAOS only ships `.qcow2.xz` images
3. `pvesm download-url` with xz content type unavailable in PVE 8.2
