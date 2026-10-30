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
  - { name: partytime, target: router }
```

The play refuses to run if a name appears twice, or if an alias points at
something that isn't in `router_dns_hosts`. dnsmasq can only follow a CNAME to a
name it serves itself. The rendered config is also syntax-checked with
`dnsmasq --test` before it's installed.

**Point browser-facing services at `router`, not at their own lab address.**
iPhones and Macs on the Wi-Fi stall on any real transfer to `10.10.10.x`, because
the traffic hairpins through the Deco (see
[lab-subnet.md](lab-subnet.md#reaching-the-lab-from-the-lan)). A LAN address always
works. So the router is the front door: it forwards ports 80 and 443 on
`192.168.68.100` to nginx-internal's lab address (`router_front_door_target` in
`group_vars/tag_router.yml`), and nginx-internal routes by hostname. Replies come
back through the router, so a phone only ever talks to `192.168.68.100`. To add a
website:

1. Add an alias, `<service>` → `router`.
2. Give nginx-internal a vhost with `server_name <service>.home.arpa` that proxies
   to the backend.
3. Add it to `homepage_links` in `group_vars/tag_nginx_internal.yml`, so it shows
   up on the links page at `http://links.home.arpa`. Apply with
   `ansible-playbook site.yml --limit tag_nginx_internal`.

This way the router's `.100` is the only Deco reservation the lab needs. Every
lab VM is addressed in Terraform, so its record never goes stale. Home Assistant
and the Proxmox nodes keep their existing reservations on the LAN.

**Public names that only work at home.** To serve a name in a real domain with a
trusted HTTPS certificate, without publishing it, add it to
`router_dns_external_aliases` (full name → a host in the zone). dnsmasq answers
only that exact name and forwards the rest of the domain upstream. The
certificate comes from Let's Encrypt over DNS-01, so nothing has to be reachable
from the internet. `homeassistant.panahi-systems.com` is the first one; see
[home-assistant.md](home-assistant.md).

**Order matters.** `records.yml` and the front door hold the post-cutover lab
addresses. Re-run the router play as the last step of the window that moves the
VMs onto the lab subnet, not before. Until then the router keeps serving the
addresses it was last applied with.

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

`site.yml` drops `/etc/systemd/resolved.conf.d/home-arpa.conf` on every managed
VM except the router. It makes `10.10.10.1` the resolver for `home.arpa` only
(a systemd-resolved routing domain, `Domains=~home.arpa`), so lab VMs reach each
other by name while public lookups stay on the `*_nameserver` from Terraform.
This applies to running VMs without editing the netplan cloud-init wrote, and
the server and zone live in `lab_dns_server` / `lab_dns_domain` in
`ansible/group_vars/all/vars.yml`. Check it on a VM:

```bash
resolvectl domain                 # ~home.arpa on the main link
getent hosts docker.home.arpa     # 10.10.10.20
```

## Names, not IPs

`home.arpa` is the only naming in the homelab. Services, scripts and people
address every guest by its name here, never by IP, so moving a guest means
changing one record in `records.yml`. The places that still hold a literal
address are the ones that can't take a name: DNS servers themselves
(`lab_dns_server`, the nginx `resolver`), the router's nftables front-door
DNAT (`router_front_door_target`), Terraform's static addressing, and the
Proxmox API URL in the inventory (its certificate is issued for the IP).

### nginx backends

nginx resolves a host in a literal `proxy_pass` or an `upstream {}` block once,
when it starts, and **refuses to start if the name doesn't resolve**. On
2026-10-23 nginx-cloudflared booted before the router's DNS answered, nginx
exited with `host not found in upstream`, and the public party-time site was
down for three days.

So every vhost proxies to a variable instead:

```nginx
set $immich_backend http://immich.home.arpa:2283;
location / {
    proxy_pass $immich_backend;
}
```

With a variable, nginx looks the name up per request through the `resolver`
in `/etc/nginx/conf.d/resolver.conf` (installed on every nginx host by
`ansible/tasks/nginx-resolver.yml`), and re-checks it every 30 seconds. If DNS
is down, requests get a 502 until it's back, but nginx itself stays up and
recovers on its own. The resolver is `127.0.0.53`, the host's systemd-resolved,
which sends `home.arpa` to the router like every other lookup on the guest.

- Use a variable for every backend: the homelab vhosts in
  `group_vars/tag_nginx*.yml` do, and so do party-time's (`$public_backend`,
  `$admin_backend`, mapped in the party-time repo's `deploy/nginx/*-upstream.conf`).
- Keep exactly one http-level `resolver` per host (this file). A second one in
  another conf.d file makes `nginx -t` fail as a duplicate.

### mDNS was retired (2026-10-30)

The guests used to also answer `.local` names over mDNS (avahi). It failed in
several ways: avahi name conflicts renamed hosts to `nginx-internal-2.local`, a
moved DHCP lease silently changed what `docker.local` meant, and a hand-added
`/etc/hosts` line pinned a dead IP. `site.yml` now purges `avahi-daemon`,
`avahi-utils` and `libnss-mdns` from every guest, which also takes
`mdns4_minimal` out of `nsswitch.conf`, and the `fix-homelab-mdns` skill is
gone. If something old still uses a `.local` name, give it the `home.arpa` name.

Home Assistant still uses mDNS/SSDP on the LAN to discover IoT devices; that's
inside HA and unrelated to how the homelab names its own machines.

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
