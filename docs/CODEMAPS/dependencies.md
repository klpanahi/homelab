<!-- Generated: 2026-09-27 | Files scanned: 7 | Token estimate: ~470 -->

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
| Proxmox VE (homelab1, 192.168.68.75) | Standalone second hypervisor (backup VM); own provider alias, token, inventory source |
| GitHub (home-assistant/operating-system) | HAOS image download source |
| Ubuntu cloud-images | Base image for every Ubuntu VM (24.04 noble standard); downloaded once per node |
| ZeroTier | Mesh VPN for laptop-to-VM access (planned on VMs) |
| Cloudflare Tunnel | Public ingress, no open ports (planned) |
| TP-Link Deco | Home router (`192.168.68.0/22`); MAC-based DHCP reservations; static route `10.10.10.0/24 → .100` (LAN). Configured by hand in the app — no API |

## Runtime Requirements

- Terraform >= 1.6
- Ansible (core 2.21+). Homebrew's Ansible bundles the needed collections;
  `ansible-galaxy install -r requirements.yml` supplies the galaxy roles
- SSH agent / key for `root@<proxmox_ssh_host>` before `terraform apply`
- Proxmox API token with Administrator role on `/` (root@pam!terraform)
- Vault password file `ansible/.vault_pass` for the inventory token secret
- VM SSH key (`ubuntu` user) for Ansible to reach guests over the LAN
- `nftables` on the router VM (installed by `roles/router`); ufw removed there
- A local route on a Mac control machine: `10.10.10.0/24` via `192.168.68.100`
  (the Deco's route alone stalls macOS connections) — needed to manage lab VMs
