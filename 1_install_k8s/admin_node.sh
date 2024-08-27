## https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo systemctl enable --now kubelet


## https://kubernetes.io/docs/setup/production-environment/container-runtimes/#install-and-configure-prerequisites
# install container runtime
sudo apt-get install -y containerd

# sysctl params required by setup, params persist across reboots
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system

## Verify that net.ipv4.ip_forward is set to 1...
sysctl net.ipv4.ip_forward | grep ip_forward

##Disable swap memory on the vm
sudo sed -e '/swap/ s/^#*/#/' -i /etc/fstab
systemctl mask swap.target
##Created symlink /etc/systemd/system/swap.target → /dev/null.

##Reboot to apply swap settings
sudo reboot