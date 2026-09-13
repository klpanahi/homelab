# Ansible

Configures VMs after Terraform provisions them. Hosts are discovered through a
**Proxmox dynamic inventory** and grouped by their Proxmox **tags** — no static
inventory or IP files. The nginx VM (tagged `nginx` in `terraform/nginx.tf`)
lands in the `tag_nginx` group and is configured with the open-source
[`geerlingguy.nginx`](https://github.com/geerlingguy/ansible-role-nginx) role.

## Layout

```
ansible/
  ansible.cfg              # inventory, vault, SSH defaults
  requirements.yml         # community.proxmox collection + geerlingguy.nginx role
  inventory/proxmox.yml    # dynamic inventory (tags -> groups, agent IP -> ansible_host)
  group_vars/
    all/vars.yml           # non-secret shared vars (optional)
    all/vault.yml          # GITIGNORED — vaulted proxmox_token_secret
    tag_nginx.yml          # nginx role variables
    tag_router.yml         # lab router/NAT variables
  roles/router/            # repo-owned role (lab router: forwarding + nftables)
  site.yml                 # top-level playbook
```

`ansible/roles/` is where galaxy installs land and is gitignored, *except* for
roles written in this repo — `roles/router/` is re-included in `.gitignore`.

## One-time setup

1. **Install collection + role:**
   ```bash
   cd ansible
   ansible-galaxy install -r requirements.yml
   ```

2. **Create the vault password file** (`.vault_pass`, gitignored):
   ```bash
   printf '%s' 'your-vault-password' > .vault_pass
   chmod 600 .vault_pass
   ```

3. **Create the vaulted secrets file** with the Proxmox token secret (the part
   after `=` in `terraform.tfvars`' `proxmox_api_token`). See
   `group_vars/all/vault.yml.example`:
   ```bash
   ansible-vault create group_vars/all/vault.yml
   # add:  proxmox_token_secret: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
   ```
   The inventory reads this at parse time via an `ansible.builtin.unvault`
   lookup (inventory plugins load *before* `group_vars`, so a plain
   `{{ proxmox_token_secret }}` group var would be undefined — the lookup
   decrypts the file directly instead). Also make sure `user:` and `token_id:`
   in `inventory/proxmox.yml` match your token's `user@realm` and token id
   (currently `root@pam` / `terraform`).

## Usage

```bash
# Verify discovery + grouping (nginx VM should appear under tag_nginx with a LAN IP)
ansible-inventory --graph

# Connectivity check
ansible tag_nginx -m ping

# Configure nginx
ansible-playbook site.yml
```

## Notes

- The `tag_router` play configures the lab subnet gateway (IP forwarding +
  nftables masquerade). It needs the `ansible.posix` collection from
  `requirements.yml` for the `sysctl` module. See [`../docs/lab-subnet.md`](../docs/lab-subnet.md).
- `ansible_host` is whatever address the guest agent reports, so once a VM moves
  to `10.10.10.0/24` the control machine needs a route to that subnet via the
  router VM (`192.168.68.50`) or every task fails as unreachable.
- Connectivity is over the LAN IP the QEMU guest agent reports. ZeroTier-based
  access can be layered on later as its own play/group.
- The `community.proxmox.proxmox` plugin replaces the deprecated
  `community.general.proxmox`.
- `group_vars/all/vault.yml` (gitignored) is the single source for the token
  secret, read by the inventory via the `unvault` lookup. It also holds any
  future play-level secrets.
