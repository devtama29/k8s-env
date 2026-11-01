# Production-Ready Vanilla Kubernetes v1.37 Lab (Cilium eBPF & Gateway API)

This repository provides automated bash scripts and complete documentation to bootstrap a **production-grade Vanilla Kubernetes v1.37 ("Garhwal")** cluster on **Ubuntu LTS**.

Tailored for resource-constrained lab environments (1 Control-Plane + 1 Worker) without sacrificing modern production standards, this architecture **completely eliminates `iptables`-based `kube-proxy`**, replacing it with **Cilium (eBPF)** as the CNI, Layer 2 LoadBalancer, and **Kubernetes Gateway API** controller.

---

## 🏗️ Architecture & Stack

```text
                        [ Client / Browser ]
                                 │
                   HTTP (192.168.137.200 - L2 VIP)
                                 ▼
               ┌───────────────────────────────────┐
               │   Cilium Gateway API (Envoy L7)   │
               │   Gateway: prod-gateway           │
               │   HTTPRoute: web-route (/)        │
               └─────────────────┬─────────────────┘
                                 │ eBPF Routing (Kube-Proxy Free)
                 ┌───────────────┴───────────────┐
                 ▼                               ▼
     ┌───────────────────────┐       ┌───────────────────────┐
     │ Node 1: ubuntu        │       │ Node 2: kubeworker    │
     │ Role: Control-Plane   │       │ Role: Worker          │
     │ IP: 192.168.137.10    │       │ IP: 192.168.137.11    │
     │                       │       │                       │
     │ [Control Plane Pods]  │       │ [App: NGINX Replica 1]│
     │ [Cilium Agent + Oper] │       │ [App: NGINX Replica 2]│
     └───────────────────────┘       └───────────────────────┘
```

| Component | Version / Spec | Role & Key Configurations |
| :--- | :--- | :--- |
| **OS** | Ubuntu 24.04 LTS | 100% LVM Root Expansion, Swap Disabled, Kernel Modules (`overlay`, `br_netfilter`). |
| **Kubernetes** | `v1.37.0` (Garhwal) | Bootstrapped via `kubeadm` (`v1beta4` API), native *KYAML* support. |
| **Container Runtime** | `containerd 2.x` | Configured with `SystemdCgroup = true` and `pause:3.10` sandbox image. |
| **CNI & Data Plane** | Cilium (eBPF) | Runs in `kubeProxyReplacement=true` mode, completely replacing `kube-proxy`. |
| **Traffic Routing** | Gateway API (`v1.5.0+`) | Experimental Channel CRDs (`Gateway`, `HTTPRoute`, `TLSRoute`, `ReferenceGrant`, `BackendTLSPolicy` `v1`). |
| **Bare-Metal LB** | Cilium L2 Announcements | Assigns External VIPs (`192.168.137.200-210`) via ARP without requiring MetalLB. |

---

## 💻 Prerequisites & VM Specifications

Provision 2 Virtual Machines (Multipass / VirtualBox / Proxmox / KVM / VMware) connected to the same *Host-Only* or *Bridged* subnet:

| Hostname | Role | IP Address | vCPU | RAM | Disk |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `ubuntu` | Control-Plane (Master) | `192.168.137.10` | 2 Cores | 3 - 4 GB | 20 GB |
| `kubeworker` | Worker Node | `192.168.137.11` | 2 Cores | 2 GB | 20 GB |

> **Note:** If your VM network uses a different subnet than `192.168.137.0/24`, update the IP variables at the top of `01-setup-node.sh` and `02-init-master-cilium-gateway.sh` before executing them.

---

## 📂 Repository Structure

```text
.
├── 01-setup-node.sh                  # Run on BOTH nodes (OS hardening, LVM expansion, containerd, kubeadm)
├── 02-init-master-cilium-gateway.sh  # Run ONLY on Master (K8s Init, Cilium eBPF, Gateway API, Demo NGINX)
└── README.md                         # Architecture, installation, and troubleshooting guide
```

---

## 🚀 Step-by-Step Installation Guide

### Step 1: Node Preparation (Run on BOTH Master & Worker)

Copy and execute `01-setup-node.sh` on **both nodes** (`ubuntu` and `kubeworker`). This script disables swap, removes `/swap.img`, expands the default Ubuntu LVM root volume to 100%, configures `containerd` with `SystemdCgroup`, and installs `kubeadm`, `kubelet`, and `kubectl` v1.37.

```bash
chmod +x 01-setup-node.sh
./01-setup-node.sh
```

### Step 2: Control-Plane Init, Cilium, & Gateway API (Run ONLY on Master)

Execute `02-init-master-cilium-gateway.sh` on the **Master node (`ubuntu`)**:

```bash
chmod +x 02-init-master-cilium-gateway.sh
./02-init-master-cilium-gateway.sh
```

**Automated workflow inside `02-init-master-cilium-gateway.sh`:**
1. Initializes the Kubernetes control plane without `kube-proxy` (`skipPhases: [addon/kube-proxy]`) and sets lab-friendly Kubelet eviction thresholds (`5%`).
2. Configures `$HOME/.kube/config` for the current user.
3. Installs the latest **Gateway API CRDs (Experimental Channel)** using `--server-side --force-conflicts`.
4. Installs the **Cilium CLI** and deploys Cilium with `kubeProxyReplacement`, `gatewayAPI`, and `l2announcements` enabled.
5. **Interactive Prompt:** Generates and prints the `kubeadm join` command, then pauses. Copy and run the `sudo kubeadm join ...` command on your **Worker Node (`kubeworker`)**, then press **[ENTER]** on the Master terminal to continue.
6. Configures the `CiliumLoadBalancerIPPool` (`cilium.io/v2`) and `CiliumL2AnnouncementPolicy`.
7. Deploys a sample `nginx:alpine` application (2 replicas) exposed via a `Service`, `Gateway`, and `HTTPRoute`.

---

## ✅ Verification & Testing

Once the scripts finish executing, verify your cluster health and traffic routing using the following commands:

### 1. Verify Node & Cilium eBPF Status
```bash
kubectl get nodes -o wide
cilium status
```
Ensure both nodes report `Ready` and `cilium status` shows `KubeProxyReplacement: True`.

### 2. Verify GatewayClass & Gateway API Resources
```bash
kubectl get gatewayclass,gateway,httproute
```
Expected output:
```text
NAME                                        CONTROLLER                     ACCEPTED   AGE
gatewayclass.gateway.networking.k8s.io/cilium   io.cilium/gateway-controller   True       5m

NAME                                         CLASS    ADDRESS          PROGRAMMED   AGE
gateway.gateway.networking.k8s.io/prod-gateway   cilium   192.168.137.200   True         3m

NAME                                         HOSTNAMES   AGE
httproute.gateway.networking.k8s.io/web-route                3m
```

### 3. Test HTTP Traffic via Gateway VIP
```bash
GW_IP=$(kubectl get gateway prod-gateway -o jsonpath='{.status.addresses[0].value}')
curl -i http://${GW_IP}
```

### 4. Explore Kubernetes v1.37 Native KYAML Output
Kubernetes v1.37 graduates **KYAML** to Stable, providing an unambiguous, explicit alternative to traditional whitespace-sensitive YAML:
```bash
kubectl get gateway prod-gateway -o kyaml
```

---

## 🛠️ Troubleshooting & Built-in Fixes

This section documents key production/lab issues already resolved and baked into the installation scripts:

### 1. `NodeHasDiskPressure` / `FreeDiskSpaceFailed` on Ubuntu VMs
* **Root Cause:** By default, the Ubuntu Server LVM installer only allocates ~50% (10–11 GiB) of the virtual disk to the root logical volume (`/`) and creates a 2–4 GB `/swap.img` file. Once container images push disk usage past 85% (`imagefs.available < 15%`), Kubelet taints the node with `DiskPressure`.
* **Built-in Fix (`01-setup-node.sh`):** Deletes `/swap.img`, extends the LVM logical volume to 100% (`lvextend -l +100%FREE` + `resize2fs`), and tunes Kubelet `evictionHard` thresholds to `5%`.

### 2. Nodes Stuck in `NotReady` & CoreDNS Pods `Pending` (`untolerated taint`)
* **Root Cause:** Kubelet applies the `node.kubernetes.io/not-ready:NoSchedule` taint until a CNI plugin initializes the node network.
* **Built-in Fix:** Deploys Cilium immediately after control-plane initialization once sufficient disk space is guaranteed.

### 3. `CiliumL2AnnouncementPolicy` Strict Decoding Error & IP Pool Deprecation
* **Root Cause:** Kubernetes CRD schemas are strictly case-sensitive (`spec.LoadBalancerIPs` fails decoding; it must be camelCase `spec.loadBalancerIPs`). Additionally, `CiliumLoadBalancerIPPool` has graduated from `cilium.io/v2alpha1` to `cilium.io/v2`.
* **Built-in Fix (`02-init-master-cilium-gateway.sh`):** Uses `cilium.io/v2` for `CiliumLoadBalancerIPPool` and `loadBalancerIPs: true` in `CiliumL2AnnouncementPolicy`.

### 4. `GatewayClass` and `Gateway` Stuck in `Unknown` Status
* **Root Cause:** Recent Cilium releases require `tlsroutes`, `referencegrants`, and `backendtlspolicies` CRDs at API version `gateway.networking.k8s.io/v1`. Installing older `standard-install.yaml` bundles leaves these CRDs missing or on `v1alpha2`/`v1beta1`, causing `cilium-operator` to abort Gateway API controller initialization.
* **Built-in Fix (`02-init-master-cilium-gateway.sh`):** Applies the latest Gateway API `experimental-install.yaml` (`v1.5.0+`) with `--server-side --force-conflicts` prior to starting Cilium and restarts `cilium-operator`.