# lab-k3s

Infrastructure as code for the single-node k3s lab on `notatonix` (192.168.4.243). Argo CD
reconciles branch `main` of this repo into the cluster, so **a push to `main` is a deploy**.
Internal services live at `https://<name>.lab.kleincogroup.com` (LAN only, real Let's Encrypt
certs). Selected services are published as `https://<name>.kleincogroup.com` through a
Cloudflare Tunnel.

Read **[CONVENTIONS.md](CONVENTIONS.md)** before adding anything. It covers the domain/TLS
model, the Argo CD layout, namespaces and secret names. No secrets in this repo, ever.

## Layout

```
bootstrap/     applied by hand, once: k3s install, secrets, Argo CD seed
argocd/        root-app.yaml (app-of-apps) + apps/<name>.yaml, one Application per component
platform/      cluster services: cert-manager, issuers/certs, traefik, argocd, monitoring, registry, ci
apps/          workload apps (apps/<name>/), each with an Application in argocd/apps/
templates/     starting point for a new project: Dockerfile, k8s manifests, CI workflow
scripts/       ops tools: udm-dns.sh (LAN DNS on the UDM Pro), expose.sh / unexpose.sh (Cloudflare)
docs/          runbooks and design notes (below)
```

## Bootstrap

From a clone on notatonix, with `~/.config/lab-k3s/secrets.env` (keys in
`bootstrap/secrets.env.example`) and `~/.config/lab-k3s/udm.env` (UniFi API key or local
admin, see [docs/dns.md](docs/dns.md#credentials-configlab-k3sudmenv-chmod-600-never-in-git))
in place:

```
sudo bootstrap/00-install-k3s.sh   # k3s (Traefik + ServiceLB), kubeconfig, helm
bootstrap/10-secrets.sh            # namespaces + the secrets charts expect
bootstrap/20-argocd.sh             # Argo CD, then the root app-of-apps (push main to GitHub first; Argo syncs from there)
scripts/udm-dns.sh ensure-lab      # LAN DNS: *.lab.kleincogroup.com -> 192.168.4.243 on the UDM
```

A full rebuild from a blank box, including what isn't in git, is in
[docs/rebuild.md](docs/rebuild.md).

## Docs

- [docs/dns.md](docs/dns.md): `lab.kleincogroup.com`, split-horizon DNS on the UDM Pro, VLANs, `udm-dns.sh`
- [docs/cloudflare.md](docs/cloudflare.md): publishing a service with `expose.sh`, Access gating, the one-label limit
- [docs/rebuild.md](docs/rebuild.md): disaster recovery and backups
- [docs/ci.md](docs/ci.md): in-cluster GitHub Actions runners (`runs-on: lab-k3s`)
- [docs/observability.md](docs/observability.md): Prometheus / Grafana
- [templates/README.md](templates/README.md): onboarding a new project
