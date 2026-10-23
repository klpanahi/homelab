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

## How it was formed (runbook)

Run these as root. A joining node must have no guests, so homelab1's VMs are
moved aside during the join.

1. Back up `/etc/pve` on both nodes: `tar czf /root/pve-etc-$(date +%F).tgz /etc/pve`.
2. Bring both nodes to the same PVE release (`apt update && apt full-upgrade`).
   They must match before joining.
3. Fix `/etc/hosts` on each node so its own name maps to its LAN address,
   e.g. `192.168.68.65 homelab2.home.arpa homelab2`. Add a line for the peer,
   then run `systemctl restart pve-cluster pveproxy`.
4. On homelab2: `pvecm create homelab --link0 192.168.68.65`.
5. On homelab1:
   - Stop the guests: `qm shutdown 300; qm shutdown 301`.
   - Move `/etc/pve/qemu-server/30{0,1}.conf` and any `/etc/pve/firewall/30*.fw`
     to `/root/guest-conf/`.
   - Make sure homelab1's root key is in homelab2's root `authorized_keys`.
6. On homelab1: `pvecm add 192.168.68.65 --link0 192.168.68.75 --use_ssh`.
7. Copy the saved configs into `/etc/pve/nodes/homelab1/qemu-server/` (and the
   firewall files into `/etc/pve/firewall/`), then `qm start 300; qm start 301`.
8. Verify:
   - `pvecm status` shows Quorate with 2 nodes.
   - `/api2/json/nodes/homelab1/qemu`, queried through homelab2's API with the
     terraform token, lists 300 and 301.

The join replaces homelab1's user and token database with the cluster's.
homelab1's old standalone token no longer exists, so remove
`proxmox_homelab1_api_token` from `terraform.tfvars` and
`proxmox_token_secret_homelab1` from the Ansible vault.
