<!-- Generated: 2026-09-27 | Files scanned: 26 | Token estimate: ~1680 -->

# Ansible Configuration

Configures VMs after Terraform provisions them. No static inventory — hosts are
discovered from the Proxmox API and grouped by their Proxmox **tags**.

## Files

```
ansible/
  ansible.cfg                    inventory path (loads whole inventory/ dir), vault,
                                  SSH defaults (remote_user=ubuntu)
  requirements.yml               community.proxmox collection + geerlingguy.nginx role
  inventory/proxmox.yml          community.proxmox.proxmox dynamic inventory (cluster API, both nodes)
  files/pve-root-ca.pem          Proxmox cluster CA; inventory verifies the API cert via
                                 REQUESTS_CA_BUNDLE from the repo-root .envrc
  group_vars/
    all/vars.yml           non-secret shared vars (incl. backup_ssh_public_key)
    all/vault.yml          GITIGNORED — vaulted secrets
    all/vault.yml.example  template
    tag_nginx.yml          geerlingguy.nginx baseline config
    tag_router.yml         lab router: lab/LAN subnets, NAT-to-LAN toggle
  roles/router/            REPO-OWNED role — IP forwarding + nftables ruleset
                            + dnsmasq internal DNS (home.arpa)
  roles/immich/            REPO-OWNED role — Immich instances, shared ML, restic backup
  roles/restic_server/     REPO-OWNED role — restic REST server on the docker VM
  dns/records.yml          internal DNS records (hosts + aliases) served by the
                            router's dnsmasq; loaded by the tag_router play
  site.yml                 top-level playbook
  .vault_pass              GITIGNORED — vault password file
  collections/             GITIGNORED — galaxy installs
  roles/*                  GITIGNORED (galaxy installs) EXCEPT hand-written
                            roles re-included in .gitignore (backup, router);
                            add a negation line there for each new one
```

## Inventory flow

homelab1 and homelab2 are one Proxmox cluster (see [`../cluster.md`](../cluster.md)),
so a single inventory source pointed at the cluster API sees the VMs on both
nodes. `ansible.cfg` sets `inventory = inventory/` (a directory), so any extra
source dropped in there would merge into the same host list.

```
inventory/proxmox.yml
  url: https://192.168.68.65:8006   (cluster API — lists homelab1 + homelab2)
  token: proxmox_token_secret
        ▼
  inventory: tag_ansible, tag_nginx, tag_docker,
             tag_nginx_internal, tag_router, tag_backup, ...
```

The source sets `want_facts: true` (per-VM config + guest-agent data),
`keyed_groups: proxmox_tags_parsed → tag_<name>` (Proxmox tags set in
Terraform), `compose: ansible_host` = first non-loopback IPv4 from
`proxmox_agent_interfaces`.

Auth note: inventory plugins load BEFORE group_vars, so token secrets cannot
be plain `{{ ... }}` group vars — each is pulled via
`lookup('ansible.builtin.unvault', 'group_vars/all/vault.yml')` at parse time.

**Gotcha — inventory plugin filename requirement**: `community.proxmox.proxmox`'s
`verify_file()` requires the filename to literally **end in** `.proxmox.yml` /
`.proxmox.yaml`. A file that merely contains "proxmox" elsewhere in its name
(e.g. `proxmox-homelab1.yml`) is **silently declined** — no error, just a
generic "unable to parse" warning — and that inventory source is dropped
entirely. Name any additional source `<name>.proxmox.yml`.

## Groups produced

| Group | Members | Source |
|---|---|---|
| `tag_nginx` | nginx | Proxmox tag `nginx` |
| `tag_ansible` | all VMs | Proxmox tag `ansible` (every managed VM carries it) |
| `tag_docker` | docker | Proxmox tag `docker` |
| `tag_nginx_internal` | nginx-internal | Proxmox tag `nginx_internal` |
| `tag_router` | router | Proxmox tag `router` |
| `tag_backup` | backup | Proxmox tag `backup` |
| `tag_immich` | immich | Proxmox tag `immich` |
| `proxmox_all_qemu` / `proxmox_all_lxc` / `_all_running` | VMs / LXCs (nginx-cloudflared, nginx-internal) | guest type/status |
| `proxmox_homelab2_qemu` / `proxmox_homelab2_lxc` | homeassistant, docker, router / nginx-cloudflared, nginx-internal | per-node |
| `proxmox_homelab1_qemu` | backup, immich (immich is not managed by this repo) | per-node |
| `proxmox_nodes` | homelab2, homelab1 | cluster nodes |

## Playbook

```
site.yml
  hosts: proxmox_hosts     → role proxmox_host (repo-owned): e1000e NIC offloads
                             off; enterprise apt repos commented out,
                             pve-no-subscription.list added (no package changes)
  hosts: tag_ansible:!tag_router → avahi-daemon/libnss-mdns (mDNS) on every VM
                             except the router (avahi would publish its lab
                             address to LAN clients that can't route to it)
  hosts: tag_router        → role router (repo-owned): nftables pkg, ufw removed,
                             ip_forward + send_redirects sysctls,
                             /etc/nftables.conf (validated with `nft --check`),
                             dnsmasq + /etc/dnsmasq.d/lab.conf (validated with
                             `dnsmasq --test`; port 53 opened for LAN + lab)
      ← group_vars/tag_router.yml: router_lab_subnet, router_lan_subnet,
        router_masquerade_to_lan
      ← dns/records.yml (vars_files): router_dns_domain, router_dns_hosts,
        router_dns_aliases — see docs/internal-dns.md
  hosts: tag_nginx         → role geerlingguy.nginx (install/baseline only)
  hosts: tag_cloudflared   → role cloudflared
  hosts: tag_docker        → roles geerlingguy.docker, restic_server, then installs
                             backup_ssh_public_key into ubuntu's authorized_keys
                             (skipped while that var is blank)
  hosts: tag_nginx_internal → role geerlingguy.nginx (install/baseline only)
  hosts: tag_immich        → roles geerlingguy.docker, immich (docs/immich.md)
  hosts: tag_backup        → role backup
      ← group_vars/tag_nginx.yml: nginx_vhosts (port 80, root /var/www/html),
        nginx_remove_default_vhost: true
```

Application-specific vhosts (e.g. party-time's) are NOT applied here — they're
owned by that application's own repo and deploy playbook.

## Role: `backup` (roles/backup/)

Runs on the `backup` VM (homelab1, VM 300) and **pulls** backups from two
homelab2 workloads — see [`architecture.md`](architecture.md#backup-strategy)
for the design rationale (pull model, no offsite copy, no encryption).

| Var (defaults/main.yml) | Default | Notes |
|---|---|---|
| `backup_root` | `/var/backups/homelab` | root of all backup artifacts |
| `backup_ha_url` | `http://homeassistant.home.arpa:8123` | HA Core API |
| `backup_ha_token` | `{{ vault_ha_token }}` | HA long-lived admin token |
| `backup_ha_agent_id` | `hassio.local` | the `backup` integration's local storage agent, confirmed via `backup/agents/info` |
| `backup_ha_create_timeout` | `1800` (seconds) | how long to wait for HA to finish generating a backup |
| `backup_docker_host` / `_user` | `docker.home.arpa` / `ubuntu` | SSH target for pg_dump |
| `backup_ssh_key_path` | `/root/.ssh/id_backup` | private half of `vault_backup_ssh_private_key`, installed by this role |
| `backup_pg_container` / `_database` / `_schema` | `party-time-db` / `party_time` / `party_time` | app data lives in the `party_time` schema, NOT `public` |
| `backup_ha_retention_days` / `backup_pg_retention_days` | `14` / `30` | local pruning |
| `backup_ha_oncalendar` / `backup_pg_oncalendar` | `03:15:00` / `03:45:00` daily | systemd `OnCalendar` |

Tasks: adds the PGDG apt repo and installs `postgresql-client-17` (Ubuntu
24.04's stock `postgresql-client-16` can't `pg_restore --list` a v17 dump —
pg_dump archives are backward-compatible only, never forward), plus `python3`
and `python3-websockets` (for the HA script — `curl`/`jq` are no longer
needed since HA backup is no longer done via plain REST+shell), creates
`backup_root` subdirs, installs the SSH private key (`no_log: true`), deploys
both backup scripts + 4 systemd units, then enables/starts both timers
(`Persistent=true`, `RandomizedDelaySec=15m`).

**Gotcha, costly to rediscover:** HA refuses long-lived access tokens on
`/api/hassio/*` (the Supervisor proxy) with a 401, *even for admin users*.
This was verified empirically against a live HAOS instance: the same token
that gets a 200 from `/api/config/core/check_config` (an admin-only Core
endpoint) gets a 401 with an empty body from `/api/hassio/backups`,
`/api/hassio/info`, and `/api/hassio/core/info`. There is no scope or
permission fix for this — the Supervisor proxy is simply unusable for
unattended automation with a long-lived token. The working path is HA
Core's native `backup` integration: create/list/delete over the WebSocket
API (`/api/websocket`), download over REST (`GET
/api/backup/download/<backup_id>?agent_id=<agent_id>` — the `agent_id`
query param is required, HA 400s without it). `backup-homeassistant.py.j2`
uses this path exclusively.

Scripts (templates/):
- `backup-homeassistant.py.j2` — connects to `{{ backup_ha_url }}/api/websocket`,
  authenticates with the long-lived token, calls `backup/generate` (agent
  `{{ backup_ha_agent_id }}`, full backup: config + database + no addons/folders),
  watches `backup/subscribe_events` (falling back to polling `backup/info`
  by name) until the backup reaches `state: completed` / `manager_state:
  idle`, downloads it over REST to `<backup_root>/homeassistant/ha-<ts>.tar.part`,
  verifies it's non-empty before renaming to `.tar` (a partial `.part` file
  is never left behind or renamed), deletes HA's own copy via
  `backup/delete`, prunes local copies past retention, writes
  `{{ backup_root }}/LAST_SUCCESS_homeassistant`. Exits non-zero with a
  categorized stderr message (`auth` / `create` / `download` / `empty`) on
  any failure. Requires the `python3-websockets` apt package (Ubuntu 24.04
  noble has it).
- `backup-postgres.sh.j2` — SSHes to `backup_docker_host` and runs
  `docker exec party-time-db sh -c 'pg_dump -U "$POSTGRES_USER" -d party_time -n party_time -Fc'`
  (single-quoted so `$POSTGRES_USER` expands only inside the container — no DB
  credentials are stored anywhere in this repo), verifies the dump with
  `pg_restore --list`, then best-effort `scp`s `/opt/party-time/.env.prod`
  (warns, doesn't fail, if missing/unreachable), prunes past retention, writes
  `{{ backup_root }}/LAST_SUCCESS_postgres`.

Neither script's failure is currently alerted on anywhere — the
`LAST_SUCCESS_*` marker files exist but nothing polls them.

## Run

```
ansible-galaxy install -r requirements.yml
ansible-inventory --graph        # nginx under tag_nginx, ansible_host = LAN IP
ansible tag_nginx -m ping
ansible-playbook site.yml
```

## Notes

- Connectivity over the IP the guest agent reports; ZeroTier can layer on later.
  The router reports its LAN IP first, so it needs no route. A VM only on
  `10.10.10.0/24` needs a local route on a Mac control machine via
  `192.168.68.100` — the Deco's static route stalls sustained macOS connections —
  see [`../lab-subnet.md`](../lab-subnet.md).
- Collections resolve from Homebrew's bundled Ansible (`ansible.posix`,
  `community.proxmox`, `community.docker`); `ansible/collections/` is empty.
- `community.proxmox.proxmox` replaces the deprecated `community.general.proxmox`.
