# OpenBao

The homelab's credential manager. Secrets are edited in its web UI, and Terraform
and Ansible fetch them with the operator's login. Why OpenBao, and the options
considered: `docs/decisions/0002-credential-manager.md` in the workspace.

| | |
|---|---|
| Guest | CT 302 `openbao` on homelab1, `10.10.10.60` (`terraform/openbao.tf`, `ansible/roles/openbao`) |
| URL | <https://openbao.panahi-systems.com>, web UI at `/ui` |
| Reachable from | Macs with the lab route (`docs/lab-subnet.md`) at home and over WireGuard. The name only resolves through the router's DNS. iPhones stall on lab addresses, so the UI doesn't work there |
| Certificate | Let's Encrypt over DNS-01 (`roles/letsencrypt`), renewed by certbot |

## Daily use

Put the address in your shell profile, then log in. A login lasts 8 hours (24 at
most) and is stored in `~/.vault-token`.

```bash
export BAO_ADDR=https://openbao.panahi-systems.com
bao login -method=userpass username=<login>
```

Then run things as before, except Terraform goes through a wrapper that fetches
the Proxmox token:

```bash
scripts/tf plan
ansible-playbook site.yml
```

If OpenBao is sealed or the login has expired, both stop with an error. For
Ansible that relies on `any_unparsed_is_failed` in `ansible.cfg`: without it a
failed lookup empties the inventory, skips every play and exits 0.

**Don't run secret-reading commands where an agent can see the output.** `bao kv
get` prints values. A decrypted vault reached a chat transcript this way once
(board card #25).

## Where each secret lives

All under the `secret/` KV v2 store. The `vault_` variables in
`ansible/group_vars/all/secrets.yml` keep their old names, so roles don't change.

| Path | Fields | Used by |
|---|---|---|
| `proxmox` | `token_secret` | Inventory, `scripts/tf` |
| `home-assistant` | `token` | `backup` role |
| `backup` | `ssh_private_key` | `backup` role |
| `immich-db` | `personal`, `austin` | `immich` role (`group_vars/tag_immich.yml`) |
| `immich-restic` | `password` | `immich` role |
| `restic-server` | `password` | `restic_server`, `immich` roles |
| `cloudflare` | `dns_token`, `tunnel_token` | `letsencrypt`, `cloudflared` roles |
| `pihole` | `password` | `pihole` role |

To change a secret, edit it in the UI and re-run the play that uses it. KV v2
keeps old versions, so a mistake can be undone. It also means a replaced value
stays readable until its version is destroyed, so revoke rotated credentials at
their source.

To add one, create it in the UI, then add a line to `secrets.yml`.

## After a reboot

OpenBao starts sealed and unsealing is manual. Nothing breaks while it's sealed,
because guests get their secrets at deploy time. It only blocks the next Terraform
or Ansible run.

```bash
bao operator unseal   # prompts for the unseal key
```

The unseal key isn't stored on the guest on purpose. It would land in the nightly
vzdump next to the data it protects.

Restarting the service also seals it. That includes a config change from the role
and any package upgrade followed by a restart. Certificate renewal doesn't: its
hook sends SIGHUP.

## Upgrading

Set `openbao_version` and `openbao_deb_sha256` in `roles/openbao/defaults/main.yml`
(from the release's `checksums.txt`), run `ansible-playbook site.yml --limit
tag_openbao`, restart the service on the guest, and unseal.

## Recovery

The way back must not depend on OpenBao. Keep these outside the homelab, in a
password manager or on paper:

- the unseal key
- your OpenBao login
- the Proxmox root password
- the Immich restic password: without it the Immich backups can't be read, and every
  backup is in the same building

**OpenBao guest lost or broken.** In the Proxmox UI, restore CT 302 from the nightly
vzdump on the USB disk (`docs/backups.md`), start it, and unseal. The store on disk
is encrypted, so the backup is safe without the key. Anything changed since the last
backup is lost.

**homelab2 down.** OpenBao's lab address routes through the router VM on homelab2,
so it's unreachable until the router is back, even though homelab1 is fine. Restore
the router from vzdump first. The cluster also loses quorum (`docs/cluster.md`).

**Lost login, unseal key still known.** Create a temporary root token with `bao
operator generate-root`, reset the password under `auth/userpass/users/<login>`, then
revoke the token.

**Lost unseal key.** Nothing in the store can be read again. Wipe `/opt/openbao/data`,
run `scripts/openbao-init.sh`, and re-enter every secret, rotating each one at its
source. The Cloudflare DNS token is needed before the role can run on a rebuilt
guest, because the role fetches it from OpenBao.

## First-time setup

Terraform creates the guest and `ansible-playbook site.yml --limit tag_router,tag_openbao`
configures it. Then run `scripts/openbao-init.sh` in your own terminal, with no agent
watching: it shows the unseal key once, creates the store, policy and login, revokes
the root token, and logs you in.
