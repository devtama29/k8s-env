#!/usr/bin/env bash
# ==============================================================================
# Script 01: Persiapan Node Ubuntu (Master & Worker) - Kubernetes v1.37
# Mencakup: Disk LVM Expansion, OS Hardening, containerd, & Kubeadm v1.37
# ==============================================================================

set -euo pipefail

# --- KONFIGURASI IP & HOSTNAME (Sesuaikan dengan IP VM Anda) ---
MASTER_IP="192.168.56.10"
MASTER_HOSTNAME="ubuntu"
WORKER_IP="192.168.56.11"
WORKER_HOSTNAME="kubeworker"
K8S_VERSION="v1.37"

echo "=== [1/6] Mematikan Swap & Menghapus /swap.img (Fix DiskPressure) ==="
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
if [ -f /swap.img ]; then
    sudo rm -f /swap.img
    echo "File /swap.img berhasil dihapus untuk menghemat ruang disk."
fi

echo "=== [2/6] Memperluas Partisi LVM Ubuntu ke 100% Kapasitas Disk ==="
if sudo lvdisplay /dev/mapper/ubuntu--vg-ubuntu--lv >/dev/null 2>&1; then
    sudo lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv || true
    sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
    echo "Partisi LVM berhasil diperluas:"
    df -h /
else
    echo "Sistem tidak menggunakan path LVM default Ubuntu, melewati lvextend."
fi

echo "=== [3/6] Mengatur /etc/hosts, Kernel Modules, & Sysctl Networking ==="
grep -q "${MASTER_IP} ${MASTER_HOSTNAME}" /etc/hosts || echo "${MASTER_IP} ${MASTER_HOSTNAME}" | sudo tee -a /etc/hosts
grep -q "${WORKER_IP} ${WORKER_HOSTNAME}" /etc/hosts || echo "${WORKER_IP} ${WORKER_HOSTNAME}" | sudo tee -a /etc/hosts

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

echo "=== [4/6] Instalasi & Konfigurasi containerd (SystemdCgroup = true) ==="
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg containerd jq

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sudo sed -i 's|registry.k8s.io/pause:3.8|registry.k8s.io/pause:3.10|g' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd

echo "=== [5/6] Instalasi Kubelet, Kubeadm, & Kubectl (${K8S_VERSION}) ==="
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key | sudo gpg --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet

echo "=== [6/6] Pembersihan Cache OS & Limitasi Log Systemd ==="
sudo journalctl --vacuum-size=200M
sudo apt-get clean && sudo apt-get autoremove -y

echo "=================================================================="
echo "Selesai! Node $(hostname) siap untuk inisialisasi/join Kubernetes."
echo "=================================================================="