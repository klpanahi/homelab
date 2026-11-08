# Gitea

The homelab's private git server: repositories on hardware the owner controls
instead of GitHub. Not exposed to the internet.

| | |
|---|---|
| Guest | CT 303 `gitea` on homelab1, `10.10.10.70` (`terraform/gitea.tf`, `ansible/roles/gitea`) |
| URL | <https://git.panahi-systems.com> |
| Git over SSH | `git@git.panahi-systems.com:<owner>/<repo>.git`, port 22 |
| Reachable from | Macs with the lab route (`docs/lab-subnet.md`) at home and over WireGuard. The name only resolves through the router's DNS. iPhones stall on lab addresses, so the site doesn't work there |
| Certificate | Let's Encrypt over DNS-01 (`roles/letsencrypt`), renewed by certbot |
| Data | All on the guest under `/var/lib/gitea`: repositories, SQLite database, attachments |
| Backup | The nightly vzdump job covers the whole guest (`docs/backups.md`). No offsite copy yet |

Why the name points straight at the guest instead of the router's front door: the
front door only forwards 80/443, so a name on the router couldn't carry git over
SSH. A direct name gives HTTPS and SSH the same address, the same trade-off as
OpenBao.

## Policy

Registration is off and every page needs a login (`DISABLE_REGISTRATION`,
`REQUIRE_SIGNIN_VIEW`), so even a repository marked public can't be cloned
anonymously. New repositories default to private. Actions, the OAuth2 provider,
OpenID, LFS and outgoing mail are off. These are all in
`ansible/roles/gitea/templates/app.ini.j2`; changes made through the site's admin
pages can't override them.

## Daily use

Add your SSH public key once under Settings → SSH / GPG Keys. A key can belong to
only one Gitea account. Then:

```bash
git clone git@git.panahi-systems.com:<owner>/<repo>.git
```

HTTPS works too. Use an access token (Settings → Applications) as the password.

New account (there's no sign-up page), in your own terminal because it prints a
one-time password:

```bash
ssh -t root@gitea.home.arpa 'sudo -u git gitea admin user create --config /etc/gitea/app.ini --username <name> --email <email> --random-password --must-change-password'
```

Add `--admin` for an administrator. Lost password: same shape, with
`admin user change-password --username <name> --password <new>`.

## Configuration and secrets

`/etc/gitea/app.ini` is written by Ansible and is read-only to Gitea, so edit the
template and run:

```bash
ansible-playbook site.yml --limit tag_gitea
```

`secret_key`, `internal_token` and `jwt_secret` are in `secret/gitea` in OpenBao
(`docs/openbao.md`), and the play fetches them at deploy time, so Gitea keeps
running if OpenBao is sealed. Don't rotate `secret_key` casually: it encrypts stored
two-factor secrets and similar data, which become unreadable if it changes.
Gitea refuses to start if `jwt_secret` is missing, even with OAuth2 off.

## Upgrading

1. Read the release notes for anything breaking across the versions you're skipping.
2. Take a backup: `vzdump 303 --storage backup-hdd-nfs --mode snapshot --compress zstd`
   on homelab1. Gitea migrates its database on start, and the only way back is this.
3. Set `gitea_version` and `gitea_binary_sha256` in `roles/gitea/defaults/main.yml`,
   from the release's `gitea-<version>-linux-amd64.sha256`.
4. Run `ansible-playbook site.yml --limit tag_gitea`. The service restarts itself.

The binary stays at the fixed path `/usr/local/bin/gitea` rather than a versioned
path behind a symlink. Gitea writes its resolved path into `authorized_keys` and
every repository's hooks, so a versioned path would break them after an upgrade.

## Restore

In the Proxmox UI, restore CT 303 from the newest vzdump on the USB disk
(`docs/backups.md`) and start it. The archive has everything, including `app.ini`
and the certificate. Pushes since that backup are lost, but any clone on your Mac
that has them can push them back.

Rebuilt from scratch instead (`terraform apply`, then the play, no backup): every
repository, account and SSH key is gone. `secret/gitea` in OpenBao still works.

The Terraform resource ignores changes to `initialization` and `operating_system`
on purpose. Without that, a new template would make the provider replace the
container and destroy the repositories.

## If it's down

```bash
ssh root@gitea.home.arpa 'systemctl status gitea; journalctl -u gitea -n 50 --no-pager'
```

The lab address routes through the router VM on homelab2, so if homelab2 is down
Gitea is unreachable even though homelab1 is fine (`docs/openbao.md` describes the
same case). A certificate renewal restarts the service briefly (Gitea only reads the
certificate at startup), at most about every 60 days.
