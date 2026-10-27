# Remote access (WireGuard on the Deco)

The Deco's built-in WireGuard server is the only way into the homelab from
outside. There is no public URL for anything except party-time, which goes out
through the Cloudflare tunnel. Don't add a second VPN or mesh network alongside
it; one path keeps the router's allow-lists and these docs simple.

| | |
|---|---|
| Server | Deco app → More → Advanced → VPN Server → WireGuard VPN |
| Listen port | `51820/udp` (opened on the Deco's WAN by the Deco itself) |
| Tunnel subnet | `10.5.5.0/24`. Server `10.5.5.1`, peers from `10.5.5.2` up |
| Client access | "Internet and Home Network" |
| NAT | None. Clients reach the LAN with their tunnel address (`10.5.5.2` for the first peer), confirmed with tcpdump on the router 2026-10-26 |
| Router allow-list | `router_vpn_subnets` in [`ansible/group_vars/tag_router.yml`](../ansible/group_vars/tag_router.yml) |

`10.5.5.0/24` doesn't overlap the LAN (`192.168.68.0/22`) or the lab
(`10.10.10.0/24`). If the Deco ever hands out a different tunnel range, update
`router_vpn_subnets` and run the router play (below).

## How a VPN client reaches things

```
iPhone/Mac (10.5.5.x) ──wg──▶ Deco ──LAN──▶ router 192.168.68.100
                                              ├─ :53  dnsmasq (home.arpa)
                                              ├─ :80  front door ─▶ nginx-internal 10.10.10.40
                                              └─ forward ─▶ lab 10.10.10.0/24 (Deco static route)
```

- **DNS:** clients use `192.168.68.100`, so `*.home.arpa` names resolve the same
  as at home. The router only answers subnets it knows, so the tunnel subnet is in
  `router_dns_allowed_subnets` (and `router_ssh_allowed_subnets`) through
  `router_vpn_subnets`. The Deco passes the real `10.5.5.x` source through, so
  without that entry the router silently drops VPN clients' DNS queries.
  The Deco's peer configs default to `DNS = 10.5.5.1` (the Deco itself), which
  doesn't know `home.arpa`. Change it on every client (below).
- **Web:** `http://<name>.home.arpa` names are aliases for the router, whose
  front door forwards ports 80/443 to nginx-internal from any source.
- **Lab SSH:** the router forwards anything to `10.10.10.0/24` from any source,
  and masquerades the replies to its LAN address, so the Deco routes them back
  into the tunnel.

## Applying the router side

From the main checkout, not a worktree (worktrees have no vault):

```bash
cd ~/Documents/Workspace/homelab/ansible
ansible-playbook site.yml --limit tag_router
```

## Client config

1. In the Deco WireGuard page, **Add Peer** (one per device; the `Default` peer
   is `10.5.5.2`) and share its config to the device.
2. Import it into the WireGuard app on the iPhone or Mac and edit it:
   - `DNS = 192.168.68.100`, replacing the Deco's default `10.5.5.1`. In the
     iOS app: tap the tunnel → Edit → Interface → DNS servers.
   - `AllowedIPs = 192.168.68.0/22, 10.10.10.0/24` for a split tunnel (only home
     traffic goes through the VPN). Keep the Deco's default `0.0.0.0/0` instead if
     you want all traffic to go home, for example on public Wi-Fi.
3. On the iPhone, turn on **On-Demand** for cellular and Wi-Fi networks other than
   home, so the tunnel comes up by itself when you leave.

The Mac's persistent `10.10.10.0/24 → 192.168.68.100` route (see
[`lab-subnet.md`](lab-subnet.md)) is tied to the Wi-Fi service, and that
gateway is unreachable away from home. With the tunnel up, WireGuard's
`10.10.10.0/24` route through `utun` is used instead. If lab SSH hangs away from
home, check `route -n get 10.10.10.40` shows the `utun` interface.

## Checks

On cellular (Wi-Fi off) with the tunnel up:

```bash
dig @192.168.68.100 homelab2.home.arpa +short   # resolves
curl -sI http://links.home.arpa | head -1       # HTTP/1.1 200, via the front door
ssh ubuntu@docker.home.arpa true                # lab SSH through the router
ssh root@homelab2.home.arpa pveversion          # LAN SSH
```

Run SSH with real output (for example `journalctl -n 200`), not just `true`.
The Deco's hairpin path stalls macOS sessions once data flows (see
[`lab-subnet.md`](lab-subnet.md)), so a short check can pass even if a real
session would hang.

Last verified 2026-10-26 from the iPhone on cellular: `http://links.home.arpa`
(through the router's front door), `https://homelab2.home.arpa:8006` and
`http://192.168.68.60:8123` all loaded.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Names don't resolve, IPs work | The client's `DNS` is still the Deco default `10.5.5.1` instead of `192.168.68.100`, or the tunnel subnet changed and isn't in `router_vpn_subnets` |
| LAN works, lab doesn't | `AllowedIPs` is missing `10.10.10.0/24` |
| Handshake never completes | The Deco's WAN IP changed (no DDNS in the peer `Endpoint`), or the carrier blocks UDP 51820 |
