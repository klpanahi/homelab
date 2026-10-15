# Homelab

Infrastructure-as-code for a two-node Proxmox homelab. See `agent.md` for full architecture decisions.

---

## Prerequisites

### 1. Proxmox VE

- Proxmox VE installed bare-metal on each machine
- Nodes accessible on the local network (or via ZeroTier for remote work)

### 2. Terraform

```bash
brew install terraform   # macOS
terraform -version       # must be >= 1.6
```

### 3. Proxmox API Token

Run the following on each Proxmox node (via SSH or the web UI Shell tab):

```bash
# Create a dedicated Terraform user
pveum user add terraform@pve

# Create an API token (secret is shown once — save it)
pveum user token add terraform@pve terraform --privsep=0

# Grant admin rights
pveum aclmod / --token 'terraform@pve!terraform' --role Administrator
```

### 4. SSH Access to Proxmox Root

SSH access to root is required to download the Home Assistant OS image onto the Proxmox node. The bpg/proxmox provider (v0.78+) dropped xz decompression support, and HAOS only ships `.xz` images, so Terraform SSHes in and calls `pvesm download-url` directly instead.

Authorize your key on the Proxmox host:

```bash
ssh-copy-id root@192.168.68.65
```

Ensure your SSH agent is running with the key loaded before running `terraform apply`:

```bash
eval $(ssh-agent)
ssh-add ~/.ssh/id_ed25519   # adjust path as needed
ssh root@192.168.68.65      # verify it works before applying
```

---

## Getting Started

### 1. Provision VMs (Terraform)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Fill in proxmox_api_token and haos_version in terraform.tfvars

terraform init
terraform plan
terraform apply   # requires SSH agent loaded (see Prerequisite 4)
```

### 2. Configure VMs (Ansible)

VMs are discovered through a Proxmox dynamic inventory and grouped by their
Proxmox tags — `terraform apply` tags the nginx VM `nginx`, which Ansible
configures with the `geerlingguy.nginx` role.

```bash
cd ansible
ansible-galaxy install -r requirements.yml   # community.proxmox + geerlingguy.nginx

# Vault password file, then the vaulted Proxmox token secret (the inventory
# reads it via an unvault lookup — see ansible/README.md)
printf '%s' 'your-vault-password' > .vault_pass && chmod 600 .vault_pass
ansible-vault create group_vars/all/vault.yml   # add proxmox_token_secret

ansible-inventory --graph    # nginx VM should appear under tag_nginx
ansible-playbook site.yml
```

See [`ansible/README.md`](ansible/README.md) for details.

### 3. (Optional) Reach the lab subnet

Lab VMs live on `10.10.10.0/24`, routed by the `router` VM at `192.168.68.100`.
The Deco carries a static route for it, which is enough for Linux and Windows
machines. **A Mac needs its own route** — the Deco's route stalls real transfers for
macOS and iOS:

```bash
sudo route -n add -net 10.10.10.0/24 192.168.68.100
```

See [`docs/lab-subnet.md`](docs/lab-subnet.md) for why, how to persist the route, the
design and bring-up, and the traps involved in moving an existing VM onto it.

### 4. (Optional) Internal DNS

The router VM also runs dnsmasq for the `home.arpa` zone. Add names in
[`ansible/dns/records.yml`](ansible/dns/records.yml), apply with
`ansible-playbook site.yml --limit tag_router`, then set the Deco's DHCP DNS to
`192.168.68.100` so every device on the Wi-Fi resolves them. See
[`docs/internal-dns.md`](docs/internal-dns.md).

---

## IP allocation

Lab VMs are addressed in git: each address below is the `*_static_ip` default in
[`terraform/variables.tf`](terraform/variables.tf), gateway `10.10.10.1`. Nothing on
`10.10.10.0/24` needs a Deco reservation — the Deco hands out no addresses there — so
the router's `192.168.68.100` is the only reservation the lab needs. Adding a VM
means adding a row here, never a trip to the Deco app. The hosts below the lab rows
predate it and keep their existing reservations.

| Host | VM | Node | Address | How it's held |
|---|---|---|---|---|
| `router` | 204 | homelab2 | `10.10.10.1` + `192.168.68.100` | Static; LAN side also Deco-reserved (MAC `BC:24:11:00:02:04`) |
| *(reserved)* | | | `10.10.10.2`–`.9` | Lab infrastructure (e.g. a resolver) |
| `nginx-cloudflared` | 201 | homelab2 | `10.10.10.10` | Static (`nginx_static_ip`) |
| `docker` | 202 | homelab2 | `10.10.10.20` | Static (`docker_static_ip`) |
| `backup` | 300 | homelab1 | `10.10.10.30` | Static (`backup_static_ip`) |
| `nginx-internal` | 203 | homelab2 | `10.10.10.40` | Static (`nginx_internal_static_ip`); LAN clients reach it through the router's port 80/443 forward on `.100` |
| *(free)* | | | `10.10.10.41`–`.250` | Next VM: take the next free `.x0`, add a row here |
| `homeassistant` | 200 | homelab2 | `192.168.68.60` | LAN, Deco reservation (MAC `BC:24:11:00:02:00`) — needs mDNS/SSDP on the LAN |
| `homelab2` | — | — | `192.168.68.65` | LAN, Deco reservation |
| `homelab1` | — | — | `192.168.68.75` | LAN, Deco reservation |

Moving the running VMs onto these addresses is a one-window cutover —
see [the cutover runbook](docs/lab-subnet.md#cutover-the-party-time-chain).

---

## Repository Structure

```
├── agent.md              # Architecture decisions and conventions
├── docs/                 # Codemaps + design notes (e.g. lab-subnet.md)
├── terraform/            # VM provisioning (Proxmox)
├── ansible/              # VM configuration (Docker, UFW, ZeroTier, etc.)
└── compose/              # Docker Compose stacks per service
```
