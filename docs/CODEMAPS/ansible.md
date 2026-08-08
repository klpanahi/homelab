<!-- Generated: 2026-06-23 | Files scanned: 7 | Token estimate: ~520 -->

# Ansible Configuration

Configures VMs after Terraform provisions them. No static inventory — hosts are
discovered from the Proxmox API and grouped by their Proxmox **tags**.

## Files

```
ansible/
  ansible.cfg                    inventory path (loads whole inventory/ dir), vault,
                                  SSH defaults (remote_user=ubuntu)
  requirements.yml               community.proxmox collection + geerlingguy.nginx role
  inventory/proxmox.yml          community.proxmox.proxmox dynamic inventory (homelab2)
  inventory/homelab1.proxmox.yml community.proxmox.proxmox dynamic inventory (homelab1)
  group_vars/
    all/vars.yml           non-secret shared vars (incl. backup_ssh_public_key)
    all/vault.yml          GITIGNORED — vaulted secrets
    all/vault.yml.example  template
    tag_nginx.yml          geerlingguy.nginx vhost config
  site.yml                 top-level playbook
  .vault_pass              GITIGNORED — vault password file
  roles/ collections/      GITIGNORED (blanket) — galaxy installs AND hand-written
                            roles (e.g. `backup`) both live here; hand-written roles
                            must be force-added: `git add -f roles/backup`
```

## Inventory flow

homelab1 and homelab2 are two independent, **standalone** Proxmox hosts — not
clustered, so there is no single Proxmox API that sees both. Each host gets
its own inventory source pointed at its own API endpoint; `ansible.cfg` sets
`inventory = inventory/` (a directory, not a single file) so both sources'
`tag_*` groups merge into one host list.

```
inventory/proxmox.yml (homelab2)            inventory/homelab1.proxmox.yml (homelab1)
  url: https://192.168.68.65:8006             url: https://192.168.68.75:8006
  token: proxmox_token_secret                  token: proxmox_token_secret_homelab1
        │                                             │
        └──────────────────┬──────────────────────────┘
                            ▼
              merged inventory: tag_ansible, tag_nginx,
              tag_docker, tag_nginx_internal, tag_backup, ...
```

Both sources: `want_facts: true` (per-VM config + guest-agent data),
`keyed_groups: proxmox_tags_parsed → tag_<name>` (Proxmox tags set in
Terraform), `compose: ansible_host` = first non-loopback IPv4 from
`proxmox_agent_interfaces`.

Auth note: inventory plugins load BEFORE group_vars, so token secrets cannot
be plain `{{ ... }}` group vars — each is pulled via
`lookup('ansible.builtin.unvault', 'group_vars/all/vault.yml')` at parse time.
homelab1's token lives under a **distinct** vault key,
`proxmox_token_secret_homelab1` (both hosts' secrets share one vault file but
are not the same token — homelab1 has its own user/token database).

**Gotcha — inventory plugin filename requirement**: `community.proxmox.proxmox`'s
`verify_file()` requires the filename to literally **end in** `.proxmox.yml` /
`.proxmox.yaml`. A file that merely contains "proxmox" elsewhere in its name
(e.g. `proxmox-homelab1.yml`) is **silently declined** — no error, just a
generic "unable to parse" warning — and that inventory source is dropped
entirely. This is why the second source is named `homelab1.proxmox.yml`, not
`proxmox-homelab1.yml` or `proxmox_homelab1.yml`.

## Groups produced

| Group | Members | Source |
|---|---|---|
| `tag_nginx` | nginx | Proxmox tag `nginx` |
| `tag_ansible` | all VMs | Proxmox tag `ansible` (every managed VM carries it) |
| `tag_docker` | docker | Proxmox tag `docker` |
| `tag_nginx_internal` | nginx-internal | Proxmox tag `nginx_internal` |
| `tag_backup` | backup | Proxmox tag `backup` (homelab1 source) |
| `proxmox_all_qemu` / `_all_running` | all VMs | VM type/status |
| `proxmox_homelab2_qemu` | homeassistant, nginx, docker, nginx-internal | per-node, homelab2 source |
| `proxmox_homelab1_node`'s qemu group | backup | per-node, homelab1 source |
| `proxmox_nodes` | homelab2, homelab1 | node, one per inventory source |

## Playbook

```
site.yml
  hosts: tag_ansible       → avahi-daemon/libnss-mdns (mDNS) on every VM
  hosts: tag_nginx         → role geerlingguy.nginx (install/baseline only)
  hosts: tag_cloudflared   → role cloudflared
  hosts: tag_docker        → role geerlingguy.docker, then installs
                             backup_ssh_public_key into ubuntu's authorized_keys
                             (skipped while that var is blank)
  hosts: tag_nginx_internal → role geerlingguy.nginx (install/baseline only)
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
| `backup_ha_url` | `http://192.168.68.60:8123` | HA Core API |
| `backup_ha_token` | `{{ vault_ha_token }}` | HA long-lived admin token |
| `backup_ha_agent_id` | `hassio.local` | the `backup` integration's local storage agent, confirmed via `backup/agents/info` |
| `backup_ha_create_timeout` | `1800` (seconds) | how long to wait for HA to finish generating a backup |
| `backup_docker_host` / `_user` | `docker.local` / `ubuntu` | SSH target for pg_dump |
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

- Connectivity over the LAN IP the guest agent reports; ZeroTier can layer on later.
- `community.proxmox.proxmox` replaces the deprecated `community.general.proxmox`.
