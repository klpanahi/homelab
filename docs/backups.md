# Backups

Three layers, from coarse to fine:

| What | How | Where it lands | Schedule |
|---|---|---|---|
| Every guest, whole (VMs and LXCs) | Proxmox vzdump jobs, `ansible/roles/proxmox_host/tasks/backups.yml` | USB backup disk | 02:30 Central, nightly |
| party-time Postgres, Home Assistant | `backup` role on the backup LXC (pull over SSH / HA API) | backup LXC's own disk, `/var/backups/homelab/` | 03:15 / 03:45 UTC |
| Immich photo libraries | restic from the Immich VM (`immich` role) | restic REST server on the docker VM | 04:15 UTC |

The guest-level vzdump jobs are the safety net for everything else: a bad
upgrade, a broken guest, a failed SSD. Everything lives in the same building;
there is no offsite copy.

## The USB backup disk

| | |
|---|---|
| Drive | Seagate Portable 1.8 TB, USB (`/dev/disk/by-id/usb-Seagate_Portable_NACA5G8C-0:0`) |
| Filesystem | one ext4 partition, label `homelab-backup`, UUID `f4cfb007-d29c-4cc4-bac3-21785c26c929`, 0% reserved |
| Attached to | **homelab2** (`proxmox_backup_disk_node` in `group_vars/proxmox_hosts.yml`) |
| Mounted at | `/mnt/backup-hdd`, by UUID with `nofail,x-systemd.device-timeout=10s` |
| Health | SMART isn't readable through this USB bridge (only the coarse SCSI status, which is OK). A full read-only `badblocks` scan ran after formatting on 2026-10-30; it finished with 0 bad blocks (`/root/badblocks-homelab-backup.txt` on homelab2 is empty). |

Prepared on 2026-10-30: it held an old APFS (Mac) volume, which was wiped with
the owner's approval.

**It stays on homelab2** (owner's decision, 2026-10-30). The trade-off: most
workloads (Home Assistant, docker, router, both nginx guests) run on homelab2,
so a homelab2 failure can take those guests and their backups out together.
If that changes, moving it is:

1. Plug the drive into homelab1.
2. Set `proxmox_backup_disk_node: homelab1` in `group_vars/proxmox_hosts.yml`.
3. `ansible-playbook site.yml --limit proxmox_hosts`. This mounts it on
   homelab1, moves the NFS export, re-points both storages and both jobs.
   Existing backups on the disk carry over.
4. Remove the stale mount on homelab2: `umount /mnt/backup-hdd` and delete its
   line from `/etc/fstab` (the role doesn't clean up the old node's fstab).

## How the jobs are wired

The disk hangs off one node. Proxmox storage is cluster-wide, so the same
directory appears as two storages:

| Storage | Type | Nodes | Used by |
|---|---|---|---|
| `backup-hdd` | dir, `is_mountpoint yes` | the disk node | that node's job |
| `backup-hdd-nfs` | NFS from `<disk node>.home.arpa:/mnt/backup-hdd` | every other node | their jobs |

`is_mountpoint` means a missing disk marks the storage offline and the job
fails loudly, instead of quietly filling the root disk. The NFS export is
limited to the other Proxmox nodes' addresses from `inventory/hosts.yml`.

Jobs `homelab-nightly-homelab1` and `homelab-nightly-homelab2` back up every
guest on their node (`--all 1`), snapshot mode, zstd, retention
`keep-daily=7,keep-weekly=4,keep-monthly=3`. See them in the Proxmox UI under
Datacenter → Backup, or with `pvesh get /cluster/backup`.

Size: all guests together hold about 46 GB of data (2026-10-30), and a full set
compresses to well under that, so the disk holds months of retention. The
Immich VM's 200 GB library disk is the one that will grow; if it starts to
crowd the disk, exclude that disk from vzdump (`backup=0` on the disk in
Terraform), since restic already backs the photos up.

## Restore

From the Proxmox UI: the storage → Backups → pick one → Restore. From a shell,
to a new ID without touching the original:

```bash
pct restore 9203 /mnt/backup-hdd/dump/vzdump-lxc-203-<date>.tar.zst --storage local-lvm --unique 1
qmrestore /mnt/backup-hdd/dump/vzdump-qemu-202-<date>.vma.zst 9202 --storage local-lvm --unique 1
```

A restore keeps the guest's network config, so don't start a copy next to the
original without changing its address (or set `link_down=1` on its NIC).

Tested 2026-10-30: nginx-internal (CT 203) restored to 9203, its rootfs had
the current nginx config and admin UI, then 9203 was destroyed.

## Failure notifications

vzdump notifies the `mail-to-root` target, which mails `root@pam`'s address
(`klpanahi2@gmail.com`). Whether mail actually leaves the Proxmox hosts hasn't
been checked; until it is, look at Datacenter → Backup / the task log after a
change.
