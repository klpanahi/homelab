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
| Deco DHCP pool | `192.168.68.50`–`192.168.71.250` | The Deco only accepts address reservations **inside** this range, so stable infrastructure addresses live in-pool and are held by a MAC reservation |
| Lab | `10.10.10.0/24` | Gateway `10.10.10.1` (the router VM), static addresses only |

| Host | Address | Role |
|---|---|---|
| `router` (VM 204) | `192.168.68.100/22` + `10.10.10.1/24` | Both on one vNIC; NAT gateway for the lab. MAC pinned to `BC:24:11:00:02:04` |
| Lab VMs | `10.10.10.10`–`10.10.10.250` | Default gateway `10.10.10.1` |

The router's LAN address is held the same way every other stable address here is:
a Deco **address reservation** bound to a pinned MAC (`router_mac_address`, same
pattern as `haos_mac_address`). It has to be — the Deco refuses reservations outside
its own DHCP range, so "pick something below the pool" is not an option on this
router. The reservation is what keeps the address; without it a phone gets it
eventually and the whole lab subnet goes dark.

Current Deco reservations, which are the only addresses on this LAN that are
actually guaranteed:

| Host | Address | Reserved |
|---|---|---|
| `homelab1` (Proxmox node) | `192.168.68.75` | yes |
| `homelab2` (Proxmox node) | `192.168.68.65` | yes |
| `homeassistant` (VM 200) | `192.168.68.60` | yes |
| `router` (VM 204) | `192.168.68.100` | yes — MAC `BC:24:11:00:02:04` |
| `nginx-cloudflared`, `docker`, `nginx-internal` | `.77`, `.78`, `.85` | **no** — plain dynamic leases |
| `backup` (VM 300, on homelab1) | DHCP | **no** |

Those three unreserved VMs are exactly the mDNS "lease moved" failure mode the
[`fix-homelab-mdns`](../.claude/skills/fix-homelab-mdns/SKILL.md) skill documents
(the docker VM has already jumped once, `.89` → `.78`). Reserving them is unrelated
to this change, but it is the cheap fix for a recurring outage.

```
                 Deco 192.168.68.1 ── internet
                        │
                 unmanaged switch
                   │         │
      homelab1 (.75)       homelab2 (.65)
                   │         │
                 vmbr0     vmbr0          ← one flat L2 segment
                   │         │
   lab VM 10.10.10.x   router VM 192.168.68.100 + 10.10.10.1
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

First, the addressing prerequisite: **the Deco reservation must exist before the
VM does.** `router_lan_ip` is `192.168.68.100`, which sits inside the DHCP pool —
that is not a compromise, it is the only place the Deco will accept a reservation.

In the Deco app: More → Address Reservation → bind `BC:24:11:00:02:04`
(`router_mac_address`) to `192.168.68.100`. Terraform pins that MAC, so the
reservation can be created first. Confirm nothing else holds the address:

```bash
ping -c 2 192.168.68.100    # no reply expected
```

If a Deco build only offers reservations picked from the connected-client list,
apply Terraform first — the VM comes up on its static address regardless — then add
the reservation as soon as `router` appears in the list. Do not leave it unreserved.

```bash
cd terraform
# router_* defaults in variables.tf already match the table above
terraform apply

cd ../ansible
ansible-galaxy install -r requirements.yml   # no-op on Homebrew Ansible, which bundles ansible.posix
ansible-inventory --graph                    # router should appear under tag_router
ansible-playbook site.yml --limit tag_router
```

Then set up LAN access: the Deco static route, plus a route on each Mac. Without
them nothing on the LAN can reach lab addresses, and which one a device needs depends
on its OS — see [Reaching the lab from the LAN](#reaching-the-lab-from-the-lan).

## Verify

On the router VM:

```bash
ip -4 -o addr show                  # both 192.168.68.100/22 and 10.10.10.1/24 on one NIC
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

From a Mac (with its own route in place — see the next section):

```bash
ping -c2 10.10.10.1
ssh ubuntu@10.10.10.<lab-vm>
```

If forwarding looks dead, `sudo nft list ruleset` on the router shows per-chain
`counter` values for dropped input/forward traffic — check those before guessing.

### End-to-end test without a VM

No lab VM yet? A throwaway network namespace on a Proxmox host stands in for one:
a veth pair plugged into `vmbr0` with a lab address. It is not a VM or a container,
so it never appears in the Proxmox UI, and it removes itself on exit. Run it as root
on **homelab1** — the router lives on homelab2, so this crosses the physical switch
like a real lab VM on the other host would:

```bash
cleanup() { ip netns del labtest 2>/dev/null; ip link del labtest-br 2>/dev/null; }
trap cleanup EXIT
ip link add labtest type veth peer name labtest-br
ip link set labtest-br master vmbr0 up
ip netns add labtest && ip link set labtest netns labtest
ip -n labtest link set lo up && ip -n labtest link set labtest up
ip -n labtest addr add 10.10.10.99/24 dev labtest
ip -n labtest route add default via 10.10.10.1
ip netns exec labtest ping -c2 10.10.10.1        # gateway
ip netns exec labtest ping -c2 192.168.68.1      # LAN (only answers because of the masquerade)
ip netns exec labtest curl -sI https://ubuntu.com | head -1
```

To test **LAN → lab**, serve a file from inside the namespace
(`ip netns exec labtest python3 -m http.server 8099 --bind 10.10.10.99`) and download
it from a LAN device. **Test with 64 KB or more and compare the byte count, not with
ping:** on a path the Deco mishandles, ping and tiny requests pass while every real
transfer stalls — see the next section.

## Reaching the lab from the LAN

LAN devices send anything for `10.10.10.0/24` to their default gateway, the Deco,
so the Deco has to know the way. What happens next depends on the device's OS.
Everything below was measured on 2026-09-27 with a lab host serving 64 KB, 1 MB and
8 MB files.

### The Deco static route (in place)

Deco app → More → Advanced → Routing:

| Field | Value |
|---|---|
| Destination | `10.10.10.0` |
| Subnet mask | `255.255.255.0` |
| Gateway | `192.168.68.100` |
| Interface | **LAN** |

**The interface must be LAN.** Set to WAN, the Deco ships lab-bound traffic to the
ISP, which drops it silently: traceroute shows the Deco as hop 1 and nothing after.

What the route gives each kind of device:

| Device | Result | Why |
|---|---|---|
| Linux (homelab2) | **Works fully** — 8 MB, checksum match | Follows the Deco's ICMP redirect ("go straight to `.100`"), so the Deco drops out of the path after the first packet |
| Windows | Expected to work (not tested) | Follows ICMP redirects by default |
| macOS (Mac) | **Broken for real use** — ping and ≤1 KB work; 64 KB+ stalls at 14,480 bytes | Ignores redirects (`net.inet.icmp.drop_redirect=1`), so every packet hairpins through the Deco |
| iOS 18.7 (iPhone) | **Same as macOS** — 64 KB stalls at 14,480 bytes | Same network stack |

**Why hairpinned traffic fails.** When a connection enters and leaves the Deco on the
same LAN port, it survives about ten packets — 14,480 bytes is exactly one initial
TCP congestion window — and then whichever direction crosses the Deco goes silent,
while FIN and RST still get through. Packet captures on the router show the server's
data leaving toward the Mac and never arriving. The pattern matches a hardware fast
path that takes over each flow after its first packets and mishandles hairpins. The
Deco app has no setting to turn acceleration off, so treat this as fixed hardware
behaviour, not configuration.

**Tried and rejected — don't repeat it:** policy-routing the router's replies back
through the Deco (connections arriving from the Deco's MAC get a conntrack mark;
marked replies use a table whose default route is the Deco). The Deco then sees both
directions, the first window does reach the Mac — and the Mac's ACKs die inside the
Deco instead. The stall moves; it does not go away.

### Per-device routes (Macs)

A Mac with its own route sends lab traffic straight to the router and never touches
the Deco, so it is fully reliable. Every Mac that talks to lab VMs needs one —
including the Ansible control machine, since a lab VM's `ansible_host` is a
`10.10.10.x` address. (The router itself needs no route: its inventory address is its
LAN IP.)

```bash
sudo route -n add -net 10.10.10.0/24 192.168.68.100
```

Persist it across reboots (check the existing list first — this flag replaces it):

```bash
networksetup -getadditionalroutes Wi-Fi
sudo networksetup -setadditionalroutes Wi-Fi 10.10.10.0 255.255.255.0 192.168.68.100
```

iPhones and iPads cannot take static routes. They get working access only once LAN
DHCP hands out the route itself (option 121) — see
[Where this is heading](#where-this-is-heading).

### Keep `router_masquerade_to_lan: true`

Earlier drafts said to turn it off once the Deco had a route. Don't. With it off, a
LAN host answering a lab-initiated connection replies to a `10.10.10.x` address via
the Deco — the hairpin that stalls for Apple devices. Masquerading makes those
replies go to `192.168.68.100` directly on the LAN, which always works.

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
`nginx-internal`) **together in one window**, or leave it on the LAN.

The chain has a fourth consumer that does not move with it: the **backup VM on
homelab1** reaches Postgres over SSH at `backup_docker_host: docker.local`
(`ansible/roles/backup/defaults/main.yml`). Move `docker` without giving the backup
VM a route (below), or without repointing that variable, and nightly Postgres
backups start failing quietly — the kind of breakage nobody notices until a
restore is needed. If a
consumer of a `.local` name must stay on the LAN, give it a route of its own:

```yaml
# /etc/netplan/50-cloud-init.yaml on the LAN-side VM
      routes:
        - to: default
          via: 192.168.68.1
        - to: 10.10.10.0/24
          via: 192.168.68.100
```

Then `sudo netplan apply && sudo systemctl restart nginx` — the restart is what
re-resolves the pinned upstream addresses.

Home Assistant stays on the LAN regardless: it depends on mDNS/SSDP discovery of
IoT devices that live there.

## Lab VMs on homelab1

homelab1 is a standalone Proxmox host with its own Terraform provider alias
(`proxmox.homelab1`, introduced by `terraform/backup.tf`). A lab VM there is an
ordinary Terraform VM that binds **every** resource to that alias — one that forgets
silently lands on homelab2 — with lab values for its `*_static_ip` / `*_gateway`.
It reaches the router over the physical switch, since both hosts' `vmbr0` bridges
share the one flat segment. Follow `backup.tf` as the template.

For a VM created by hand in the Proxmox UI instead, set the address inside the
guest — do **not** use Proxmox's cloud-init IP fields on Ubuntu 24.04, since the
generated config renames the NIC to `eth0` and silently fails (same reason this
repo ships its own network-config snippets):

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

## Where this is heading

The end state is fixed addresses for every service plus an internal resolver, so
that neither mDNS nor the Deco app is in the path of provisioning a VM. This
change is step one of that, not a detour — and it already removes the Deco chore
for anything that moves onto the lab subnet:

**The Deco does not serve `10.10.10.0/24`.** It has no DHCP scope there and never
offers a lease on it, so a lab VM's address cannot be taken from it and needs no
address reservation. `192.168.68.100` for the router is the *last* reservation
this homelab has to make by hand; every VM placed behind it is addressed in git
(`*_static_ip` in `terraform.tfvars`) and nowhere else.

Remaining steps, in dependency order:

1. **Lab-side resolver.** dnsmasq on the router VM, authoritative for a private
   zone (`home.arpa` is the reserved-for-this-purpose choice; `.local` is spoken
   for by mDNS). Records come from a git-tracked hosts file rendered by the
   `router` role — the same place the address plan already lives. Forward
   everything else upstream. This is the concrete form of the "DNS strategy for
   internal service discovery" open decision in `agent.md`; Pi-hole is dnsmasq
   with a UI, so it can take this job later without re-planning.
2. **Point lab VMs at it.** Each VM already has a `*_nameserver` Terraform
   variable — set it to `10.10.10.1`. No new plumbing.
3. **Migrate the services** (`docker`, `nginx-internal`, `nginx-cloudflared`)
   onto lab addresses in one window, per the migration section above, replacing
   `docker.local` upstreams with the new zone names as they move. Once nothing
   resolves a `.local` name, avahi can come out of the `tag_ansible` play
   entirely and the `fix-homelab-mdns` failure class disappears with it.
4. **Resolve lab names from the LAN.** The Deco cannot do split-horizon DNS, but
   macOS can be told per-zone: a one-line `/etc/resolver/home.arpa` pointing at
   `10.10.10.1` resolves lab names on the Mac without touching the router.
5. **Hand every device the lab route over DHCP (option 121).** The only fix for
   iPhones and iPads, and it retires the per-Mac routes: devices learn
   `10.10.10.0/24 via 192.168.68.100` at lease time and never hairpin through the
   Deco. Option 121 replaces the plain default-gateway option, so it must also carry
   `0.0.0.0/0 via 192.168.68.1`. The Deco cannot send custom DHCP options, so this
   means dnsmasq on the router serving LAN DHCP with the Deco's DHCP server off.
   Open questions: whether the Deco allows turning DHCP off in router mode, and
   whether the household should depend on a VM for its addresses.

Home Assistant stays on the LAN throughout — it needs mDNS/SSDP discovery of IoT
devices that live there, and it is already reserved at `.60`.

## Limits and rollback

- Single point of failure: the router VM gates all lab internet access. It is
  `on_boot = true`, but a host reboot means lab downtime until it is back.
- No isolation (see the warning at the top).
- DNS for lab VMs is still public (`8.8.8.8`) through NAT until the resolver in
  "Where this is heading" lands; until then lab VMs resolve `.local` names the
  same way everything else does, over mDNS.

If you tear the router down for good, delete its Deco address reservation too —
a reservation pointing at a MAC that no longer exists just shrinks the usable pool.

Rollback is per-VM and cheap: point the VM's `*_static_ip` / `*_gateway` back at
`192.168.68.x` / `192.168.68.1` (or back to DHCP), fix its netplan in-guest, and
restart anything that had pinned a `.local` upstream. The router VM can stay up
with nothing behind it, or be destroyed with `terraform destroy -target
proxmox_virtual_environment_vm.router`.
