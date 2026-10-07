#!/usr/bin/env bash
# Install k3s (single node) and hand the kubeconfig to the invoking user.
# Needs root: sudo bootstrap/00-install-k3s.sh
# Idempotent: re-running upgrades/ reconfigures k3s in place.
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.36.5+k3s1}"  # pinned: the traefik HelmChartConfig is written against this release's bundled chart
NODE_IP="${NODE_IP:-192.168.4.243}"       # fixed DHCP lease on the UDM
TARGET_USER="${SUDO_USER:-${USER}}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

if [[ $EUID -ne 0 ]]; then echo "run with sudo" >&2; exit 1; fi

mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<CFG
# managed by lab-k3s/bootstrap/00-install-k3s.sh
node-ip: ${NODE_IP}
node-external-ip: ${NODE_IP}
tls-san:
  - ${NODE_IP}
  - k3s.lab.kleincogroup.com
  - notatonix
write-kubeconfig-mode: "0600"
# traefik + servicelb stay enabled (defaults); we customise traefik via HelmChartConfig.
# systemd-resolved: point kubelet at the real upstream list, not the 127.0.0.53 stub
resolv-conf: /run/systemd/resolve/resolv.conf
# this is also a desktop/dev box: keep memory back from pods and evict before the host swaps to death
kubelet-arg:
  - "max-pods=250"
  - "system-reserved=memory=10Gi,cpu=2"
  - "eviction-hard=memory.available<1Gi,nodefs.available<5%,imagefs.available<5%"
CFG

export INSTALL_K3S_CHANNEL="${INSTALL_K3S_CHANNEL:-stable}"
[[ -n "$K3S_VERSION" ]] && export INSTALL_K3S_VERSION="$K3S_VERSION"
curl -sfL https://get.k3s.io | sh -

# kubeconfig for the user
install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 0700 "$TARGET_HOME/.kube"
if [[ -f "$TARGET_HOME/.kube/config" ]]; then cp -p "$TARGET_HOME/.kube/config" "$TARGET_HOME/.kube/config.bak-$(date +%s)"; fi
install -o "$TARGET_USER" -g "$TARGET_USER" -m 0600 /etc/rancher/k3s/k3s.yaml "$TARGET_HOME/.kube/config"
sed -i "s#https://127.0.0.1:6443#https://${NODE_IP}:6443#" "$TARGET_HOME/.kube/config"

# helm for the user (k3s bundles kubectl at /usr/local/bin/kubectl)
if ! command -v helm >/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | DESIRED_VERSION="${HELM_VERSION:-v3.22.0}" bash
fi

echo "waiting for node Ready..."
for _ in $(seq 1 60); do
  if kubectl get node -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then break; fi
  sleep 2
done
kubectl get node -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' | grep -q True || { echo "node not Ready after 120s" >&2; journalctl -u k3s --no-pager -n 30 >&2; exit 1; }
kubectl get node -o wide
echo "k3s installed. Next: bootstrap/10-secrets.sh then bootstrap/20-argocd.sh (as $TARGET_USER, no sudo)."
