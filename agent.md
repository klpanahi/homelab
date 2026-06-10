# Homelab Architecture

This document captures the **why** behind architecture decisions and operational conventions. For the current system map (resources, variables, services, dependencies), see [`docs/CODEMAPS/`](docs/CODEMAPS/).

---

## Codemaps

Architecture, infrastructure, and dependency details live in token-lean codemaps:

- [`docs/CODEMAPS/architecture.md`](docs/CODEMAPS/architecture.md) — system overview, networking, backup strategy, provisioning flow
- [`docs/CODEMAPS/infrastructure.md`](docs/CODEMAPS/infrastructure.md) — Terraform resources, variables, provider config
- [`docs/CODEMAPS/dependencies.md`](docs/CODEMAPS/dependencies.md) — providers, external services, runtime requirements

**After making code changes, update the codemaps** by running `/ecc:update-codemaps` in Claude Code.

---

## Why Proxmox

Designed for headless, always-on server use with a full REST API (usable with Terraform), native backup scheduling and PBS integration, and equal support for Linux VMs, Windows VMs, and LXC containers. Each machine manages its own VMs independently — the 2-node cluster is for unified UI visibility, not live migration or shared storage.

---

## VM Strategy

Workloads run as **Docker containers inside Linux VMs** rather than one VM per service. This keeps VM count low, makes services composable via `docker-compose.yml`, and keeps everything version-pinned and git-trackable.

---

## Base VM Template

All Linux VMs are cloned from a single base template (Ubuntu Server LTS or Debian) that includes the QEMU guest agent, cloud-init, and SSH pre-configured. Never provision from scratch — always clone the template.

The QEMU guest agent must be installed (`apt install qemu-guest-agent && systemctl enable --now qemu-guest-agent`) **and** enabled in Proxmox VM settings (Hardware → QEMU Guest Agent checkbox). Without the checkbox, Proxmox cannot report VM IPs to Ansible's dynamic inventory.

---

## Networking Conventions

- Proxmox hosts: static DHCP reservations in TP-Link Deco by MAC address
- VMs needing stable IPs (e.g. Home Assistant): MAC-based reservation in Deco app
- ZeroTier installed on all VMs + laptop — SSH and Ansible/Terraform traverse ZeroTier only
- UFW default: deny inbound, allow outgoing, SSH allowed from ZeroTier subnet only
- Public services: Cloudflare Tunnel (outbound-only, zero open inbound ports)

---

## Windows VM

- Mount VirtIO ISO alongside Windows ISO before starting installer — required for disk and NIC visibility
- Allocate minimum 4 GB RAM, 2 vCPUs
- RDP firewalled to ZeroTier subnet; Proxmox noVNC as fallback

---

## IaC Conventions

- **Terraform**: provisions VMs; VM identity tracked by Proxmox VM ID, not IP
- **Ansible**: configures VMs post-provision; uses `community.general.proxmox` dynamic inventory (no static IP files); secrets in Ansible Vault, never plaintext
- Provisioning order: `terraform apply` → VM boots → guest agent reports IP → `ansible-playbook site.yml` → PBS picks up on next schedule

---

## Open Decisions

- Which services run on which machine; split for redundancy vs. single host with cross-machine backup
- DNS strategy for internal service discovery (Pi-hole or similar)
- Monitoring and alerting (Grafana + Prometheus is a natural fit)
