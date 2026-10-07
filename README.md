# lab-k3s

Infrastructure as code for the single-node k3s lab on `notatonix` (192.168.4.243). Argo CD
reconciles branch `main` of this repo into the cluster, so **a push to `main` is a deploy**.
Internal services live at `https://<name>.lab.kleincogroup.com` (LAN only, real Let's Encrypt
certs, no browser warnings). Selected services can be published as
`https://<name>.kleincogroup.com` through the existing Cloudflare Tunnel; the same link works
directly on the LAN and through the tunnel from outside.

Read **[CONVENTIONS.md](CONVENTIONS.md)** before adding anything. It covers the domain/TLS
model, the Argo CD layout, namespaces and secret names. **No secrets in this repo, ever.**

## What is running

| service | URL | login |
|---|---|---|
| Argo CD (deploys) | https://argocd.lab.kleincogroup.com | `admin` / `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| Grafana (dashboards) | https://grafana.lab.kleincogroup.com | `admin` / `GRAFANA_ADMIN_PASSWORD` in `~/.config/lab-k3s/secrets.env` |
| Prometheus / Alertmanager | in-cluster only (`kubectl -n monitoring port-forward`) | none |
| Image registry | https://registry.lab.kleincogroup.com | none (source-IP allow-list: Parent/Default/VPN VLANs + pods) |
| Traefik dashboard | https://traefik.lab.kleincogroup.com/dashboard/ | none (same allow-list) |
| whoami (smoke test) | https://whoami.lab.kleincogroup.com | none |
| GitHub Actions runners | label `runs-on: lab-k3s`, one runner set per listed private repo | see [docs/ci.md](docs/ci.md) |

Cluster access from this box: `kubectl` with `KUBECONFIG=$HOME/.kube/config` (exported by
`~/.config/shell/common.sh`; no sudo). `helm` is in `/usr/local/bin`.

## Layout

```
bootstrap/     applied by hand, once: k3s install, secrets, Argo CD seed
argocd/        root-app.yaml (app-of-apps) + apps/<name>.yaml, one Application per component
platform/      cluster services: cert-manager, issuers/certs, traefik, argocd, monitoring, registry, ci
apps/          workload apps (apps/<name>/), each with an Application in argocd/apps/
templates/     starting point for a new project: Dockerfile, k8s manifests, CI workflow, Argo app
scripts/       ops tools: udm-dns.sh / udm-dns-mongo.sh (LAN DNS on the UDM Pro), expose.sh / unexpose.sh (Cloudflare)
docs/          runbooks and design notes (below)
```

## Deploying a project

Three modes, by intent (the `lab-k3s` Claude Code skill follows the same rules):

1. **Dev / test** (throwaway): build and push the image, then deploy with kubectl into
   `dev-<project>`.
   ```
   IMG=registry.lab.kleincogroup.com/<project>/<name>:$(git rev-parse --short HEAD)
   docker build -t "$IMG" . && docker push "$IMG"
   kubectl create ns dev-<project>
   kubectl -n dev-<project> apply -k k8s/          # k8s/ from templates/app/, tag set in kustomization.yaml
   curl -sS https://<name>.lab.kleincogroup.com/   # valid cert, no -k
   kubectl delete ns dev-<project>                 # when done
   ```
   If a prod deploy of the same service exists, change the dev Ingress host to
   `<name>-dev.lab.kleincogroup.com` first (two Ingresses on one host split traffic).
2. **"Prod" (internal, for other people)**: manifests stay in the project repo under `k8s/`
   with an immutable image tag committed; add `argocd/apps/<name>.yaml` **here** (copy
   `templates/app/argocd-application.yaml`), push `main`. Argo CD syncs within ~1 min:
   `kubectl -n argocd get application <name>`. Private project repos need a repository
   credential in Argo CD first (see `templates/app/argocd-application.yaml`).
3. **CI**: copy `templates/app/.github/workflows/ci.yaml` (`runs-on: lab-k3s`), add the repo
   to `argocd/apps/arc-runners.yaml` and to the runner token's repository access
   ([docs/ci.md](docs/ci.md)). **Private repos only**: runner pods are privileged
   Docker-in-Docker on the LAN node.

Full walkthrough and placeholders: [templates/README.md](templates/README.md). To publish a
service on the Internet: [docs/cloudflare.md](docs/cloudflare.md) (`scripts/expose.sh`).

### Telling a Claude Code session to deploy here

The global `~/.claude/CLAUDE.md` (dotfiles) points every session on `notatonix` at the
`lab-k3s` skill (`~/.claude/skills/lab-k3s/SKILL.md`), which encodes the three modes above.
A prompt that works in any project session:

> Deploy this to the local k3s lab as a dev deploy. Load the lab-k3s skill and follow it:
> build the image, push it to registry.lab.kleincogroup.com/<project>/<name>:<git-sha>,
> deploy with kubectl into namespace dev-<project> using ~/dev/lab-k3s/templates/app/,
> and verify https://<name>.lab.kleincogroup.com returns the app with a valid cert.

Say "promote this to prod via Argo CD" for mode 2.

## Setting it up from scratch

Short form; the full disaster-recovery runbook with backups and what is *not* in git is
[docs/rebuild.md](docs/rebuild.md).

Prerequisites on the box: Ubuntu, user `jklein`, hostname `notatonix`, fixed DHCP lease
192.168.4.243 on the UDM (keyed to the Wi-Fi MAC; see rebuild.md §1), `git curl jq dnsutils
docker`, `gh auth login`, and these files restored (all mode 600, none in git):

| file | content |
|---|---|
| `~/.config/lab-k3s/secrets.env` | keys in `bootstrap/secrets.env.example` (Cloudflare token, Grafana admin, GitHub runner token) |
| `~/.config/lab-k3s/udm.env` | UniFi API key or local admin for `scripts/udm-dns.sh` ([docs/dns.md](docs/dns.md)); optional, `udm-dns-mongo.sh` works over SSH instead |
| `~/.config/cloudflare/api-token` | fallback source for the Cloudflare token (Zone DNS Edit + Tunnel Edit) |
| `/etc/cloudflared/token` | tunnel `homelab` run token, only if the box also runs the tunnel connector (rebuild.md §5) |

Then:

```
git clone git@github.com:kleintech/lab-k3s.git ~/dev/lab-k3s && cd ~/dev/lab-k3s
sudo bootstrap/00-install-k3s.sh     # k3s v1.36.5 pinned (Traefik + ServiceLB), ~/.kube/config, helm. Only sudo step.
export KUBECONFIG=$HOME/.kube/config  # k3s' kubectl otherwise tries the root-only /etc/rancher/k3s/k3s.yaml
bootstrap/10-secrets.sh              # namespaces + secrets; generates a Grafana password if the file has none
bootstrap/20-argocd.sh               # Argo CD via helm, then the root app-of-apps. main must already be on GitHub.
kubectl -n argocd get applications -w            # all Synced/Healthy in ~5 min; certs take 1-3 min (DNS-01)
scripts/udm-dns.sh ensure-lab        # LAN DNS on the UDM: *.lab + lab.kleincogroup.com -> 192.168.4.243
#   or: scripts/udm-dns-mongo.sh     # same via root SSH (no API credential needed; restarts the Network app ~1 min)
#   or by hand in the UniFi web UI:  Settings > Policy Engine > Policy Table > Create New Policy > DNS Record
curl -sS https://whoami.lab.kleincogroup.com/    # 200 with a valid cert = done
```

Claude Code integration comes with the dotfiles (`~/.claude/CLAUDE.md` section "The local
k3s lab", `~/.claude/skills/lab-k3s/SKILL.md`, `KUBECONFIG` export in
`~/.config/shell/common.sh`); nothing in this repo installs it.

Already-existing state that a rebuild does not recreate: the UDM records and the Cloudflare
tunnel / DNS / Access objects (they live on the UDM and in Cloudflare and survive the host),
and PVC data (registry images, Prometheus history, Grafana UI changes), see rebuild.md §0.

## Docs

- [docs/dns.md](docs/dns.md): `lab.kleincogroup.com`, split-horizon DNS on the UDM Pro, VLANs, `udm-dns.sh`
- [docs/cloudflare.md](docs/cloudflare.md): publishing a service with `expose.sh`, Access gating, the one-label limit
- [docs/rebuild.md](docs/rebuild.md): disaster recovery and backups
- [docs/ci.md](docs/ci.md): in-cluster GitHub Actions runners (`runs-on: lab-k3s`)
- [docs/observability.md](docs/observability.md): Prometheus / Grafana
- [templates/README.md](templates/README.md): onboarding a new project
