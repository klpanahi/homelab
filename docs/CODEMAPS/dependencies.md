<!-- Generated: 2026-09-13 | Files scanned: 6 | Token estimate: ~400 -->

# Dependencies

## Terraform Providers

| Provider | Version | Purpose |
|---|---|---|
| `bpg/proxmox` | `~> 0.78` (locked: 0.109.0) | Proxmox VE API — provider auth, nginx VM + cloud-init files |
| `hashicorp/null` | `~> 3.0` (locked: 3.3.0) | `null_resource` for SSH-based HAOS provisioning |

## Ansible Collections & Roles (requirements.yml)

| Item | Type | Purpose |
|---|---|---|
| `community.proxmox` | collection | `proxmox` dynamic inventory plugin (replaces deprecated `community.general.proxmox`) |
| `geerlingguy.nginx` | role | installs + configures nginx (vhosts) on `tag_nginx` hosts |
| `geerlingguy.docker` | role | installs Docker CE on `tag_docker` hosts |
| `community.docker` / `ansible.posix` | collections | compose v2 + `sysctl`/`synchronize` modules |
| `roles/router` | repo-owned role | lab subnet gateway: IP forwarding + nftables masquerade |

## External Services

| Service | Role |
|---|---|
| Proxmox VE (homelab2, 192.168.68.65) | Hypervisor; Terraform target + Ansible inventory source |
| GitHub (home-assistant/operating-system) | HAOS image download source |
| Ubuntu cloud-images | nginx VM base image (24.04 noble standard) |
| ZeroTier | Mesh VPN for laptop-to-VM access (planned on VMs) |
| Cloudflare Tunnel | Public ingress, no open ports (planned) |
| TP-Link Deco | Home router (`192.168.68.0/22`); MAC-based DHCP reservations for stable IPs |

## Runtime Requirements

- Terraform >= 1.6
- Ansible (core 2.21+); `ansible-galaxy install -r requirements.yml`
- SSH agent / key for `root@<proxmox_ssh_host>` before `terraform apply`
- Proxmox API token with Administrator role on `/` (root@pam!terraform)
- Vault password file `ansible/.vault_pass` for the inventory token secret
- VM SSH key (`ubuntu` user) for Ansible to reach guests over the LAN
- `nftables` on the router VM (installed by `roles/router`); ufw removed there
- A control-machine route to `10.10.10.0/24` via `192.168.68.100` to manage lab VMs
