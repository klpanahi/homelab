# Lab Subnet (routed, no VLANs)

Lab VMs get addresses from a private CIDR that is distinct from the range the
Deco hands out to household devices, using only the hardware already here.

## Why this shape

| Constraint | Consequence |
|---|---|
| Switch is unmanaged | No VLAN tagging or trunking — VLAN segmentation is off the table |
| Neither Proxmox host has a spare NIC | No dedicated lab interface, no direct host-to-host cable |
| Both hosts hang off the same switch, which uplinks to the Deco | One flat broadcast domain shared with the whole house |
| Hosts are standalone (not clustered) | Nothing can be solved at the cluster/SDN layer |

So separation happens at **layer 3 only**: lab VMs stay on `vmbr0` and on the
same wire as everything else, but carry `10.10.10.0/24` addresses and reach the
rest of the world through a small router VM that NATs onto the LAN.

> **This is address-space separation, not isolation.** A lab VM and a TV on the
> LAN are still one ARP broadcast away from each other. Any LAN device could give
> itself a `10.10.10.x` address and talk to lab VMs directly. If real isolation
> is ever needed, the answer is a ~$30 managed switch and VLANs — this design
> buys a clean, predictable address plan, not a security boundary.

## Address plan

| Network | Range | Notes |
|---|---|---|
| Home LAN | `192.168.68.0/22` | Deco default — `192.168.68.1`–`192.168.71.254` is **one** subnet, gateway `192.168.68.1` |
| Lab | `10.10.10.0/24` | Gateway `10.10.10.1` (the router VM), static addresses only |

| Host | Address | Role |
|---|---|---|
| `router` (VM 204) | `192.168.68.50/22` + `10.10.10.1/24` | Both on one vNIC; NAT gateway for the lab |
| Lab VMs | `10.10.10.10`–`10.10.10.250` | Default gateway `10.10.10.1` |

```
                 Deco 192.168.68.1 ── internet
                        │
                 unmanaged switch
                   │         │
         homelab (host 1)   homelab2 (host 2)
                   │         │
                 vmbr0     vmbr0          ← one flat L2 segment
                   │         │
   lab VM 10.10.10.x   router VM 192.168.68.50 + 10.10.10.1
                                   └── masquerades 10.10.10.0/24 → LAN/internet
```

## No DHCP on the lab subnet

Do **not** run a DHCP server for `10.10.10.0/24`. It would share a broadcast
domain with the Deco's DHCP server, and household devices would start winning
lab leases. Lab addresses are static, set by cloud-init (Terraform).

## What owns what

- **Terraform** (`terraform/router.tf`) — the router VM, and the two addresses on
  its single NIC via a cloud-init v2 network-config snippet. Same NIC name-glob
  pattern as the other VMs, for the same Ubuntu 24.04 `eth0`-rename reason.
- **Ansible** (`ansible/roles/router`, repo-owned) — `ip_forward`, disabled ICMP
  redirects, and `/etc/nftables.conf` (masquerade + firewall policy). Applied by
  the `tag_router` play in `ansible/site.yml`. Tunables live in
  `ansible/group_vars/tag_router.yml`.
- **Per-VM addressing** — the existing `*_static_ip` / `*_gateway` variables. A VM
  joins the lab subnet purely through `terraform.tfvars`; no new Terraform code.

The router VM is deliberately excluded from the avahi play
(`hosts: tag_ansible:!tag_router`): avahi publishes *every* address on an
interface, so LAN clients would resolve `router.local` to `10.10.10.1` and fail
to reach it. Address the router by its static LAN IP.

## Bring-up

First confirm `192.168.68.50` is **outside the Deco's DHCP pool** (Deco app →
More → DHCP Server). Existing VMs have taken leases at `.77`, `.78` and `.85`, so
the pool starts lower than the Deco default — if it reaches `.50`, either shrink
it or set `router_lan_ip` to an address below it.

```bash
cd terraform
# router_* defaults in variables.tf already match the table above
terraform apply

cd ../ansible
ansible-galaxy install -r requirements.yml   # ansible.posix provides the sysctl module
ansible-inventory --graph                    # router should appear under tag_router
ansible-playbook site.yml --limit tag_router
```

Then give the control machine (Mac) a route, or nothing on the LAN can reach lab
addresses:

```bash
sudo route -n add -net 10.10.10.0/24 192.168.68.50
```

Persist it across reboots (check the existing list first — this flag replaces it):

```bash
networksetup -getadditionalroutes Wi-Fi
sudo networksetup -setadditionalroutes Wi-Fi 10.10.10.0 255.255.255.0 192.168.68.50
```

## Verify

On the router VM:

```bash
ip -4 -o addr show                  # both 192.168.68.50/22 and 10.10.10.1/24 on one NIC
sysctl net.ipv4.ip_forward          # = 1
sudo nft list ruleset               # filter + nat tables, masquerade rule present
```

From a lab VM:

```bash
ip route                            # default via 10.10.10.1
ping -c2 10.10.10.1                 # gateway
ping -c2 192.168.68.1               # LAN, through the router
curl -sI https://ubuntu.com | head -1   # NAT to the internet
```

From the Mac (with the route above in place):

```bash
ping -c2 10.10.10.1
ssh ubuntu@10.10.10.<lab-vm>
```

If forwarding looks dead, `sudo nft list ruleset` on the router shows per-chain
`counter` values for dropped input/forward traffic — check those before guessing.

## Optional: a static route on the Deco

By default the router masquerades lab traffic bound for LAN hosts too, so LAN
devices see connections coming from `192.168.68.50` and need no configuration.

If the Deco app exposes static routing (More → Advanced; not all models do), add
`10.10.10.0/24 → 192.168.68.50`. Then every LAN device can reach lab VMs without
per-device routes, and lab source addresses can be preserved:

```yaml
# ansible/group_vars/tag_router.yml
router_masquerade_to_lan: false
```

Re-run `ansible-playbook site.yml --limit tag_router`. Internet-bound traffic is
still masqueraded either way. Note the return path becomes asymmetric
(LAN → Deco → router → lab, lab → router → LAN directly); if consumer-router
quirks make that flaky, set the flag back to `true`.

## Moving an existing VM onto the lab subnet

New VMs are the easy case — set their `*_static_ip` / `*_gateway` to lab values
before first boot. Moving a **running** VM has two traps:

1. **cloud-init writes network config once.** Editing the Terraform snippet
   updates what a rebuilt VM gets, but a booted VM keeps its current
   `/etc/netplan/50-cloud-init.yaml`. Change it in-guest and `sudo netplan apply`.
2. **You will lose the SSH session** the moment the address changes. Do it from
   the Proxmox noVNC console, not over SSH.

```bash
# 1. record the intent so a rebuild lands on the same address
#    terraform.tfvars:  docker_static_ip = "10.10.10.20/24"
#                       docker_gateway   = "10.10.10.1"
cd terraform && terraform apply

# 2. from the Proxmox console on that VM
sudo sed -i 's#192\.168\.68\.[0-9]*/2[24]#10.10.10.20/24#; s#via: 192\.168\.68\.1#via: 10.10.10.1#' \
  /etc/netplan/50-cloud-init.yaml
sudo netplan apply
```

### The mDNS trap — read before moving `docker`

avahi advertises whatever address the host actually holds, and mDNS answers
cross subnets fine on a shared L2 segment. So the moment the docker VM moves,
`docker.local` starts resolving to `10.10.10.20` **for every host on the LAN** —
including the nginx VMs. nginx resolves upstream names once, at config-parse
time, and refuses to start when that fails, so a half-moved chain takes the site
down until a human intervenes (see `.claude/skills/fix-homelab-mdns`).

Therefore: move the party-time chain (`docker`, `nginx-cloudflared`,
`nginx-internal`) **together in one window**, or leave it on the LAN. If a
consumer of a `.local` name must stay on the LAN, give it a route of its own:

```yaml
# /etc/netplan/50-cloud-init.yaml on the LAN-side VM
      routes:
        - to: default
          via: 192.168.68.1
        - to: 10.10.10.0/24
          via: 192.168.68.50
```

Then `sudo netplan apply && sudo systemctl restart nginx` — the restart is what
re-resolves the pinned upstream addresses.

Home Assistant stays on the LAN regardless: it depends on mDNS/SSDP discovery of
IoT devices that live there.

## Lab VMs on the other Proxmox host

Host 1 is not managed by Terraform. Create the VM in the Proxmox UI on `vmbr0`,
then set the address inside the guest — do **not** use Proxmox's cloud-init IP
fields on Ubuntu 24.04, since the generated config renames the NIC to `eth0` and
silently fails (same reason this repo ships its own network-config snippets):

```yaml
# /etc/netplan/50-lab.yaml
network:
  version: 2
  ethernets:
    primary:
      match: {name: "e*"}
      dhcp4: false
      addresses: [10.10.10.30/24]
      routes:
        - to: default
          via: 10.10.10.1
      nameservers:
        addresses: [8.8.8.8]
```

## Limits and rollback

- Single point of failure: the router VM gates all lab internet access. It is
  `on_boot = true`, but a host reboot means lab downtime until it is back.
- No isolation (see the warning at the top).
- DNS for lab VMs is still public (`8.8.8.8`) through NAT; a lab-side resolver is
  a separate decision (Pi-hole is the open one in `agent.md`).

Rollback is per-VM and cheap: point the VM's `*_static_ip` / `*_gateway` back at
`192.168.68.x` / `192.168.68.1` (or back to DHCP), fix its netplan in-guest, and
restart anything that had pinned a `.local` upstream. The router VM can stay up
with nothing behind it, or be destroyed with `terraform destroy -target
proxmox_virtual_environment_vm.router`.
