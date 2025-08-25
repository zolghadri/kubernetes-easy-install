#!/usr/bin/env bash
set -euo pipefail

# === Config ===
K8S_MINOR="${K8S_MINOR:-v1.33}"    # Kubernetes minor for pkgs repo (matches docs)
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"  # Default matches Flannel; Cilium will use it too
ARCH="${ARCH:-amd64}"              # change if needed: arm64, etc.
CNI="${CNI:-flannel}"              # flannel | cilium

echo "[0/11] Checking prerequisites (root, network)..."
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (use sudo)." >&2
  exit 1
fi
ping -c1 -W2 dl.k8s.io >/dev/null 2>&1 || echo "Warning: network check failed; continuing..."

echo "[1/11] System prep: packages, kernel modules, sysctl..."
apt-get update -y
apt-get install -y ca-certificates curl gpg apt-transport-https \
                   conntrack socat ebtables ipset lsb-release

# Kernel modules needed by Kubernetes networking
modprobe overlay || true
modprobe br_netfilter || true
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

# Sysctl for bridged traffic & forwarding
cat >/etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

echo "[2/11] Disable swap (required by kubelet unless configured otherwise)..."
swapoff -a || true
sed -ri 's/^\s*([^#]\S+\s+\S+\s+swap\s+\S+).*$/# \1 # disabled for k8s/' /etc/fstab || true

echo "[3/11] Install and configure containerd (CRI runtime)..."
apt-get install -y containerd containernetworking-plugins

mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml

mkdir -p /opt/cni/bin

# Point containerd CNI bin_dir to /opt/cni/bin (Flannel copies its binary there)
sed -ri 's|^( *bin_dir *= *).*$|\1"/opt/cni/bin"|' /etc/containerd/config.toml || true
grep -q 'plugins."io.containerd.grpc.v1.cri".cni' /etc/containerd/config.toml || \
  echo -e '\n[plugins."io.containerd.grpc.v1.cri".cni]\n  bin_dir = "/opt/cni/bin"\n  conf_dir = "/etc/cni/net.d"\n' >> /etc/containerd/config.toml
systemctl restart containerd







# Use systemd cgroups to match kubelet (recommended)
sed -ri 's/^(\s*)SystemdCgroup\s*=\s*false/\1SystemdCgroup = true/' /etc/containerd/config.toml || true
systemctl enable --now containerd

echo "[4/11] Add Kubernetes apt repo (pkgs.k8s.io, per ${K8S_MINOR} docs)..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Overwrite to ensure a clean single source list
cat >/etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /
EOF
apt-get update -y

echo "[5/11] Install kubelet, kubeadm, kubectl and hold their versions..."
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet

echo "[6/11] kubeadm init (single-node control plane) with pod CIDR ${POD_CIDR}..."
# Pre-pull images to speed up init (optional)
kubeadm config images pull || true

# You can pin a specific version via --kubernetes-version; using repo default here
kubeadm init --pod-network-cidr="${POD_CIDR}"

echo "[7/11] Configure kubectl for the current (non-root) user if present..."
USER_NAME=${SUDO_USER:-root}
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
mkdir -p "${USER_HOME}/.kube"
cp -i /etc/kubernetes/admin.conf "${USER_HOME}/.kube/config"
chown -R "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.kube"

# Helper for kubectl as target user
k() { su - "$USER_NAME" -c "kubectl $*"; }

echo "[8/11] Install Helm (v3)..."
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
  echo "Helm already installed."
fi

echo "[9/11] Install CNI: ${CNI}"
case "$CNI" in
  flannel)
    echo "-> Applying Flannel manifest..."
    k apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
    echo "-> Waiting for Flannel DaemonSet to be ready..."
    k -n kube-flannel rollout status ds/kube-flannel-ds --timeout=180s || true
    ;;
  cilium)
    echo "-> Installing cilium-cli for convenience..."
    if ! command -v cilium >/dev/null 2>&1; then
      # Install latest cilium-cli (binary install)
      CIL_VER=$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
      curl -fsSL -o /usr/local/bin/cilium https://github.com/cilium/cilium-cli/releases/download/${CIL_VER}/cilium-linux-${ARCH}
      chmod +x /usr/local/bin/cilium
    fi

    echo "-> Adding Helm repo & installing Cilium..."
    su - "$USER_NAME" -c "helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true"
    su - "$USER_NAME" -c "helm repo update >/dev/null 2>&1 || true"

    # Install Cilium with kube-proxy partial replacement and cluster-pool IPAM
    su - "$USER_NAME" -c "helm upgrade --install cilium cilium/cilium \
        --namespace kube-system \
        --set kubeProxyReplacement=partial \
        --set ipam.mode=cluster-pool \
        --set ipam.operator.clusterPoolIPv4PodCIDRList={${POD_CIDR}}"

    echo "-> Waiting for Cilium to become ready..."
    k -n kube-system rollout status ds/cilium --timeout=240s || true
    k -n kube-system rollout status deploy/cilium-operator --timeout=240s || true

    echo "-> (Optional) Validate Cilium status"
    su - "$USER_NAME" -c "cilium status --wait --verbose || true"
    ;;
  *)
    echo "Unsupported CNI value: ${CNI}. Use 'flannel' or 'cilium'." >&2
    exit 2
    ;;
esac

echo "[10/11] Allow scheduling on control plane (single-node convenience)..."
k taint nodes --all node-role.kubernetes.io/control-plane- || true
k taint nodes --all node-role.kubernetes.io/master- || true

echo "[11/11] Quick health checks..."
# Core components
k -n kube-system get pods -o wide
# Node Ready?
k get nodes -o wide
# CNI namespace check
if [[ "$CNI" == "flannel" ]]; then
  k -n kube-flannel get pods -o wide
else
  k -n kube-system get pods -l k8s-app=cilium -o wide
fi

echo
echo "=== Done! ==="
echo "CNI installed: ${CNI}"
echo "Helm installed: $(helm version --short 2>/dev/null || echo 'not found')"
echo
echo "Check CoreDNS:"
echo "  kubectl -n kube-system get deploy/coredns && kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide"
echo
echo "Worker join command (use on additional nodes):"
kubeadm token create --print-join-command
