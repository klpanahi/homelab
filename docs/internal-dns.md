# Internal DNS (`home.arpa`)

dnsmasq on the router VM answers for a private zone, `home.arpa`, and forwards
every other name to public resolvers. Once the Deco hands its address out as the
DNS server, every device on the Wi-Fi can open names like
`https://homelab2.home.arpa:8006` with no per-device setup.

| | |
|---|---|
| Resolver | dnsmasq on `router` (VM 204), listening on `192.168.68.100` (LAN) and `10.10.10.1` (lab) |
| Zone | `home.arpa`, reserved by RFC 8375 for exactly this. `.local` belongs to mDNS |
| Records | [`ansible/dns/records.yml`](../ansible/dns/records.yml), the only file you edit |
| Everything else | Forwarded to `1.1.1.1` and `9.9.9.9` |
| Config owner | `ansible/roles/router` (dnsmasq, plus port 53 in the nftables input chain) |

It serves DNS only. No DHCP scope is configured, so it never competes with the
Deco for leases.

## Adding a name

Edit `ansible/dns/records.yml`, then apply:

```bash
cd ansible
ansible-playbook site.yml --limit tag_router
```

There are two kinds of entry:

```yaml
router_dns_hosts:          # name -> address
  - { name: homelab2, ip: 192.168.68.65 }

router_dns_aliases:        # name -> another name in router_dns_hosts
  - { name: party-admin, target: nginx-internal }
```

The play refuses to run if a name appears twice, or if an alias points at
something that isn't in `router_dns_hosts`. dnsmasq can only follow a CNAME to a
name it serves itself. The rendered config is also syntax-checked with
`dnsmasq --test` before it's installed.

**Point browser-facing services at nginx-internal, not at their own lab
address.** iPhones and Macs on the Wi-Fi stall on any real transfer to
`10.10.10.x` because traffic hairpins through the Deco (see
[lab-subnet.md](lab-subnet.md#reaching-the-lab-from-the-lan)). A name that
resolves to a LAN address always works, so the pattern is:

1. Add an alias, `<service>` → `nginx-internal`.
2. Give nginx-internal a vhost with `server_name <service>.home.arpa` that proxies
   to the backend. The backend can live on the lab subnet, because nginx-internal
   reaches it through the router.

`nginx-internal` at `192.168.68.85` is still a plain dynamic lease. Reserve it in
the Deco before you lean on aliases, or they all break the day the lease moves.

Lab VMs have no such problem. They can be given `10.10.10.x` records and reach
each other directly.

## Pointing the Wi-Fi at it

Apply the router play first and check that the resolver answers. From a Mac on
the Wi-Fi:

```bash
dig @192.168.68.100 homelab2.home.arpa +short     # 192.168.68.65
dig @192.168.68.100 example.com +short            # forwarding works
```

Then, in the Deco app, go to **More → Advanced → DHCP Server** and set
**Primary DNS** to `192.168.68.100`.

- **Use the DHCP Server page, not IPv4 → DNS.** The IPv4 page sets the DNS the
  Deco itself uses upstream. Pointing that at the router would make the Deco
  depend on a VM, and it isn't how clients learn their resolver.
- **Secondary DNS:** leave it empty if the app allows that. Clients spread
  queries across both servers, so a public secondary such as `8.8.8.8` would
  intermittently answer "no such name" for `home.arpa` names. The cost is that
  if the router VM is down, the house has no DNS (see
  [Failure and rollback](#failure-and-rollback)).
- **Devices pick it up at their next lease renewal.** Toggle Wi-Fi off and on to
  force it now.
- **IPv6:** if IPv6 is enabled on the Deco, it may also advertise its own IPv6
  DNS server, and clients that use it won't see `home.arpa`. If names resolve
  inconsistently on a device that has an IPv6 address, turn IPv6 off on the Deco
  (More → Advanced → IPv6).

Check from a phone or laptop on the Wi-Fi:

```bash
dig homelab2.home.arpa +short          # macOS/Linux, using the DHCP-provided DNS
scutil --dns | grep nameserver         # macOS: should list 192.168.68.100
```

On an iPhone, open `https://homelab2.home.arpa:8006`. A certificate warning is
expected, but a "server not found" error is not.

### Lab VMs

Set a VM's existing `*_nameserver` Terraform variable to `10.10.10.1` when it
moves onto the lab subnet. Running VMs need the change in-guest as well (the
netplan `nameservers:` block, then `sudo netplan apply`), because cloud-init
writes network config only once.

## mDNS / avahi

Nothing changes for mDNS. `.local` names (`docker.local`, `nginx-internal.local`)
are still answered by avahi over multicast, and `home.arpa` is ordinary unicast
DNS. The two zones don't overlap, and clients query each one the right way on
their own.

The plan is to replace mDNS, not to run both forever. As services move to fixed
addresses, give each one a record here and switch its consumers from `X.local` to
`X.home.arpa`. For example, nginx-internal's upstream (in the party-time repo) and
`backup_docker_host` in `ansible/roles/backup/defaults/main.yml`. Once nothing
resolves a `.local` name, avahi can come out of the `tag_ansible` play in
`site.yml`. That removes the failure class the `fix-homelab-mdns` skill exists
for: a moved lease silently changing what a name means.

The router stays excluded from avahi, as before. It publishes its LAN address as
`router.home.arpa` here instead.

## Failure and rollback

- **The router VM is now the house's DNS.** If it's down, Wi-Fi devices can't
  resolve anything, internet names included. It is `on_boot = true` on homelab2.
  Debug from the router with `systemctl status dnsmasq` and
  `journalctl -u dnsmasq`. Set `router_dns_log_queries: true` and re-run the play
  to log every query.
- **Fast rollback:** in the Deco app, set DHCP Server DNS back to automatic.
  Devices return to the Deco's resolver as they renew, or right away after a Wi-Fi
  toggle. Nothing else depends on the resolver, so this is safe at any time.
- **Remove it from the router:** set `router_dns_enabled: false` in
  `group_vars/tag_router.yml` and re-run the play. That closes port 53. Then
  `sudo systemctl disable --now dnsmasq` on the router.
- **Later:** Pi-hole is dnsmasq with a UI and can take over this job. Its
  "Local DNS records" use the same name → IP shape as `records.yml`.
