---
name: fix-homelab-mdns
description: Diagnoses and repairs mDNS/avahi name resolution failures across the Proxmox homelab VMs (docker.local, nginx-internal.local, nginx-cloudflared.local). Use when a .local hostname fails to resolve or resolves to the wrong IP, when nginx reports "host not found in upstream" or refuses to start, when a homelab VM is unreachable by name but reachable by IP, when the browser shows ERR_NAME_NOT_RESOLVED for a .local host, or when the user says mDNS/avahi/Bonjour is flaky, broken, or intermittent. Also use when a deploy or smoke test fails because docker.local or nginx-internal.local could not be resolved.
---

# Fix homelab mDNS

A **recurring, well-characterized fault class** in this homelab. All four failure modes
below have been observed, and all four occurred within a single day. Work the triage order
— do not guess.

## When to use

- A `.local` name does not resolve, or resolves to a stale/wrong IP.
- nginx logs `host not found in upstream`, or `nginx -t` fails, or nginx will not start.
- A VM answers on its IP but not on its name (or vice versa).
- `ERR_NAME_NOT_RESOLVED` in the browser for a `.local` host.
- The user reports mDNS "flaky", "works sometimes", or "only some hosts".

## Environment

Proxmox homelab, Ubuntu VMs. Ansible installs **`avahi-daemon` and `libnss-mdns` on every
VM** via the `tag_ansible` play in `~/Documents/Workspace/homelab/ansible/site.yml`.
Control machine is a Mac. DHCP is served by the router at `192.168.68.1`.

| Host | IP |
|---|---|
| nginx-cloudflared.local | 192.168.68.77 |
| docker.local | 192.168.68.78 |
| nginx-internal.local | 192.168.68.85 |

### Why this matters more than normal DNS flakiness

**nginx on both nginx VMs references the backend as `docker.local` in its upstream block.**
nginx resolves upstream hostnames **once, at config-parse time**, and **refuses to start if
resolution fails.** So an mDNS blip does not merely degrade the site — it can take nginx
**permanently down until a human restarts it**, long after mDNS itself recovered.

Always finish with the [post-fix nginx step](#post-fix-nginx-step--mandatory).

## Quick triage

Run in this order. Each step tells you which mode to jump to.

1. **Determine scope.** Which `.local` names fail, and do they fail *from the Mac*, *from a
   VM*, or *both*? **Compare several names at once** — if only some fail, that points
   straight at **Mode D**.
   ```bash
   dscacheutil -q host -a name docker.local
   dscacheutil -q host -a name nginx-internal.local
   dscacheutil -q host -a name nginx-cloudflared.local
   ```
   macOS caches aggressively — **run each a few times** before believing the result.

2. **Is the host up at its IP at all?**
   ```bash
   ping -c 2 192.168.68.78
   ssh ubuntu@192.168.68.78 true
   ```
   Unreachable by IP too → **Mode C**.

3. **Check `/etc/hosts` on the *consumer* of the name** (usually an nginx VM) → **Mode A**.

4. **Check avahi logs on the *provider* of the name** → **Mode D**.

5. **Check systemd-networkd / DHCP on the provider** → **Mode B / Mode C**.

## Mode A — Stale hardcoded `/etc/hosts` override

**Symptom.** The name resolves, but to an **OLD/wrong IP**, and restarting avahi changes
nothing at all. The nginx error log shows
`connect() failed (113: No route to host)` against the wrong IP.

**Detect.**
```bash
ssh ubuntu@<vm> 'grep -n "\.local" /etc/hosts; grep ^hosts /etc/nsswitch.conf'
```

**Cause.** A line such as `192.168.68.89 docker.local` in `/etc/hosts`.
`/etc/nsswitch.conf` lists `files` **before** `mdns4_minimal`, so `/etc/hosts` silently and
permanently wins over mDNS. No amount of avahi restarting will help.

**Fix.** Back up `/etc/hosts`, then remove the stale line. It is **not Ansible-managed**, so
nothing will reintroduce it.

## Mode B — DHCP lease moved

**Symptom.** The host genuinely has a different IP than expected or cached.

**Detect.**
```bash
ssh ubuntu@<vm> 'ip -4 -o addr show scope global'
ssh ubuntu@<vm> 'sudo journalctl -u systemd-networkd | grep DHCPv4'
```

**Cause.** No DHCP reservation. Real example: the docker VM moved
`192.168.68.89` → `192.168.68.78` on 2026-07-27.

**Fix.** **Nothing to fix on the VM** — the new IP is legitimate. But anything **caching the
old IP** must be corrected or reloaded: a Mode A `/etc/hosts` entry, and any **already-running
nginx** that pinned the old address. Durable prevention is a DHCP reservation on the router,
or a static IP — see [Durable improvements](#durable-improvements).

## Mode C — Interface lost its IPv4 address entirely

**Symptom.** Host unreachable **by name AND by its expected IP**. From another machine,
`getent hosts docker.local` may return **only an IPv6 link-local** address. Confusingly,
**Docker containers on the box keep running** the whole time.

**Detect.**
```bash
ssh ubuntu@<vm> 'ip -4 -o addr show; networkctl status enp6s18'
ssh ubuntu@<vm> 'sudo journalctl -u systemd-networkd -n 20'
```
Look for `State: degraded (failed)`, **no global IPv4**, only an `fe80::` link-local. In the
journal, look for `Could not set NDisc address: Connection timed out` followed by `Failed`.

Real example: the docker VM sat with **no IPv4 for 17+ hours** after this.

**Fix.**
```bash
ssh ubuntu@<vm> 'sudo networkctl reconfigure enp6s18'
```
Then confirm `ip -4 -o addr show enp6s18` shows a **global** address and
`networkctl status enp6s18` shows `routable (configured)`.

> **Getting in when there is no IPv4:** you may still reach the box **over IPv6 link-local
> via its `.local` name** even with no IPv4 address — that is exactly how this was
> originally diagnosed. In this situation **prefer connecting by name**, not by IP.

## Mode D — avahi hostname conflict (renamed itself with a `-2` suffix)

**Symptom.** **The most deceptive one.** The name resolves **intermittently** — sometimes
fine, sometimes `ERR_NAME_NOT_RESOLVED`. Often **several hosts fail while others succeed**.

**Detect.**
```bash
ssh ubuntu@<vm> 'sudo journalctl -u avahi-daemon -n 20 --no-pager | grep -i "host name\|conflict"'
```
Look for `Host name conflict, retrying with <name>-2` and
`Server startup complete. Host name is <name>-2.local.`

**Cause.** After a network flap, avahi can see a **delayed echo of its own address probe**
and wrongly conclude another device owns the name, so it backs off to a `-2` suffix. **The
real name then has no advertiser at all.**

Real example: **both** nginx VMs did this simultaneously, becoming
`nginx-cloudflared-2.local` and `nginx-internal-2.local`.

**Fix.**
```bash
ssh ubuntu@<vm> 'sudo systemctl restart avahi-daemon'
```
Confirm the log now shows `Host name is <name>.local.` with **no new conflict line**.

> If a conflict recurs **immediately**, a **real second device genuinely owns that name.**
> Investigate that — **do not restart avahi in a loop.**

## Post-fix nginx step — MANDATORY

**Fixing DNS is not enough.** nginx pins upstream IPs at config load, so it is still holding
the old (or failed) resolution. Run this on **each** nginx VM:

```bash
ssh ubuntu@<nginx-vm> 'getent hosts docker.local; sudo nginx -t && sudo systemctl reload nginx; systemctl is-active nginx'
```

- `getent hosts docker.local` must show the **correct current IP** before you reload.
- If nginx was in a **`failed`** state, it must be **started**, not merely reloaded:
  ```bash
  ssh ubuntu@<nginx-vm> 'sudo systemctl start nginx; systemctl is-active nginx'
  ```

## Verification

Do not report success until all of these pass.

```bash
# From the Mac — names resolve to the right IPs (run a few times; macOS caches)
dscacheutil -q host -a name docker.local
dscacheutil -q host -a name nginx-internal.local
dscacheutil -q host -a name nginx-cloudflared.local

# nginx actually running on both nginx VMs
ssh ubuntu@nginx-internal.local 'systemctl is-active nginx'
ssh ubuntu@nginx-cloudflared.local 'systemctl is-active nginx'

# The real URLs
curl -s -o /dev/null -w '%{http_code}\n' http://nginx-internal.local/
curl -s -o /dev/null -w '%{http_code}\n' https://party-time.panahi-systems.com/
```

Re-testing the **actual URLs** is required — resolution being fixed does not prove nginx
came back.

## Durable improvements

**Neither of these is currently in place.** Present them as recommendations; do not
implement them unless asked.

- **DHCP reservations (or static IPs) for all three VMs** on the router at `192.168.68.1`,
  so names and IPs stop moving. This eliminates Mode B and most Mode A recurrences.
- **An nginx `resolver` directive with a variable in `proxy_pass`**, so nginx **re-resolves
  upstreams at runtime** instead of pinning them at startup. This is the fix that stops an
  mDNS blip from taking nginx down entirely — nginx would degrade instead of refusing to
  boot.
