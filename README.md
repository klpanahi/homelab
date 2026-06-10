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

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Fill in proxmox_api_token and haos_version in terraform.tfvars

terraform init
terraform plan
terraform apply   # requires SSH agent loaded (see Prerequisite 4)
```

---

## Repository Structure

```
├── agent.md              # Architecture decisions and conventions
├── terraform/            # VM provisioning (Proxmox)
├── ansible/              # VM configuration (Docker, UFW, ZeroTier, etc.)
└── compose/              # Docker Compose stacks per service
```
