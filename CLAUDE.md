# lab-k3s

Infrastructure-as-code for the single-node k3s lab on `notatonix`. Argo CD reconciles
branch `main` of this repo into the cluster, so **a push to main is a deploy**.

- Read `CONVENTIONS.md` first: domain/TLS model, Argo CD layout, namespaces, secret names.
- Never commit secrets. Secrets come from `~/.config/lab-k3s/secrets.env` via `bootstrap/10-secrets.sh`.
- Pin every chart version and image tag. Validate with `helm template` + kubeconform before pushing.
- `bootstrap/` is the only thing applied by hand (k3s install, secrets, Argo CD seed); everything else goes through `argocd/apps/`.
- Ops scripts: `scripts/udm-dns.sh` (LAN DNS on the UDM Pro), `scripts/expose.sh` / `unexpose.sh` (Cloudflare tunnel). Docs in `docs/`.
- After changing anything under `platform/` or `argocd/`, check `kubectl -n argocd get applications` until the affected app is Synced/Healthy and say so.
