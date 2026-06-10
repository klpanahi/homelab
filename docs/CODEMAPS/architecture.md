<!-- Generated: 2026-06-10 | Files scanned: 7 | Token estimate: ~350 -->

# Homelab Architecture

## Overview

2-node Proxmox VE homelab. VMs provisioned by Terraform, configured by Ansible (planned), services run as Docker containers via Compose.

```
Laptop
  ├── Terraform ──SSH/API──► Proxmox Node (192.168.68.65)
  └── Ansible  ──ZeroTier──► VMs (dynamic inventory via QEMU guest agent)

Proxmox Node
  ├── VM: services      (Docker host — all containerized workloads)
  ├── VM: pbs           (Proxmox Backup Server — receives backups from sibling node)
  ├── VM: tunnel        (cloudflared — outbound-only public ingress)
  ├── VM: homeassistant (HAOS, VM ID 200, dedicated appliance)
  └── VM: windows       (Windows VM, VirtIO drivers required)
```

## Networking

- Proxmox hosts: static DHCP reservations in TP-Link Deco by MAC
- VMs: `vmbr0` bridge → home network, DHCP from Deco
- Stable-IP VMs (e.g. HAOS): MAC-based DHCP reservation in Deco
- Remote access: ZeroTier mesh VPN (laptop + all VMs)
- UFW on each VM: deny inbound except ZeroTier subnet port 22
- Public services: Cloudflare Tunnel (outbound-only, no open ports)

## Backup Strategy

Cross-machine PBS redundancy:
```
Machine 1 ──backups──► PBS on Machine 2
Machine 2 ──backups──► PBS on Machine 1
```

## Provisioning Flow

```
terraform apply          → clones base template, creates VM in Proxmox
Proxmox boots VM         → QEMU guest agent reports IP
ansible-playbook site.yml → dynamic inventory configures VM
PBS schedule             → picks up new VM on next run
```

## Planned Directories (not yet in repo)

- `ansible/` — VM configuration (Docker, UFW, ZeroTier, cloudflared)
- `compose/` — Docker Compose stacks per service
