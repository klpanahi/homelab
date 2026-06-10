<!-- Generated: 2026-06-10 | Files scanned: 2 | Token estimate: ~200 -->

# Dependencies

## Terraform Providers

| Provider | Version | Purpose |
|---|---|---|
| `bpg/proxmox` | `~> 0.78` (locked: 0.109.0) | Proxmox VE API — provider auth and future VM resources |
| `hashicorp/null` | `~> 3.0` (locked: 3.3.0) | `null_resource` for SSH-based HAOS provisioning |

## External Services

| Service | Role |
|---|---|
| Proxmox VE (homelab2, 192.168.68.65) | Hypervisor; Terraform target |
| GitHub (home-assistant/operating-system) | HAOS image download source |
| ZeroTier | Mesh VPN for laptop-to-VM and inter-VM access |
| Cloudflare Tunnel | Public ingress for exposed services (no open ports) |
| TP-Link Deco | Home router; MAC-based DHCP reservations for stable IPs |

## Runtime Requirements

- Terraform >= 1.6
- SSH agent loaded with key for `root@<proxmox_ssh_host>` before `terraform apply`
- Proxmox API token with Administrator role on `/`

## Planned (not yet wired up)

- Ansible `community.general.proxmox` dynamic inventory plugin
- Ansible Vault for secrets (Proxmox tokens, ZeroTier, Cloudflare)
