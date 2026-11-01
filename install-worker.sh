#!/usr/bin/env bash
# ==============================================================================
# Script 02: Init Control Plane, Cilium eBPF, Gateway API, & Demo NGINX
# Jalankan HANYA di Node Master (Control-Plane)
# ==============================================================================

set -euo pipefail

# --- KONFIGURASI PARAMETER CLUSTER (Sesuaikan dengan IP Lab Anda) ---
API_SERVER_IP=$(hostname -I | awk '{print $1}')
K8S_FULL_VERSION="v1.37.0"
POD_SUBNET="10.244.0.0/16"
SERVICE_SUBNET="10.96.0.0/12"
LB_IP_START="192.168.56.200"
LB_IP_STOP="192.168.56.210"

echo "=== [1/7] Inisialisasi Control Plane Kubernetes (Kube-Proxy Free) ==="
cat <<EOF > kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "${API_SERVER_IP}"
  bindPort: 6443
skipPhases:
  - addon/kube-proxy
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: "${K8S_FULL_VERSION}"
networking:
  podSubnet: "${POD_SUBNET}"
  serviceSubnet: "${SERVICE_SUBNET}"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
evictionHard:
  imagefs.available: "5%"
  nodefs.available: "5%"
  nodefs.inodesFree: "5%"
EOF

sudo kubeadm init --config kubeadm-config.yaml --upload-certs

echo "=== [2/7] Mengatur Kubeconfig untuk User $(whoami) ==="
mkdir -p "$HOME/.kube"
sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

echo "=== [3/7] Menginstal Gateway API CRDs Terbaru (Experimental Channel v1) ==="
GW_API_VERSION=$(curl -s https://api.github.com/repos/kubernetes-sigs/gateway-api/releases/latest | jq -r .tag_name)
if [ -z "${GW_API_VERSION}" ] || [ "${GW_API_VERSION}" = "null" ]; then
    GW_API_VERSION="v1.5.0"
fi
echo "Memasang Gateway API CRD versi ${GW_API_VERSION}..."
kubectl apply --server-side --force-conflicts -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GW_API_VERSION}/experimental-install.yaml"

echo "=== [4/7] Menginstal Cilium CLI & Deploy Cilium eBPF + Gateway API ==="
if ! command -v cilium >/dev/null 2>&1; then
    CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
    CLI_ARCH=amd64
    if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
    curl -L --fail --remote-name-all "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz"
    sudo tar xzvfC "cilium-linux-${CLI_ARCH}.tar.gz" /usr/local/bin
    rm -f "cilium-linux-${CLI_ARCH}.tar.gz"
fi

cilium install \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="${API_SERVER_IP}" \
  --set k8sServicePort=6443 \
  --set gatewayAPI.enabled=true \
  --set l2announcements.enabled=true \
  --set externalIPs.enabled=true \
  --set operator.replicas=1

echo ""
echo "=========================================================================="
echo "INSTRUKSI JOIN WORKER NODE:"
echo "Jalankan perintah berikut (dengan sudo) di terminal Worker Node Anda:"
echo "--------------------------------------------------------------------------"
kubeadm token create --print-join-command
echo "=========================================================================="
read -r -p "Tekan [ENTER] setelah Anda menjalankan perintah join di Worker Node..."

echo "=== [5/7] Menunggu Cilium & Seluruh Node Berstatus Ready ==="
kubectl rollout restart deployment/cilium-operator -n kube-system
cilium status --wait
kubectl get nodes -o wide

echo "=== [6/7] Mengonfigurasi Cilium L2 LoadBalancer IP Pool (cilium.io/v2) ==="
cat <<EOF | kubectl apply -f -
apiVersion: "cilium.io/v2"
kind: CiliumLoadBalancerIPPool
metadata:
  name: "lab-ip-pool"
spec:
  blocks:
  - start: "${LB_IP_START}"
    stop: "${LB_IP_STOP}"
---
apiVersion: "cilium.io/v2alpha1"
kind: CiliumL2AnnouncementPolicy
metadata:
  name: "lab-l2-policy"
spec:
  loadBalancerIPs: true
  externalIPs: true
  interfaces:
  - ^eth.*
  - ^enp.*
  - ^ens.*
EOF

echo "=== [7/7] Men-deploy Demo Aplikasi NGINX, Gateway, & HTTPRoute ==="
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web-svc
spec:
  selector:
    app: web
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: prod-gateway
spec:
  gatewayClassName: cilium
  listeners:
  - protocol: HTTP
    port: 80
    name: web-gw
    allowedRoutes:
      namespaces:
        from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: web-route
spec:
  parentRefs:
  - name: prod-gateway
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: web-svc
      port: 80
EOF

echo "Menunggu Gateway mendapatkan IP Address dan berstatus PROGRAMMED: True..."
kubectl wait --for=condition=Programmed gateway/prod-gateway --timeout=120s

GW_IP=$(kubectl get gateway prod-gateway -o jsonpath='{.status.addresses[0].value}')
echo ""
echo "=========================================================================="
echo "INSTALASI SELESAI & BERHASIL!"
echo "Status GatewayClass & Gateway:"
kubectl get gatewayclass,gateway
echo "--------------------------------------------------------------------------"
echo "Uji akses HTTP ke NGINX melalui Gateway IP (${GW_IP}):"
curl -I "http://${GW_IP}"
echo "=========================================================================="