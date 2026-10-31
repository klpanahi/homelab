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
| Guests | 200–204 | 300 (backup LXC), 301 (immich) |

There's **no shared storage**: each node keeps its own `local` and `local-lvm`.
Migrating a guest copies its disk over the LAN, and the backup LXC should stay on
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
  `deb http://download.proxmox.com/debian/pve trixie pve-no-subscription`
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

### Major upgrade: PVE 8 → 9 (done 2026-10-30)

Both nodes went from 8.4.21 (bookworm) to 9.2.24 (trixie, kernel 7.0) in one
sitting, with every guest shut down. Neither node can hold the other's guests
(8 GB RAM each, local-lvm only), so a rolling migration wasn't an option.
Total downtime was about 20 minutes, most of it the dist-upgrade.

1. `pve8to9 --full` on both nodes. Fix every FAIL first:
   - `systemd-boot` meta-package installed: both nodes boot through GRUB
     (`proxmox-boot-tool status` says `proxmox-boot-uuids does not exist`), so
     `apt remove systemd-boot`.
   - Removable EFI bootloader present (homelab2): `echo 'grub-efi-amd64
     grub2/force_efi_extra_removable boolean true' | debconf-set-selections -v -u`,
     then `apt install --reinstall grub-efi-amd64`.
   - A custom role uses `VM.Monitor`: that's the unused `Terraform` role (no ACL
     references it; the token is `root@pam!terraform`). It's fixed after the
     upgrade, see step 6.
2. Shut down every guest (`qm shutdown`, `pct shutdown`).
3. **Point the nodes at public DNS first.** They resolve through the router VM
   (`192.168.68.100`), which is now off, so `apt update` fails on every mirror
   and the dist-upgrade silently does nothing (`0 upgraded`). Save
   `/etc/resolv.conf`, write `nameserver 1.1.1.1`, and restore it before the
   reboot.
4. `sed -i 's/bookworm/trixie/g' /etc/apt/sources.list /etc/apt/sources.list.d/*.list`
   (plus `ceph-quincy` → `ceph-squid` in the commented `ceph.list`), then run
   the upgrade detached so a dropped SSH session can't kill dpkg:

   ```bash
   systemd-run --unit=pve9-upgrade --setenv=DEBIAN_FRONTEND=noninteractive /bin/sh -c \
     "apt-get update && apt-get -y -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold dist-upgrade"
   ```

   Both nodes ran it at the same time; it took about 10 minutes
   (~590 packages). `dpkg --audit` was clean afterwards.
5. Restore `/etc/resolv.conf`, reboot both. Every guest has `onboot: 1` and
   came back by itself; the cluster was quorate on boot.
6. Drop `VM.Monitor` from the `Terraform` role and add `VM.GuestAgent.Audit`
   (`pveum role modify Terraform --privs ...`). `terraform plan` showed no
   changes afterwards.

The `pve-no-subscription` repo in `ansible/roles/proxmox_host` follows
`ansible_facts['distribution_release']`, so it needed no change. The only
remaining `pve8to9` FAIL is the missing `intel-microcode` package, which needs
the `non-free-firmware` component and is optional.

**Clients' DNS after a router outage.** After this upgrade the Mac's DHCP lease
listed the ISP's resolvers (`209.18.47.62/63`) instead of `192.168.68.100`, so
`home.arpa` names stopped resolving on it while every service was healthy.
Check the Deco's DHCP Server → Primary DNS (see
[internal-dns.md](internal-dns.md)) and renew the lease (Wi-Fi off and on).

## TLS certificates

Each node's API/web cert (`/etc/pve/nodes/<node>/pve-ssl.pem`) is signed by the
cluster CA, `/etc/pve/pve-root-ca.pem`. The repo's trust anchor is
`ansible/files/pve-root-ca.pem`, a public cert valid until 2036.

That file is **not a byte-for-byte copy** of `/etc/pve/pve-root-ca.pem`. PVE
generates its CA with a bare `openssl req -x509`, so the cert has no `keyUsage`
extension, and Python 3.13+ rejects it in its default strict mode ("CA cert does
not include key usage extension"). The committed cert was re-issued from the
**same CA key and subject** with `keyUsage = keyCertSign, cRLSign` added. It has
the same public key and subject key identifier, so the existing node certs
verify against it unchanged, and Proxmox itself is untouched. It was made on
homelab2, so the key never left the node:

```bash
ca=/etc/pve/pve-root-ca.pem
subj=$(openssl x509 -in $ca -noout -subject -nameopt compat | sed 's/^subject=//')
openssl req -new -x509 -key /etc/pve/priv/pve-root-ca.key -subj "$subj" -days 3650 -sha256 \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" -out /root/pve-root-ca-ku.pem
openssl verify -x509_strict -CAfile /root/pve-root-ca-ku.pem /etc/pve/nodes/*/pve-ssl.pem
```

Ansible's Proxmox inventory verifies the API cert (`validate_certs: true`).
The plugin has no CA-path option, so the repo's `.envrc` exports
`REQUESTS_CA_BUNDLE`. It points at a generated bundle of the macOS system roots
plus the cluster CA, so public HTTPS keeps working in the same shell. One-time
setup:

```bash
brew install direnv
echo 'eval "$(direnv hook zsh)"' >> ~/.zshrc   # then open a new shell
cd ~/Documents/Workspace/homelab-workspace/repos/homelab && direnv allow
```

Without direnv, run the same exports by hand (`source .envrc` from the repo
root) before running Ansible. If they're missing, inventory parsing fails with
`CERTIFICATE_VERIFY_FAILED`.

The certs' SANs come from `/etc/hosts` when they're generated. They originally
carried pre-cluster addresses (`192.168.86.151` on homelab2), so on 2026-10-26
both were regenerated with `pvecm updatecerts --force && systemctl restart
pveproxy`. Re-run that on a node whenever its LAN IP or `/etc/hosts` entry
changes. Check a node's SANs with:

```bash
echo | openssl s_client -connect 192.168.68.65:8006 2>/dev/null | openssl x509 -noout -ext subjectAltName
```

If the cluster CA key is ever regenerated, re-run the commands above and copy
the new `/root/pve-root-ca-ku.pem` over `ansible/files/pve-root-ca.pem`.
Regenerating only the node certs (`pvecm updatecerts`) doesn't affect it. Run the
same commands again before the committed cert expires in October 2036.

Terraform still uses `insecure = true`: the bpg provider has no CA option either.

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
