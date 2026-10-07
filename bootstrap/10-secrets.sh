#!/usr/bin/env bash
# Create the namespaces + secrets that charts expect (see CONVENTIONS.md "Secrets").
# Reads ~/.config/lab-k3s/secrets.env. Idempotent. No sudo.
set -euo pipefail
ENV_FILE="${LAB_SECRETS:-$HOME/.config/lab-k3s/secrets.env}"
[[ -f "$ENV_FILE" ]] && { set -a; . "$ENV_FILE"; set +a; }

CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-$(cat "$HOME/.config/cloudflare/api-token" 2>/dev/null || true)}"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-}"
GITHUB_RUNNER_TOKEN="${GITHUB_RUNNER_TOKEN:-}"

[[ -n "$CLOUDFLARE_API_TOKEN" ]] || { echo "CLOUDFLARE_API_TOKEN missing" >&2; exit 1; }
if [[ -z "$GRAFANA_ADMIN_PASSWORD" ]]; then
  GRAFANA_ADMIN_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24)"
  mkdir -p "$(dirname "$ENV_FILE")"; touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
  printf 'GRAFANA_ADMIN_PASSWORD=%s\n' "$GRAFANA_ADMIN_PASSWORD" >> "$ENV_FILE"
  echo "generated GRAFANA_ADMIN_PASSWORD and saved it to $ENV_FILE"
fi

ns() { kubectl get ns "$1" >/dev/null 2>&1 || kubectl create ns "$1"; }
for n in argocd cert-manager monitoring registry arc-systems arc-runners; do ns "$n"; done

kubectl -n cert-manager create secret generic cloudflare-api-token \
  --from-literal=api-token="$CLOUDFLARE_API_TOKEN" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user="$GRAFANA_ADMIN_USER" --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
if [[ -n "$GITHUB_RUNNER_TOKEN" ]]; then
  kubectl -n arc-runners create secret generic github-runner-token \
    --from-literal=github_token="$GITHUB_RUNNER_TOKEN" --dry-run=client -o yaml | kubectl apply -f -
else
  echo "GITHUB_RUNNER_TOKEN not set: skipping arc-runners/github-runner-token (CI runners will stay pending until it exists)"
fi
echo "secrets in place."
