<!-- Generated: 2026-06-23 | Files scanned: 7 | Token estimate: ~520 -->

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
    tag_nginx.yml          geerlingguy.nginx vhost config
  site.yml                 top-level playbook
  .vault_pass              GITIGNORED — vault password file
  roles/ collections/      GITIGNORED — galaxy installs
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
| `tag_ansible` | nginx | Proxmox tag `ansible` |
| `proxmox_all_qemu` / `_all_running` | homeassistant, nginx | VM type/status |
| `proxmox_homelab2_qemu` | homeassistant, nginx | per-node |
| `proxmox_nodes` | homelab2 | node |

## Playbook

```
site.yml
  hosts: tag_nginx  (become: true)
    role geerlingguy.nginx
      ← group_vars/tag_nginx.yml: nginx_vhosts (port 80, root /var/www/html),
        nginx_remove_default_vhost: true
```

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
