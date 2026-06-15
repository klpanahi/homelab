# HAOS is a special appliance — not cloned from a template.
# pvesm download-url and import content type aren't available in PVE 8.2.
# Manage the full VM lifecycle via qm commands over SSH.
resource "null_resource" "homeassistant" {
  triggers = {
    version              = var.haos_version
    vm_id                = "200"
    ssh_host             = var.proxmox_ssh_host
    ssh_private_key_path = var.proxmox_ssh_private_key_path
    static_ip            = var.haos_static_ip
    mac_address          = var.haos_mac_address
  }

  # self.triggers used so destroy provisioner can reference connection values
  connection {
    type        = "ssh"
    host        = self.triggers["ssh_host"]
    user        = "root"
    private_key = file(pathexpand(self.triggers["ssh_private_key_path"]))
    timeout     = "10s"
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'SSH OK'",

      # Download and decompress (skip if already cached)
      "[ -f /tmp/haos_ova-${var.haos_version}.qcow2 ] && echo 'Image cached' || (wget -q -O /tmp/haos_ova-${var.haos_version}.qcow2.xz 'https://github.com/home-assistant/operating-system/releases/download/${var.haos_version}/haos_ova-${var.haos_version}.qcow2.xz' && xz --decompress /tmp/haos_ova-${var.haos_version}.qcow2.xz)",

      # Create VM if it doesn't exist
      "qm status 200 2>/dev/null && echo 'VM 200 exists' || qm create 200 --name homeassistant --machine q35 --bios ovmf --cores 2 --memory 4096 --net0 virtio=${var.haos_mac_address},bridge=${var.vm_network_bridge} --agent enabled=1",

      # Ensure guest agent is enabled (idempotent for existing VMs)
      "qm set 200 --agent enabled=1",

      # Pin the NIC MAC (idempotent for existing VMs). A running VM applies NIC
      # changes only on reboot, so flag that case before committing the change.
      # A freshly created VM hasn't started yet and boots with the right MAC.
      "rm -f /tmp/ha_reboot_needed",
      "qm config 200 | grep -q 'net0:.*virtio=${var.haos_mac_address}' || { qm status 200 | grep -q running && touch /tmp/ha_reboot_needed; }",
      "qm set 200 --net0 virtio=${var.haos_mac_address},bridge=${var.vm_network_bridge}",

      # Add EFI disk if not already present
      "qm config 200 | grep -q efidisk0 && echo 'EFI disk exists' || qm set 200 --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0",

      # Import HAOS disk and attach if not already done
      "qm config 200 | grep -q virtio0 && echo 'Disk already attached' || (qm importdisk 200 /tmp/haos_ova-${var.haos_version}.qcow2 local-lvm && qm set 200 --virtio0 \"$(qm config 200 | grep '^unused0' | awk '{print $2}'),discard=on\")",

      # Boot order
      "qm set 200 --boot order=virtio0",

      # Start if not already running
      "qm status 200 | grep -q running && echo 'Already running' || qm start 200",

      # Reboot to apply a pending MAC change on an already-running VM
      "[ -f /tmp/ha_reboot_needed ] && { echo 'Rebooting VM 200 to apply new MAC...'; qm reboot 200; } || echo 'No reboot needed'",
      "rm -f /tmp/ha_reboot_needed",

      # Clean up
      "rm -f /tmp/haos_ova-${var.haos_version}.qcow2"
    ]
  }

  provisioner "remote-exec" {
    when = destroy
    inline = [
      "qm stop 200 2>/dev/null || true",
      "qm destroy 200 --purge 1 2>/dev/null || true"
    ]
  }
}

# Configures a static IP inside HAOS via the guest agent CLI.
# Only runs when haos_static_ip is set; re-runs on IP/gateway/nameserver changes.
resource "null_resource" "homeassistant_network" {
  count = var.haos_static_ip != "" ? 1 : 0

  triggers = {
    static_ip            = var.haos_static_ip
    gateway              = var.haos_gateway
    nameserver           = var.haos_nameserver
    iface                = var.haos_network_iface
    ssh_host             = var.proxmox_ssh_host
    ssh_private_key_path = var.proxmox_ssh_private_key_path
  }

  depends_on = [null_resource.homeassistant]

  connection {
    type        = "ssh"
    host        = self.triggers["ssh_host"]
    user        = "root"
    private_key = file(pathexpand(self.triggers["ssh_private_key_path"]))
    timeout     = "10s"
  }

  provisioner "remote-exec" {
    inline = [
      # Wait up to 3 minutes for the QEMU guest agent to become available
      "echo 'Waiting for HAOS guest agent...'",
      "timeout 180 bash -c 'until qm agent 200 ping 2>/dev/null; do sleep 5; done' || { echo 'Guest agent timed out — ensure QEMU agent is running in HAOS'; exit 1; }",

      # Apply static IP via the HAOS network CLI
      "echo 'Configuring static IP ${var.haos_static_ip} on ${var.haos_network_iface}'",
      "qm guest exec 200 --timeout 30 -- ha network update ${var.haos_network_iface} --ipv4-method static --ipv4-address ${var.haos_static_ip} --ipv4-gateway ${var.haos_gateway} --ipv4-nameserver ${var.haos_nameserver}",
    ]
  }
}
