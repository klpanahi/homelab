# Home Assistant

HAOS runs as VM 200 on homelab2, on the LAN at `192.168.68.60` (Deco
reservation). It stays on the LAN rather than the lab subnet so it can discover
IoT devices over mDNS/SSDP.

| Name | Goes to | Used by |
|---|---|---|
| `http://homeassistant.home.arpa` | router front door → nginx-internal → `192.168.68.60:8123` | People: browsers, the companion app |
| `http://haos.home.arpa:8123` | `192.168.68.60` directly | Services: the backup job (`backup_ha_url`) |
| `http://192.168.68.60:8123` | HA directly | Fallback if the router or nginx-internal is down |

The vhost is `homeassistant.conf` in `nginx_vhosts`
([`ansible/group_vars/tag_nginx_internal.yml`](../ansible/group_vars/tag_nginx_internal.yml)).
It proxies the WebSocket the frontend uses, so dashboards stay live.

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

Then, under Settings → System → Network, set the **Local network** URL to
`http://homeassistant.home.arpa`, and update the companion app's internal URL to
match.

## Checks

```bash
curl -sI http://homeassistant.home.arpa | head -1     # HTTP/1.1 200
curl -s http://haos.home.arpa:8123/manifest.json | head -c 80
```

In a browser, the dashboard should load and update live. HA's logs should show
real client addresses, not `192.168.68.100`.

Over WireGuard the same URL works, since VPN clients reach the router's front
door like any LAN device ([remote-access.md](remote-access.md)).
