#!/usr/bin/env bash
# Install k3s (single node) and hand the kubeconfig to the invoking user.
# Needs root: sudo bootstrap/00-install-k3s.sh
# Idempotent: re-running upgrades/ reconfigures k3s in place.
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-}"            # empty = latest stable channel
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
write-kubeconfig-mode: "0644"
# traefik + servicelb stay enabled (defaults); we customise traefik via HelmChartConfig.
kubelet-arg:
  - "max-pods=250"
CFG

export INSTALL_K3S_CHANNEL="${INSTALL_K3S_CHANNEL:-stable}"
[[ -n "$K3S_VERSION" ]] && export INSTALL_K3S_VERSION="$K3S_VERSION"
curl -sfL https://get.k3s.io | sh -

# kubeconfig for the user
install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 0700 "$TARGET_HOME/.kube"
install -o "$TARGET_USER" -g "$TARGET_USER" -m 0600 /etc/rancher/k3s/k3s.yaml "$TARGET_HOME/.kube/config"
sed -i "s#https://127.0.0.1:6443#https://${NODE_IP}:6443#" "$TARGET_HOME/.kube/config"

# helm for the user (k3s bundles kubectl at /usr/local/bin/kubectl)
if ! command -v helm >/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo "waiting for node Ready..."
for i in $(seq 1 60); do
  if kubectl get node -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then break; fi
  sleep 2
done
kubectl get node -o wide
echo "k3s installed. Next: bootstrap/10-secrets.sh then bootstrap/20-argocd.sh (as $TARGET_USER, no sudo)."
