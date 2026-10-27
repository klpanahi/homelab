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
  inventory/hosts.yml      # static inventory: the Proxmox hosts themselves (proxmox_hosts)
  group_vars/
    all/vars.yml           # non-secret shared vars (optional)
    all/vault.yml          # GITIGNORED — vaulted proxmox_token_secret
    tag_nginx.yml          # nginx role variables
    tag_router.yml         # lab router/NAT variables
  roles/router/            # repo-owned role (lab router: forwarding + nftables)
  roles/proxmox_host/      # repo-owned role (hypervisor fixes: NIC offloads)
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

4. **Trust the Proxmox cluster CA.** The inventory verifies the API's TLS cert
   against `files/pve-root-ca.pem` (a strict-mode re-issue of the PVE CA), and finds it through `REQUESTS_CA_BUNDLE`,
   which the repo-root `.envrc` sets. Set up direnv once:
   ```bash
   brew install direnv
   echo 'eval "$(direnv hook zsh)"' >> ~/.zshrc   # then open a new shell
   cd .. && direnv allow
   ```
   Without it, inventory parsing fails with `CERTIFICATE_VERIFY_FAILED`. See
   `docs/cluster.md`, "TLS certificates".

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

- The `proxmox_hosts` play targets the hypervisors, not VMs, over SSH as root.
  It turns off offloads on the Intel I219 NIC (e1000e), which otherwise hangs
  and resets the link under load. Apply it alone with
  `ansible-playbook site.yml --limit proxmox_hosts`.
- The same play keeps the hosts on the free Proxmox repos: the enterprise lines
  in `pve-enterprise.list` and `ceph.list` stay commented out (no subscription,
  so they 401 on `apt update`) and `pve-no-subscription.list` holds the
  `pve-no-subscription` repo. It only edits source lists; upgrades stay manual.
- The `tag_router` play configures the lab subnet gateway (IP forwarding +
  nftables masquerade). It needs the `ansible.posix` collection for the `sysctl`
  module — Homebrew's Ansible already bundles it (and `community.proxmox`), so
  `ansible/collections/` can stay empty. See [`../docs/lab-subnet.md`](../docs/lab-subnet.md).
- `ansible_host` is whatever address the guest agent reports. The router reports
  its LAN IP first, so it needs nothing special — but a VM that lives only on
  `10.10.10.0/24` is reachable from a Mac control machine **only with a local
  route** via `192.168.68.100`. The Deco's static route is not enough: it stalls
  sustained connections from macOS, so SSH sessions hang once output flows.
- Connectivity is over the LAN IP the QEMU guest agent reports. ZeroTier-based
  access can be layered on later as its own play/group.
- The `community.proxmox.proxmox` plugin replaces the deprecated
  `community.general.proxmox`.
- `group_vars/all/vault.yml` (gitignored) is the single source for the token
  secret, read by the inventory via the `unvault` lookup. It also holds any
  future play-level secrets.
