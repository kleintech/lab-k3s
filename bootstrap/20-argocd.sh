#!/usr/bin/env bash
# Install Argo CD with helm (one-time; afterwards Argo CD manages itself from argocd/apps/argocd.yaml),
# then apply the root app-of-apps. First install only (afterwards Argo CD upgrades itself from
# argocd/apps/argocd.yaml). Push main to GitHub BEFORE running this: the root app syncs from there. No sudo.
set -euo pipefail
cd "$(dirname "$0")/.."
ARGOCD_CHART_VERSION="$(grep -E '^\s+targetRevision:' argocd/apps/argocd.yaml | head -1 | awk '{print $2}')"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
  --version "$ARGOCD_CHART_VERSION" -f platform/argocd/values.yaml --wait --timeout 10m
kubectl apply -f argocd/root-app.yaml
echo "Argo CD admin password:"; kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "(initial admin secret already deleted)"; echo
echo "UI: https://argocd.lab.kleincogroup.com (after certs are issued; before that: kubectl -n argocd port-forward svc/argocd-server 8080:443)"
