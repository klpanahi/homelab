# Lab Subnet (routed, no VLANs)

Lab VMs get addresses from a private CIDR that is distinct from the range the
Deco hands out to household devices, using only the hardware already here.

## Why this shape

| Constraint | Consequence |
|---|---|
| Switch is unmanaged | No VLAN tagging or trunking — VLAN segmentation is off the table |
| Neither Proxmox host has a spare NIC | No dedicated lab interface, no direct host-to-host cable |
| Both hosts hang off the same switch, which uplinks to the Deco | One flat broadcast domain shared with the whole house |
| Hosts are a 2-node cluster with no shared storage or SDN setup | The lab subnet is not built on Proxmox SDN; it stays a plain router VM |

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

Per-host addresses — which VM sits where, on which subnet, and why — are in the
[IP allocation table in the README](../README.md#ip-allocation). The router VM holds
`192.168.68.100/22` and `10.10.10.1/24` on one vNIC, MAC pinned to `BC:24:11:00:02:04`.

The router's LAN address is held the same way every other stable address here is:
a Deco **address reservation** bound to a pinned MAC (`router_mac_address`, same
pattern as `haos_mac_address`). It has to be — the Deco refuses reservations outside
its own DHCP range, so "pick something below the pool" is not an option on this
router. The reservation is what keeps the address; without it a phone gets it
eventually and the whole lab subnet goes dark.

**`192.168.68.100` is the only Deco reservation the lab needs.** Every lab VM sits
on `10.10.10.0/24`, where the Deco hands out nothing and so has nothing to reserve;
their addresses live in git ([allocation table](../README.md#ip-allocation)). The
other reservations predate the lab and stay as they are:

| Host | Address | Why it stays on the LAN |
|---|---|---|
| `router` (VM 204) | `192.168.68.100` | It *is* the way into the lab. MAC `BC:24:11:00:02:04` |
| `homelab1` (Proxmox node) | `192.168.68.75` | Hypervisor management |
| `homelab2` (Proxmox node) | `192.168.68.65` | Hypervisor management |
| `homeassistant` (VM 200) | `192.168.68.60` | mDNS/SSDP discovery of IoT devices on the LAN |

`docker`, `nginx-cloudflared`, `nginx-internal` and `backup` used to be unreserved
dynamic leases, the mDNS "lease moved" failure mode (mDNS has since been
retired, see [internal-dns.md](internal-dns.md#mdns-was-retired-2026-10-30))
(docker has jumped `.89` → `.78` → `.88`; nginx-internal `.85` → `.89`). Once moved,
none of them needs a reservation.

Wifi clients still reach `nginx-internal` without a route to the lab: the router
forwards ports 80/443 on `192.168.68.100` to `10.10.10.40`, and the internal DNS
names for its sites point at the router. iPhones only ever talk to `.100`, a LAN
address, so they never hit the [Deco hairpin stall](#reaching-the-lab-from-the-lan).

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
- **Per-VM addressing** — the existing `*_static_ip` / `*_gateway` variables, whose
  `variables.tf` defaults are the allocation table, so the plan is in git rather
  than in the gitignored `terraform.tfvars`. The VMs ignore later changes to their
  cloud-init `initialization`, so an address change never rebuilds a running VM;
  see [Moving an existing VM](#moving-an-existing-vm-onto-the-lab-subnet).

The router VM is excluded from the common play
(`hosts: tag_ansible:!tag_router`). That exclusion started because avahi would
publish both of its addresses; avahi is gone now, and the router is addressed
as `router.home.arpa`.

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

1. **cloud-init writes network config once, and Terraform must not "fix" that.**
   A changed network snippet makes the provider *replace* the VM — new disk, data
   gone. The VMs therefore carry `lifecycle { ignore_changes = [initialization] }`:
   `terraform apply` updates the snippet file (what a rebuilt VM gets) and leaves
   the running VM alone. A booted VM keeps its current
   `/etc/netplan/50-cloud-init.yaml`; change it in-guest and `sudo netplan apply`.
   Rebuild on purpose only, with `terraform apply -replace=<resource>`.
2. **You will lose the SSH session** the moment the address changes. Do it from
   the Proxmox noVNC console, not over SSH.

The VMs these steps were written for came up on DHCP, so their netplan has no
address to edit — replace the file instead. From the Proxmox console on the VM,
with `ADDR` taken from the [allocation table](../README.md#ip-allocation):

```bash
ADDR=10.10.10.20/24   # docker; nginx-cloudflared .10, backup .30, nginx-internal .40
sudo cp /etc/netplan/50-cloud-init.yaml /root/50-cloud-init.yaml.lan
sudo tee /etc/netplan/50-cloud-init.yaml >/dev/null <<EOF
network:
  version: 2
  ethernets:
    primary:
      match: {name: "e*"}
      dhcp4: false
      addresses: [$ADDR]
      routes:
        - to: default
          via: 10.10.10.1
      nameservers:
        addresses: [8.8.8.8]
EOF
sudo chmod 600 /etc/netplan/50-cloud-init.yaml
sudo netplan apply
ip -4 -o addr show scope global && ping -c2 10.10.10.1 && ping -c2 192.168.68.1
```

That is the same file Terraform's snippet now generates, so a rebuild lands on the
same address. Rollback is copying the saved file back and `sudo netplan apply`.

### The mDNS trap (historical: mDNS was retired on 2026-10-30)

> This applied while guests still used `.local` names. Today everything uses
> `home.arpa` records pinned in `ansible/dns/records.yml`, and nginx resolves
> backends per request ([internal-dns.md](internal-dns.md#nginx-backends)), so
> moving a guest means changing its record, not restarting nginx.

avahi advertises whatever address the host actually holds, and mDNS answers
cross subnets fine on a shared L2 segment. So the moment the docker VM moves,
`docker.local` starts resolving to `10.10.10.20` **for every host on the LAN** —
including the nginx VMs. nginx resolves upstream names once, at config-parse
time, and refuses to start when that fails, so a half-moved chain takes the site
down until a human intervenes.

Therefore: move the party-time chain (`docker`, `nginx-cloudflared`,
`nginx-internal`) **together in one window**, and restart nginx on both nginx VMs
at the end of it.

The **backup VM on homelab1** also reaches docker, over SSH for `pg_dump`. Its
`backup_docker_host` is now the fixed address `10.10.10.20`
(`ansible/roles/backup/defaults/main.yml`) rather than `docker.local`; until the
backup play is re-run with that value, a moved docker VM means nightly Postgres
backups fail quietly — the kind of breakage nobody notices until a restore is
needed. The cutover below re-runs it.

### Cutover: the party-time chain

One window, in this order. Wifi access to `nginx-internal` depends on the router's
port forward and the internal DNS records, so those must be merged first.

1. **Before the window.** Merge the router front-door / internal DNS change.
   Check the Mac running Ansible has its lab route (`netstat -rn | grep 10.10.10`).
2. **`terraform plan`** with this branch. It must show **no** `must be replaced`
   and no in-place change to any VM — only the `*-network-config.yaml` snippet
   files. If any VM would be replaced or updated, stop: the `ignore_changes` guard
   is missing from it. Then `terraform apply` — **only inside the window**: the
   snippets keep their file names but change content, and if that changes the VM's
   cloud-init instance-id, an unmoved VM's next reboot would jump it to its lab
   address unannounced. Never rebuild `backup` to "fix" anything: its disk is the
   dump history.
3. **`docker` → `10.10.10.20`**, then **`nginx-cloudflared` → `10.10.10.10`**, then
   **`nginx-internal` → `10.10.10.40`**, each from its Proxmox console per
   [Moving an existing VM](#moving-an-existing-vm-onto-the-lab-subnet).
4. **Restart nginx** on `nginx-cloudflared` and `nginx-internal` so both re-resolve
   `docker.local` (now `10.10.10.20`).
5. **Re-run the router play** (`ansible-playbook site.yml --limit tag_router`) so
   DNS and the port forward point at the new addresses — not before step 3, or the
   names point at addresses nothing holds yet. Check the public site through
   Cloudflare and the admin UI from a phone on wifi.
6. **`backup` → `10.10.10.30`** from homelab1's console, then from the Mac:
   `ansible-playbook site.yml --limit tag_backup` (renders the new
   `backup_docker_host`), and on the backup VM
   `sudo systemctl start backup-postgres.service && journalctl -u backup-postgres -n 30`.
7. **Clean up.** Delete any Deco reservations made for these VMs' old LAN leases
   (they now only shrink the pool); unreserved leases expire on their own. Remove
   any `/etc/hosts` pins of the old addresses.

The Ansible inventory needs no change: `ansible_host` comes from the guest agent,
so it follows each VM to its new address.

Home Assistant stays on the LAN regardless: it depends on mDNS/SSDP discovery of
IoT devices that live there.

## Lab VMs on homelab1

homelab1 is the second node of the Proxmox cluster (see [`cluster.md`](cluster.md)).
A lab VM there is an ordinary Terraform VM whose resources set
`node_name = var.proxmox_homelab1_node`, with lab values for its `*_static_ip` / `*_gateway`.
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
(`*_static_ip` defaults in `variables.tf`) and nowhere else.

Remaining steps, in dependency order:

1. **Lab-side resolver — built.** dnsmasq on the router VM, authoritative for
   `home.arpa`, records in `ansible/dns/records.yml`, everything else forwarded
   upstream. Serves the LAN as well as the lab, so pointing the Deco's DHCP DNS
   at `192.168.68.100` gives every Wi-Fi device the internal names. Setup, the
   Deco steps and rollback: [internal-dns.md](internal-dns.md).
2. **Point lab VMs at it — done.** `site.yml` routes `home.arpa` lookups to
   `10.10.10.1` with a systemd-resolved drop-in
   ([internal-dns.md](internal-dns.md#lab-vms)), so `*_nameserver` stays public.
3. **Migrate the services** (`docker`, `nginx-cloudflared`, `nginx-internal`,
   `backup`) onto lab addresses in one window, per
   [the cutover](#cutover-the-party-time-chain), and replace `docker.local`
   upstreams with the new zone names. **Done**, and avahi came out of the
   `tag_ansible` play on 2026-10-30
   ([internal-dns.md](internal-dns.md#mdns-was-retired-2026-10-30)).
4. **Resolve lab names from the LAN.** Covered by step 1 once the Deco hands out
   `192.168.68.100` as DNS. Names people open from phones resolve to the router,
   which forwards 80/443 to nginx-internal in the lab, since `10.10.10.x` stalls
   for Apple devices without a route.
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
- Lab VMs send only `home.arpa` lookups to `10.10.10.1` and keep public DNS
  (`8.8.8.8`) for everything else ([internal-dns.md](internal-dns.md#lab-vms)),
  so a router outage breaks internal names but not public ones. There is no
  mDNS fallback any more; nginx stays up and its backends return 502 until DNS
  is back.
- Once the Deco hands out `192.168.68.100` as DNS, the router VM is the house's
  resolver too — see [internal-dns.md](internal-dns.md#failure-and-rollback).

If you tear the router down for good, delete its Deco address reservation too —
a reservation pointing at a MAC that no longer exists just shrinks the usable pool.

Rollback is per-VM and cheap: point the VM's `*_static_ip` / `*_gateway` back at
`192.168.68.x` / `192.168.68.1` (or back to DHCP), fix its netplan in-guest, and
update the guest's record in `ansible/dns/records.yml` and re-run the router play. The router VM can stay up
with nothing behind it, or be destroyed with `terraform destroy -target
proxmox_virtual_environment_vm.router`.
