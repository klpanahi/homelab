# Homelab Architecture

This document captures the **why** behind architecture decisions and operational conventions. For the current system map (resources, variables, services, dependencies), see [`docs/CODEMAPS/`](docs/CODEMAPS/).

---

## Codemaps

Architecture, infrastructure, and dependency details live in token-lean codemaps:

- [`docs/CODEMAPS/architecture.md`](docs/CODEMAPS/architecture.md) — system overview, networking, backup strategy, provisioning flow
- [`docs/CODEMAPS/infrastructure.md`](docs/CODEMAPS/infrastructure.md) — Terraform resources, variables, provider config
- [`docs/CODEMAPS/ansible.md`](docs/CODEMAPS/ansible.md) — dynamic inventory, tag groups, playbook, roles
- [`docs/CODEMAPS/dependencies.md`](docs/CODEMAPS/dependencies.md) — providers, collections, external services, runtime requirements

Design notes that are not a system map live alongside them:

- [`docs/lab-subnet.md`](docs/lab-subnet.md) — the routed lab subnet: why L3-only, address plan, bring-up, migration traps

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
- Lab VMs: addresses from `10.10.10.0/24`, routed and NAT'd by the router VM (see below). The Deco LAN is a **/22** (`192.168.68.1`–`192.168.71.254`), not a /24

---

## Why the Lab Subnet is Routed, Not VLAN'd

Lab VMs need addresses outside the range the Deco hands household devices. The
obvious answer — a VLAN — is unavailable: the switch is unmanaged (no tagging),
and neither Proxmox host has a spare NIC to dedicate to lab traffic. Buying a
cheap managed switch was evaluated and deferred; nothing here needed new hardware.

So separation is **layer 3 only**. Lab VMs stay on `vmbr0`, on the same broadcast
domain as the rest of the house, but carry `10.10.10.0/24` addresses and route
through a small router VM that masquerades onto the LAN. The router holds both a
LAN and a lab address on one vNIC — "router on a stick".

This buys a predictable address plan, not a security boundary: any LAN device can
still reach lab VMs at layer 2. Real isolation means a managed switch and VLANs.

Consequences worth remembering, with the full runbook in
[`docs/lab-subnet.md`](docs/lab-subnet.md):

- **No DHCP server on the lab subnet** — it would share a broadcast domain with
  the Deco's and hand lab leases to household devices. Lab addresses are static.
- **mDNS crosses the subnet boundary.** avahi advertises whichever address a host
  actually holds, so moving a VM changes what its `.local` name resolves to for
  *every* LAN host. nginx pins upstream addresses at parse time, so move the
  party-time chain together or not at all.
- **The control machine needs a route** (`10.10.10.0/24 via 192.168.68.50`) —
  otherwise Ansible's dynamic inventory resolves lab VMs to unreachable IPs.
- The router VM is excluded from the avahi play; it is addressed by static IP.

---

## Windows VM

- Mount VirtIO ISO alongside Windows ISO before starting installer — required for disk and NIC visibility
- Allocate minimum 4 GB RAM, 2 vCPUs
- RDP firewalled to ZeroTier subnet; Proxmox noVNC as fallback

---

## IaC Conventions

- **Terraform**: provisions VMs; VM identity tracked by Proxmox VM ID, not IP
- **Ansible**: configures VMs post-provision; uses the `community.proxmox.proxmox` dynamic inventory (no static IP files), grouping VMs by Proxmox tags; prefers open-source Galaxy roles over hand-written tasks; secrets in Ansible Vault, never plaintext. (The older `community.general.proxmox` plugin is deprecated.)
- Provisioning order: `terraform apply` → VM boots → guest agent reports IP → `ansible-playbook site.yml` → PBS picks up on next schedule

---

## Open Decisions

- Which services run on which machine; split for redundancy vs. single host with cross-machine backup
- DNS strategy for internal service discovery (Pi-hole or similar)
- Monitoring and alerting (Grafana + Prometheus is a natural fit)
