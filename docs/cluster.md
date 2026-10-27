# Proxmox cluster

homelab2 (`192.168.68.65`) and homelab1 (`192.168.68.75`) form one Proxmox VE
cluster named `homelab`. Before the cluster existed they were standalone
installs, so the repo needed two Terraform providers, two API tokens and two
Ansible inventory sources. Now there is one of each:

- **Terraform**: one `proxmox` provider pointed at homelab2's API. A resource
  picks its host with `node_name` (`var.proxmox_node` or
  `var.proxmox_homelab1_node`). The provider still has one SSH `node` block per
  host, because snippets upload to each node's own `local` datastore.
- **Ansible**: `inventory/proxmox.yml` queries the cluster API and sees the VMs
  on both nodes.
- **Token**: `root@pam!terraform`, which is cluster-wide (`/etc/pve` is shared).

| | homelab2 | homelab1 |
|---|---|---|
| Role | cluster founder | joined |
| corosync link0 | `192.168.68.65` | `192.168.68.75` |
| VMs | 200–204 | 300 (backup), 301 (immich, not in this repo) |

There's **no shared storage**: each node keeps its own `local` and `local-lvm`.
Migrating a VM copies its disk over the LAN, and the backup VM should stay on
homelab1 (see `terraform/backup.tf`).

## Quorum: two nodes, no QDevice

Each node has one vote and quorum needs 2. **If either node is down, the
survivor loses quorum.** Its running VMs keep running, but `/etc/pve` goes
read-only: you can't start, stop or create VMs or change their config, and
Terraform calls fail.

To recover while the peer is still down, run this on the surviving node:

```bash
pvecm expected 1
```

This holds only until the peer rejoins or corosync restarts. Don't run it on
both nodes while they can't reach each other: two independent quorate halves
would diverge.

Check the state at any time:

```bash
pvecm status
```

A healthy cluster reports `Quorate: Yes` with 2 nodes.

## Packages and upgrades

Neither node has a subscription key, so both use the free
`pve-no-subscription` repo:

- `/etc/apt/sources.list.d/pve-no-subscription.list`:
  `deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription`
- The `deb` lines in `pve-enterprise.list` and `ceph.list` are commented out.
  Without a key, those repos make `apt update` fail. The originals are kept as
  `/root/*.list.bak`.

PVE installs ship with the enterprise repos enabled. Switch a fresh install
before its first `apt update`.

**Keep both nodes on the same versions.** Corosync and pve-cluster must match
across the cluster. Upgrade one node at a time and finish both in the same
sitting:

```bash
apt update && apt full-upgrade
pveversion -v | egrep 'pve-manager|pve-cluster|corosync'   # compare across nodes
```

`full-upgrade` doesn't restart VMs. A new kernel or QEMU only takes effect
after a node reboot or a VM stop/start. Rebooting a node drops quorum on the
other node (see above), and rebooting homelab2 takes down Home Assistant and
the lab router.

## How it was formed (runbook)

The cluster was formed on 2026-10-23..26 with these steps, run as root over
SSH. A joining node must have no guests, so homelab1's VMs were moved aside
during the join. Backup and immich were down for about a minute.

1. Back up both nodes:
   - `/etc/pve` on each: `tar czf /root/pve-etc-$(date +%F).tgz /etc/pve`.
   - The guests on homelab1:
     `vzdump 300 301 --mode snapshot --storage local --compress zstd`.
     This writes to `/var/lib/vz/dump/` (about 4.5 GB in total; the disks are
     mostly empty).
2. Bring both nodes to the same versions. Before upgrading, check
   `/etc/apt/sources.list.d/`: both nodes still had the enterprise repos and
   needed the switch described in [Packages and upgrades](#packages-and-upgrades).
   Then run `apt update && apt full-upgrade -y` on **both** nodes, not just the
   older one; otherwise the newer node is ahead again. Both ended on
   pve-manager 8.4.21, pve-cluster 8.1.3 and corosync 3.1.10. Neither node was
   rebooted.
3. Fix `/etc/hosts` on each node so its own name maps to its LAN address,
   e.g. `192.168.68.65 homelab2.home.arpa homelab2`. Add a line for the peer,
   then run `systemctl restart pve-cluster pveproxy`. The old entries were
   `192.168.86.151 homelab2.px` and `192.168.100.2 homelab1.local`, left from
   earlier networks. `hostname --ip-address` must print the LAN IP.
4. On homelab2: `pvecm create homelab --link0 192.168.68.65`.
5. On homelab1:
   - Stop the guests: `qm shutdown 300; qm shutdown 301`.
   - Move `/etc/pve/qemu-server/30{0,1}.conf` and any `/etc/pve/firewall/30*.fw`
     to `/root/guest-conf/`. There were no firewall files.
   - Add homelab1's root key (`/root/.ssh/id_rsa.pub`) to homelab2's
     `/etc/pve/priv/authorized_keys`. `/root/.ssh/authorized_keys` is a symlink
     to that file. Test it with `ssh root@192.168.68.65 hostname` from homelab1.
6. On homelab1: `pvecm add 192.168.68.65 --link0 192.168.68.75 --use_ssh`.
   This merges the authorized keys, so the Mac's key keeps working on both nodes.
7. Copy the saved configs into `/etc/pve/nodes/homelab1/qemu-server/` (and the
   firewall files into `/etc/pve/firewall/`), then `qm start 300; qm start 301`.
   The disks are on `local-lvm`, which has the same name on both nodes, so the
   configs work unchanged. The first start regenerates the cloud-init ISOs.
8. Verify:
   - `pvecm status` shows Quorate with 2 nodes.
   - `qm list` on each node shows its VMs running.
   - `/api2/json/nodes/homelab1/qemu`, queried through homelab2's API with the
     terraform token, lists 300 and 301.

Leftovers from the run:
- homelab2: `/root/pve-etc-2026-10-23.tgz`, `/root/hosts.bak`, `/root/*.list.bak`,
  `/root/upgrade-2026-10-23.log`.
- homelab1: the same files, plus `/root/guest-conf/` and the vzdump archives in
  `/var/lib/vz/dump/`. Delete them once the cluster has proven stable.
- During the upgrade, homelab2's apt warned that GRUB doesn't update the
  removable EFI bootloader (`/boot/efi/EFI/BOOT/BOOTX64.efi`). This hasn't been
  fixed yet. The fix apt suggests is
  `echo 'grub-efi-amd64 grub2/force_efi_extra_removable boolean true' | debconf-set-selections -v -u`
  followed by `apt install --reinstall grub-efi-amd64`.

The join replaces homelab1's user and token database with the cluster's.
homelab1's old standalone token no longer exists, so remove
`proxmox_homelab1_api_token` from `terraform.tfvars` and
`proxmox_token_secret_homelab1` from the Ansible vault.
