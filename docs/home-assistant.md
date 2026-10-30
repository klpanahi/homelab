# Home Assistant

HAOS runs as VM 200 on homelab2, on the LAN at `192.168.68.60` (Deco
reservation). It stays on the LAN rather than the lab subnet so it can discover
IoT devices over mDNS/SSDP.

| Name | Goes to | Used by |
|---|---|---|
| `https://homeassistant.panahi-systems.com` | router front door → nginx-internal (TLS) → `haos.home.arpa:8123` | People: browsers, the companion app. HA's Local network URL |
| `http://homeassistant.home.arpa` | 301 to the HTTPS name | Old bookmarks |
| `http://haos.home.arpa:8123` | `192.168.68.60` directly | Services: the backup job (`backup_ha_url`) |
| `http://haos.home.arpa:8123` | HA directly | Fallback if nginx-internal is down. `http://192.168.68.60:8123` if DNS (the router) is down too |

## Home and WireGuard only

`homeassistant.panahi-systems.com` isn't in public DNS. The router's dnsmasq
answers it itself (`router_dns_external_aliases` in
[`ansible/dns/records.yml`](../ansible/dns/records.yml)) as a CNAME to
`router.home.arpa`, so it works for anything that uses `192.168.68.100` for DNS:
the Wi-Fi, and WireGuard clients set up per [remote-access.md](remote-access.md).
Every other `panahi-systems.com` name, including the Cloudflare tunnel sites,
still resolves publicly.

Off the network, the name currently resolves to the public `*.panahi-systems.com`
wildcard (a dead ZeroTier address), so it fails rather than reaching anything.

## Certificate

A Let's Encrypt certificate issued by `ansible/roles/letsencrypt` on
nginx-internal with the DNS-01 challenge: certbot creates a TXT record through
Cloudflare's API, so HA never has to be reachable from the internet.

| | |
|---|---|
| Certificates | `letsencrypt_certificates` in [`ansible/group_vars/tag_nginx_internal.yml`](../ansible/group_vars/tag_nginx_internal.yml) |
| Files | `/etc/letsencrypt/live/homeassistant.panahi-systems.com/` on nginx-internal |
| Renewal | `certbot.timer`, twice a day; renews within 30 days of expiry and reloads nginx |
| API token | `vault_cloudflare_dns_token`, scoped to DNS Write + Zone Read on `panahi-systems.com`, written to `/etc/letsencrypt/cloudflare.ini` (0600) |
| Registration | No email address. Let's Encrypt stopped sending expiry mail in 2025 |

To check renewal: `ssh root@nginx-internal.home.arpa certbot renew --dry-run`.
To add another name, add it to `letsencrypt_certificates` and to
`router_dns_external_aliases`, then give nginx-internal a vhost for it.

## Reverse proxy settings in HA

HA rejects proxied requests (HTTP 400) unless it trusts the proxy. Requests
reach it from the router's LAN address, `192.168.68.100`, not from
nginx-internal's `10.10.10.40`, because the router masquerades lab traffic
bound for the LAN (`router_masquerade_to_lan`). In `configuration.yaml`
(File editor add-on):

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 192.168.68.100
```

Restart HA after changing it. If `router_masquerade_to_lan` is ever set to
`false`, the source becomes `10.10.10.40` and this list has to change with it.

Settings → System → Network → **Local network** URL is
`https://homeassistant.panahi-systems.com`. Use the same URL as the companion
app's internal URL.

## Checks

```bash
dig @192.168.68.100 homeassistant.panahi-systems.com +short   # router.home.arpa. 192.168.68.100
curl -sI https://homeassistant.panahi-systems.com | head -1    # HTTP/2 200 or HTTP/1.1 200, no cert error
curl -s http://haos.home.arpa:8123/manifest.json | head -c 80
```

In a browser, the dashboard should load with a padlock and update live. HA's
logs should show real client addresses, not `192.168.68.100`.
