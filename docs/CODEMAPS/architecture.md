<!-- Generated: 2026-06-23 | Files scanned: 14 | Token estimate: ~480 -->

# Homelab Architecture

## Overview

2-node Proxmox VE homelab. VMs provisioned by **Terraform**, configured by
**Ansible** (Proxmox dynamic inventory), services run as Docker containers via
Compose (planned).

```
Laptop
  ├── Terraform ──SSH/API──► Proxmox Node (192.168.68.65)
  └── Ansible  ──SSH(LAN)──► VMs (dynamic inventory via QEMU guest agent)

Proxmox Node (homelab2)
  ├── VM 200: homeassistant (HAOS appliance, null_resource + SSH)
  ├── VM 201: nginx         (Ubuntu 24.04 cloud-image, bpg VM resource)
  ├── VM: services          (Docker host — planned)
  ├── VM: pbs               (Proxmox Backup Server — planned)
  ├── VM: tunnel            (cloudflared — planned)
  └── VM: windows           (Windows VM — planned)
```

## Networking

- Proxmox hosts: static DHCP reservations in TP-Link Deco by MAC
- VMs: `vmbr0` bridge → home network, DHCP from Deco
- Stable-IP VMs (e.g. HAOS): MAC-based DHCP reservation in Deco
- Remote access: ZeroTier mesh VPN (planned on VMs); Ansible currently over LAN
- UFW on each VM: deny inbound except ZeroTier subnet port 22 (planned)
- Public services: Cloudflare Tunnel (outbound-only, no open ports — planned)

## Provisioning Flow

```
terraform apply           → creates/tags VM in Proxmox, cloud-init bootstraps
                            ubuntu user + qemu-guest-agent (NOT nginx)
Proxmox boots VM          → QEMU guest agent reports IP
ansible-playbook site.yml → dynamic inventory groups VM by tag, configures it
                            (e.g. tag_nginx → geerlingguy.nginx role)
PBS schedule              → picks up new VM on next run (planned)
```

Division of labor: Terraform owns VM lifecycle + identity (VM ID, tags);
Ansible owns in-guest config (packages, services). nginx is installed by
Ansible, not cloud-init, so config lives in one place.

## Backup Strategy

Cross-machine PBS redundancy (planned):
```
Machine 1 ──backups──► PBS on Machine 2
Machine 2 ──backups──► PBS on Machine 1
```

## Detail Codemaps

- [`infrastructure.md`](infrastructure.md) — Terraform resources, variables, provider
- [`ansible.md`](ansible.md) — dynamic inventory, groups, playbook, roles
- [`dependencies.md`](dependencies.md) — providers, collections, external services

## Planned Directories (not yet in repo)

- `compose/` — Docker Compose stacks per service
