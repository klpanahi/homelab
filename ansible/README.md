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
    tag_nginx.yml          # nginx role variables
  site.yml                 # top-level playbook
```

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

3. **Embed the Proxmox token secret in the inventory.** Inventory plugins are
   evaluated *before* `group_vars`, so the secret can't come from a vaulted
   group var — it's stored as an inline `!vault` block in `inventory/proxmox.yml`.
   Generate the block (the secret is the part after `=` in `terraform.tfvars`'
   `proxmox_api_token`; type it at the prompt, then Ctrl-D so it never lands in
   shell history):
   ```bash
   ansible-vault encrypt_string --stdin-name token_secret
   ```
   Paste the output over the existing `token_secret: !vault |` block. Also make
   sure `user:` and `token_id:` in the inventory match your token's `user@realm`
   and token id (currently `root@pam` / `terraform`).

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

- Connectivity is over the LAN IP the QEMU guest agent reports. ZeroTier-based
  access can be layered on later as its own play/group.
- The `community.proxmox.proxmox` plugin replaces the deprecated
  `community.general.proxmox`.
- `group_vars/all/vault.yml` is **not** required (the token secret is inline in
  the inventory). It stays gitignored and is available if you later need
  play-level secrets.
