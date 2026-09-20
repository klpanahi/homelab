<!-- Generated: 2026-09-13 | Files scanned: 12 | Token estimate: ~640 -->

# Ansible Configuration

Configures VMs after Terraform provisions them. No static inventory — hosts are
discovered from the Proxmox API and grouped by their Proxmox **tags**.

## Files

```
ansible/
  ansible.cfg              inventory path, vault, SSH defaults (remote_user=ubuntu)
  requirements.yml         community.proxmox collection + geerlingguy.nginx role
  inventory/proxmox.yml    community.proxmox.proxmox dynamic inventory
  group_vars/
    all/vars.yml           non-secret shared vars
    all/vault.yml          GITIGNORED — vaulted proxmox_token_secret
    all/vault.yml.example  template
    tag_nginx.yml          geerlingguy.nginx baseline config
    tag_router.yml         lab router: lab/LAN subnets, NAT-to-LAN toggle
  roles/router/            REPO-OWNED role — IP forwarding + nftables ruleset
  site.yml                 top-level playbook
  .vault_pass              GITIGNORED — vault password file
  collections/             GITIGNORED — galaxy installs
  roles/*                  GITIGNORED except re-included repo-owned roles
```

## Inventory flow (inventory/proxmox.yml)

```
Proxmox API (root@pam!terraform token) ──► VMs + facts (want_facts: true)
  token_secret: unvault lookup on group_vars/all/vault.yml at parse time
  keyed_groups: proxmox_tags_parsed → tag_<name>   (nginx → tag_nginx)
  compose: ansible_host = first non-loopback IPv4 from proxmox_agent_interfaces
```

Auth note: inventory plugins load BEFORE group_vars, so the token secret cannot
be a plain `{{ proxmox_token_secret }}` group var — it's pulled via
`lookup('ansible.builtin.unvault', 'group_vars/all/vault.yml')`. `user` +
`token_id` must match the Proxmox token (`root@pam` / `terraform`).

## Groups produced

| Group | Members | Source |
|---|---|---|
| `tag_nginx` | nginx | Proxmox tag `nginx` |
| `tag_router` | router | Proxmox tag `router` |
| `tag_ansible` | all VMs | Proxmox tag `ansible` |
| `proxmox_all_qemu` / `_all_running` | homeassistant, nginx | VM type/status |
| `proxmox_homelab2_qemu` | homeassistant, nginx | per-node |
| `proxmox_nodes` | homelab2 | node |

## Playbook

```
site.yml
  hosts: tag_ansible:!tag_router   avahi-daemon + libnss-mdns (mDNS .local names)
      router excluded: avahi would publish its lab address to LAN clients
  hosts: tag_router                role router  (repo-owned)
      ← group_vars/tag_router.yml: router_lab_subnet, router_lan_subnet,
        router_masquerade_to_lan
      tasks: nftables pkg, ufw removed, ip_forward + send_redirects sysctls,
        /etc/nftables.conf from template (validated with `nft --check`)
  hosts: tag_nginx / tag_nginx_internal   role geerlingguy.nginx (install +
      baseline only; app vhosts live in the app's own repo)
  hosts: tag_cloudflared           role cloudflared (untracked, local)
  hosts: tag_docker                role geerlingguy.docker
```

## Run

```
ansible-galaxy install -r requirements.yml
ansible-inventory --graph        # nginx under tag_nginx, ansible_host = LAN IP
ansible tag_nginx -m ping
ansible-playbook site.yml
```

## Notes

- Connectivity over the IP the guest agent reports; ZeroTier can layer on later.
  A VM on `10.10.10.0/24` is only reachable if the control machine has a route via
  the router VM (`192.168.68.100`) — see [`../lab-subnet.md`](../lab-subnet.md).
- `community.proxmox.proxmox` replaces the deprecated `community.general.proxmox`.
