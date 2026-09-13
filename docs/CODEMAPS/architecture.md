<!-- Generated: 2026-09-13 | Files scanned: 16 | Token estimate: ~560 -->

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
  ├── VM 202: docker        (Docker host)
  ├── VM 203: nginx-internal (LAN-only nginx)
  ├── VM 204: router        (lab subnet gateway: 192.168.68.50 + 10.10.10.1)
  ├── VM: services          (Docker host — planned)
  ├── VM: pbs               (Proxmox Backup Server — planned)
  ├── VM: tunnel            (cloudflared — planned)
  └── VM: windows           (Windows VM — planned)
```

## Networking

- Home LAN: `192.168.68.0/22` (Deco default — a /22, not a /24), gateway `192.168.68.1`
- Lab subnet: `10.10.10.0/24`, gateway = router VM `10.10.10.1`; static addresses
  only (no DHCP server — it would share a broadcast domain with the Deco's).
  Same wire as the LAN, separated at L3 only — see [`../lab-subnet.md`](../lab-subnet.md)
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
- [`../lab-subnet.md`](../lab-subnet.md) — routed lab subnet design + runbook

## Planned Directories (not yet in repo)

- `compose/` — Docker Compose stacks per service
