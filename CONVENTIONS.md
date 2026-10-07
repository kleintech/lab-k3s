# lab-k3s conventions (read before adding anything)

Single-node k3s on `notatonix` (Ubuntu 26.04, 16 cores / 30 GiB, 192.168.4.243 on the
fixed DHCP lease, UDM Pro gateway at 192.168.4.1). Everything that runs on
the cluster is declared in this repo and reconciled by Argo CD from branch `main`.
The repo is on GitHub at `kleintech/lab-k3s`. **No secrets in this repo, ever.**

## Domain and TLS

- Internal lab domain: **`lab.kleincogroup.com`**. Every internal service is
  `<name>.lab.kleincogroup.com`. (Not `.local`: Let's Encrypt cannot issue for `.local`,
  and `.local` collides with mDNS on macOS/Linux, so it could never meet the
  "no browser cert errors" requirement.)
- The UDM Pro answers `*.lab.kleincogroup.com` -> `192.168.4.243` for the LAN
  (split-horizon). Public DNS has no record for `*.lab.kleincogroup.com`.
- Services exposed to the Internet get a **one-level** public name `<name>.kleincogroup.com`
  (Cloudflare Universal SSL only covers one level). The UDM also answers that name with
  `192.168.4.243`, so one link works on the LAN (direct) and off it (Cloudflare tunnel).
- cert-manager issues two wildcard certs by DNS-01 through Cloudflare, both in
  namespace `kube-system`:
  - secret `wildcard-lab-kleincogroup-com` for `*.lab.kleincogroup.com`
  - secret `wildcard-kleincogroup-com` for `*.kleincogroup.com`
  Traefik's default `TLSStore` serves them, so an Ingress needs **no** `secretName`:

  ```yaml
  spec:
    ingressClassName: traefik
    tls:
      - hosts: [whoami.lab.kleincogroup.com]
    rules:
      - host: whoami.lab.kleincogroup.com
        http: {paths: [{path: /, pathType: Prefix, backend: {service: {name: whoami, port: {number: 80}}}}]}
  ```
  HTTP is redirected to HTTPS at the Traefik entrypoint.

## Ingress controller

k3s' bundled Traefik (deployed by k3s' helm-controller from a `HelmChart` CR). Customise it
only through the `HelmChartConfig` named `traefik` in `kube-system`
(`platform/traefik/`). ServiceLB (klipper) binds :80/:443 on the node IP.

## Argo CD layout (app-of-apps)

- `argocd/root-app.yaml` - the root `Application`; it syncs `argocd/apps/`.
- `argocd/apps/<name>.yaml` - one `Application` (or `ApplicationSet`) per component,
  all in project `default`, destination the in-cluster API, `automated: {prune: true,
  selfHeal: true}`, `syncOptions: [CreateNamespace=true, ServerSideApply=true]`.
- Helm charts: multi-source Application - the chart from its upstream repo plus
  `$values/platform/<name>/values.yaml` from this repo. Pin chart versions.
- Plain manifests: `platform/<name>/manifests/` (directory source, `recurse: true`).
- Sync waves: cert-manager (-3) -> issuers/certs (-2) -> traefik config (-1) -> everything else (0).
- Workload apps live in `apps/<name>/` with the same pattern, Application in `argocd/apps/`.

## Namespaces

| namespace      | what                                   |
|----------------|----------------------------------------|
| argocd         | Argo CD                                |
| cert-manager   | cert-manager                           |
| kube-system    | traefik, wildcard certs, TLSStore      |
| registry       | in-cluster OCI registry                |
| monitoring     | kube-prometheus-stack (Grafana at grafana.lab.kleincogroup.com) |
| arc-systems    | Actions Runner Controller              |
| arc-runners    | GitHub runner scale sets               |
| dev-<project>  | throwaway dev deploys done by Claude   |
| <project>      | "prod" (internal) deploys via Argo CD  |

## Secrets

Created once by `bootstrap/10-secrets.sh` from `~/.config/lab-k3s/secrets.env`
(not in git; `bootstrap/secrets.env.example` lists the keys). Charts reference them by
these exact names:

| namespace    | secret name              | keys                     | used by                  |
|--------------|--------------------------|--------------------------|--------------------------|
| cert-manager | cloudflare-api-token     | api-token                | ClusterIssuer (DNS-01)   |
| monitoring   | grafana-admin            | admin-user, admin-password | Grafana                |
| arc-runners  | github-runner-token      | github_token             | ARC runner scale sets    |
| registry     | (none; LAN-only, TLS by Traefik)                                               |

## Images

In-cluster registry at `registry.lab.kleincogroup.com` (TLS via wildcard cert, so no
insecure-registry config anywhere). Dev loop: `docker build -t registry.lab.kleincogroup.com/<proj>/<img>:<tag> . && docker push ...`.
CI pushes there too.

## Storage

k3s `local-path` StorageClass (default), data under `/var/lib/rancher/k3s/storage`.
