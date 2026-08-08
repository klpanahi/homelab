<!-- Generated: 2026-06-23 | Files scanned: 14 | Token estimate: ~480 -->

# Homelab Architecture

## Overview

2-node Proxmox VE homelab. VMs provisioned by **Terraform**, configured by
**Ansible** (Proxmox dynamic inventory), services run as Docker containers via
Compose (planned).

```
Laptop
  ├── Terraform ──SSH/API──► Proxmox Node homelab2 (192.168.68.65)
  ├── Terraform ──SSH/API──► Proxmox Node homelab1 (192.168.68.75)
  └── Ansible  ──SSH(LAN)──► VMs (dynamic inventory via QEMU guest agent, both nodes)

Proxmox Node (homelab2, 192.168.68.65)
  ├── VM 200: homeassistant (HAOS appliance, null_resource + SSH)
  ├── VM 201: nginx         (Ubuntu 24.04 cloud-image, bpg VM resource)
  ├── VM 202: docker        (Docker host — runs party-time-db etc.)
  ├── VM 203: nginx-internal (Ubuntu 24.04 cloud-image, bpg VM resource)
  └── VM: windows           (Windows VM — planned)

Proxmox Node (homelab1, 192.168.68.75) — STANDALONE, not clustered with homelab2
  └── VM 300: backup        (Ubuntu 24.04 cloud-image, bpg VM resource; pulls
                             backups from homelab2 over the LAN — see Backup
                             Strategy below)
```

homelab1 and homelab2 are two independent, uncoupled Proxmox installs — homelab1's
API only ever sees itself, and homelab2's API token is rejected there (401). The
backup VM runs on homelab1 specifically so a homelab2 hardware/storage failure
can't take the backups down along with the things they back up.

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
                            (e.g. tag_nginx → geerlingguy.nginx role,
                            tag_backup → backup role)
```

Backup coverage for a new workload is NOT automatic — there is no schedule
that "picks up" new VMs. The `backup` role's pull scripts target specific,
named hosts/containers (HA at a fixed URL, `party-time-db` by container name);
a new service needs its own backup script and timer added deliberately.

Division of labor: Terraform owns VM lifecycle + identity (VM ID, tags);
Ansible owns in-guest config (packages, services). nginx is installed by
Ansible, not cloud-init, so config lives in one place.

## Backup Strategy

Implemented (not the PBS design previously sketched here). A dedicated `backup`
VM (300, homelab1) **pulls** two things from homelab2 on a schedule; neither
source host holds credentials for or write access to the backup store, so a
compromised app host can't delete its own backups:

```
backup VM (homelab1) ──HTTP, admin token────► Home Assistant Core API (VM 200)
                          create backup → download .tar → delete from HA
backup VM (homelab1) ──SSH + docker exec────► docker VM (VM 202)
                          pg_dump -Fc party_time schema from party-time-db,
                          plus best-effort fetch of /opt/party-time/.env.prod
```

Artifacts land under `/var/backups/homelab/` on the backup VM. Retention: 14
days (Home Assistant `.tar`s), 30 days (Postgres dumps). Two systemd timers,
daily at 03:15 and 03:45 (`Persistent=true`, so a missed run catches up on
next boot). See [`ansible.md`](ansible.md) for the `backup` role.

**Explicitly NOT covered** — do not assume any of this exists:
- No whole-VM / image-level backups (no PBS, no snapshot-based backup of any
  kind — only HA's own Supervisor backup and a Postgres logical dump)
- No encryption at rest for backup artifacts (deliberate operator choice)
- No offsite copy — homelab1 and homelab2 are both in the same building, so a
  building-level event (fire, theft, power surge) takes out both
- No failure alerting — each script writes a `LAST_SUCCESS_<name>` marker
  timestamp file under `/var/backups/homelab/`, but nothing currently reads
  or monitors it; a silently-broken timer would go unnoticed

## Detail Codemaps

- [`infrastructure.md`](infrastructure.md) — Terraform resources, variables, provider
- [`ansible.md`](ansible.md) — dynamic inventory, groups, playbook, roles
- [`dependencies.md`](dependencies.md) — providers, collections, external services

## Planned Directories (not yet in repo)

- `compose/` — Docker Compose stacks per service
