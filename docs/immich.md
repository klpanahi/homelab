# Immich

Self-hosted photo library replacing Google Photos. One VM on homelab1 runs
several independent Immich instances, so friends can have their own without
touching the personal library.

| | |
|---|---|
| VM | `immich`, VM 301 on homelab1, `10.10.10.50` ([`terraform/immich.tf`](../terraform/immich.tf)) |
| Size | 4 vCPU, 4 GB RAM, 32 GB root disk, 200 GB data disk at `/srv/immich` |
| Instances | [`ansible/group_vars/tag_immich.yml`](../ansible/group_vars/tag_immich.yml) |
| Role | [`ansible/roles/immich`](../ansible/roles/immich) |
| Version | `immich_version` in the role defaults (all instances share one) |
| Backups | restic, nightly at 04:15, to the docker VM on homelab2 |

homelab1 hosts it because homelab2's 8 GB is already overcommitted (see the
Hardware section of `agent.md`).

## Instances and how they're reached

| Instance | Port | Address | Reached from |
|---|---|---|---|
| `personal` | 2283 | `http://photos.home.arpa` | Home Wi-Fi and the Deco's WireGuard VPN only |
| `personal` share links | 3000 | `https://immich-shared.panahi-systems.com` | Internet, shared items only |
| `austin` | 2284 | `https://austins-photos.panahi-systems.com` | Internet, via the Cloudflare Tunnel |

- **Personal.** `photos.home.arpa` is an alias to `router` in
  `ansible/dns/records.yml`. The router forwards port 80/443 on `192.168.68.100`
  to nginx-internal, whose `photos.home.arpa` vhost proxies to `immich.home.arpa:2283`.
  Phones never talk to `10.10.10.x` directly, which is what stalls on Apple
  devices (docs/lab-subnet.md). Plain HTTP for now, since `home.arpa` can't get a
  public certificate; WireGuard encrypts it off-site.
- **Share links.** [Immich Public Proxy](https://github.com/alangrainger/immich-public-proxy)
  runs next to the personal instance and serves only what is shared by link. The
  personal login, library and API are never on the internet.
- **Austin.** nginx-cloudflared proxies the hostname to `immich.home.arpa:2284`.
  Immich has no self sign-up: the first account created becomes the admin, and
  the admin creates everyone else.
- **Machine learning** (faces, smart search) runs in one container shared by
  every instance, on the `immich-ml` Docker network. It unloads idle models,
  which is what keeps two instances inside 4 GB.

Cloudflare's free plan caps a single upload at 100 MB, so very long videos fail
to upload to the public instance from outside the house.

## Bring-up

1. **Vault secrets.** Add the Immich block from
   `ansible/group_vars/all/vault.yml.example` to `group_vars/all/vault.yml`
   (`ansible-vault edit`). Keep a copy of `vault_immich_restic_password` in a
   password manager: without it the backups can't be read.
2. **Terraform.** `terraform apply` creates the immich VM and adds the 100 GB
   restic disk to the docker VM (`docker_restic_disk_gb`). Check the plan first:
   the docker VM must show as updated in place, not replaced.
3. **Collections.** `ansible-galaxy install -r requirements.yml` (adds
   `community.general`).
4. **DNS and the docker VM.**
   `ansible-playbook site.yml --limit tag_router,tag_docker` publishes
   `photos.home.arpa` and starts the restic server on the docker VM.
5. **Immich.** `ansible-playbook site.yml --limit tag_immich`.
6. **Proxies.** `ansible-playbook site.yml --limit tag_nginx,tag_nginx_internal`.
7. **Tunnel hostnames.** Add `austins-photos.panahi-systems.com` and
   `immich-shared.panahi-systems.com` as public hostnames on the existing tunnel, pointing
   at the same nginx service party-time's hostname uses.
8. **First login.** Open each instance and create its admin account. On the
   personal instance, set **Administration → Settings → Server → External
   domain** to `https://immich-shared.panahi-systems.com`, so share links use the proxy.
9. **Check a backup.** `sudo systemctl start immich-backup.service`, then
    `journalctl -u immich-backup -e` on the immich VM.

## Moving the Google Photos library

One-time, into the personal instance:

1. Request a [Google Takeout](https://takeout.google.com) export of Google Photos
   only, as `.zip` files.
2. In the personal instance, create an API key under **Account Settings → API
   Keys**.
3. Import with [immich-go](https://github.com/simulot/immich-go), which reads the
   Takeout JSON so dates, albums and locations come through:

   ```bash
   immich-go upload from-google-photos \
     --server=http://photos.home.arpa --api-key=<key> takeout-*.zip
   ```

4. Install the Immich phone app, sign in at `http://photos.home.arpa`, and turn
   on backup. New photos go to Immich from then on.

## Adding an instance

1. Add an entry to `immich_instances` with an unused `name` and `port`.
2. Add its password to `vault_immich_db_passwords` in the vault.
3. Add a vhost: nginx-internal plus a `home.arpa` alias for LAN-only, or
   nginx-cloudflared plus a tunnel hostname for public.
4. Run the immich play and the nginx play. The nightly backup picks the new
   library up automatically.

## Backups

`/usr/local/bin/immich-backup.sh` on the immich VM, run by
`immich-backup.timer`:

- **What:** every instance's library, including `library/backups`, where Immich
  writes its own database dump every night at 02:00. Thumbnails and transcoded
  video are skipped because Immich regenerates them.
- **Where:** the restic REST server on the docker VM (`docker.home.arpa:8000`, data
  on its `/srv/restic` disk), set in `/etc/immich-backup/homelab2.env`. A
  different machine, but the same building: there is no offsite copy. Another
  destination can be added later as another `.env` file in that directory.
- **History:** 30 daily and 12 monthly snapshots.
- **Health:** `/var/lib/immich-backup/LAST_SUCCESS_<repo>` holds the time of the
  last good run. Like the other backups here, nothing alerts on it yet.

### Restoring

On the immich VM, as root:

```bash
set -a; . /etc/immich-backup/homelab2.env; set +a
restic snapshots
restic restore latest --target /srv/restore --include /srv/immich/personal/library
```

Then follow Immich's
[restore guide](https://docs.immich.app/administration/backup-and-restore): put
the library back, start a fresh database, and load the newest dump from
`library/backups`.
