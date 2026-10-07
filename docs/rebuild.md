# Rebuilding the lab from a blank box

This runbook takes a fresh Ubuntu install (same host `notatonix`, or a replacement) back to
a working lab. Everything that runs on the cluster comes back from git through Argo CD. You
supply the secrets and whatever data lived on PVCs.

## 0. What git does *not* have

| item | where it lives | how it comes back |
|------|----------------|-------------------|
| `~/.config/lab-k3s/secrets.env` | notatonix only | your backup (Cloudflare token, Grafana admin, GitHub runner token) |
| `~/.config/lab-k3s/udm.env` | notatonix only | your backup, or create a new UniFi API key / local admin |
| `~/.config/cloudflare/api-token` | notatonix only | backup, or a new token (permissions: [cloudflare.md](cloudflare.md#api-token)) |
| `/etc/cloudflared/token` (tunnel `homelab` run token) | notatonix, root 0600 | backup, or fetch again from Cloudflare (step 5) |
| Registry images | PVC `registry/registry-data`, under `/var/lib/rancher/k3s/storage/` | re-run CI / `docker push`, or restore a tarball of the PV dir |
| Prometheus TSDB, Alertmanager state | PVCs in `monitoring` | not backed up; history starts over |
| Grafana DB (users, prefs, dashboards made in the UI) | PVC `monitoring/kube-prometheus-stack-grafana` | export dashboards to git (below) |
| Argo CD admin password | generated at install | new one printed by `bootstrap/20-argocd.sh` |
| UDM DNS records, Cloudflare tunnel/DNS/Access | the UDM and Cloudflare | survive a host rebuild; re-assert with the scripts (steps 4 and 5) |

All PVCs use k3s' `local-path` storage, so a lost disk means lost data. Back up what matters
to you before you need it (see "Backups" at the end).

## 1. Base OS

- Ubuntu with a user `jklein`, hostname `notatonix`.
- The UDM gives this box a fixed lease of **192.168.4.243**, keyed to
  the **Wi-Fi** NIC's MAC (`wlp4s0`; see the client in the UniFi app). Switching to the wired
  NIC (`enp5s0`) or to new hardware means a new MAC. Edit the fixed IP in the UniFi UI
  (Client → Settings → Fixed IP Address) or everything below points at the wrong address.
  `bootstrap/00-install-k3s.sh` assumes `NODE_IP=192.168.4.243`.
- Tools: `sudo apt install git curl jq dnsutils`. `docker` is for the dev loop and isn't
  needed by the cluster.

## 2. Clone and restore secrets

```
git clone https://github.com/kleintech/lab-k3s.git ~/dev/lab-k3s
install -d -m 700 ~/.config/lab-k3s ~/.config/cloudflare
# restore from backup, then:
chmod 600 ~/.config/lab-k3s/secrets.env ~/.config/lab-k3s/udm.env ~/.config/cloudflare/api-token
```

`bootstrap/secrets.env.example` lists the keys in `secrets.env`. The `udm.env` keys are in
[dns.md](dns.md#credentials-configlab-k3sudmenv-chmod-600-never-in-git).

## 3. Bootstrap the cluster

```
cd ~/dev/lab-k3s
sudo bootstrap/00-install-k3s.sh     # k3s + kubeconfig for jklein + helm
bootstrap/10-secrets.sh              # namespaces + secrets from secrets.env (no sudo)
export KUBECONFIG=$HOME/.kube/config # k3s' kubectl defaults to the root-only /etc/rancher/k3s/k3s.yaml
bootstrap/20-argocd.sh               # Argo CD via helm, then the root app-of-apps (no sudo; main must already be pushed)
```

If the root app stalls (waves are health-gated), the usual cause is certificate issuance:
`kubectl -n kube-system describe certificate` and `kubectl -n cert-manager logs deploy/cert-manager`.

Argo CD then syncs everything under `argocd/apps/` from `main`, in sync-wave order:
cert-manager, then issuers/certs, then the Traefik config, then everything else. Watch it:

```
kubectl -n argocd get applications -w
kubectl -n kube-system get certificate         # both wildcards READY=True (DNS-01 takes 1-3 min)
```

If `10-secrets.sh` generated a new Grafana password, it appended it to `secrets.env`.

## 4. LAN DNS

The UDM's records survive a host rebuild. Re-assert them anyway (idempotent):

```
scripts/udm-dns.sh ensure-lab        # *.lab.kleincogroup.com + lab.kleincogroup.com -> 192.168.4.243 (needs udm.env)
scripts/udm-dns-mongo.sh             # alternative with no API credential: root SSH, writes static_dns, restarts the Network app
scripts/udm-dns.sh list
dig +short whoami.lab.kleincogroup.com @192.168.4.1
curl -sI https://whoami.lab.kleincogroup.com   # 200 with a valid cert once Argo CD is synced
```

No API credential and no terminal? The UniFi web UI path (Network 10.x) is Settings > Policy
Engine > Policy Table > Create New Policy > DNS Record (not available in the mobile app).

## 4b. Claude Code integration

Lives in the dotfiles repo, not here: the "The local k3s lab" section of `~/.claude/CLAUDE.md`,
the skill `~/.claude/skills/lab-k3s/SKILL.md` (force-added; `.claude/skills` is otherwise
gitignored there) and the `KUBECONFIG` export in `~/.config/shell/common.sh`. A bootstrapped
box gets all three from `config pull`.

## 5. Cloudflare tunnel connector

The tunnel `homelab` and its config live in Cloudflare (remotely managed). Only the
connector has to be reinstalled:

1. Install `cloudflared` from Cloudflare's apt repo (<https://pkg.cloudflare.com/>).
2. Restore `/etc/cloudflared/token` (root:root, 0600). Without a backup, copy the token from
   the Zero Trust dashboard (Networks → Tunnels → `homelab` → configure; it's the long
   string in the install command). Cloudflare also documents an API call:
   `GET /accounts/{account}/cfd_tunnel/{tunnel-id}/token`. That call was not exercised
   while writing this.
3. Recreate the unit as it runs today, in `/etc/systemd/system/cloudflared.service`:
   ```
   [Unit]
   Description=Cloudflare Tunnel client
   After=network-online.target
   Wants=network-online.target

   [Service]
   TimeoutStartSec=15
   Type=notify
   ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token-file /etc/cloudflared/token
   Restart=on-failure
   RestartSec=5s

   [Install]
   WantedBy=multi-user.target
   ```
   Then `sudo systemctl daemon-reload && sudo systemctl enable --now cloudflared`.
   `--token-file` keeps the token out of `ps`. `cloudflared service install <token>` would
   put it on the command line instead.
4. The ingress rules come back with the connector (they're stored at Cloudflare). For each
   name that **`expose.sh` created** (CNAME comment `lab-k3s expose.sh ...`), re-assert the
   full set, including the UDM record: `scripts/expose.sh <name> --public` or
   `--gated --allow-email ...`. Don't do this for routes made by hand (other services on
   this host that the tunnel also serves). `expose.sh` refuses those unless you pass
   `--replace`, which would point them at Traefik.

Non-cluster services published through the same tunnel come back only when you restart
whatever listens on their port.

## 6. Data

- **Registry**: push images again (CI does it on the next run of each repo), or restore a
  tarball of the PV directory (below) before the registry pod first starts.
- **Grafana**: dashboards kept in git as ConfigMaps (label `grafana_dashboard: "1"`, see
  [observability.md](observability.md)) come back by themselves. Re-import UI-made ones from
  your export (below).

## 7. Done when

- `kubectl -n argocd get applications` is all Synced/Healthy.
- `https://argocd.lab.kleincogroup.com`, `https://grafana.lab.kleincogroup.com` and
  `https://registry.lab.kleincogroup.com/v2/` load from a LAN client without cert warnings.
- `systemctl is-active cloudflared` says active, and every exposed
  `https://<name>.kleincogroup.com` answers from off-LAN (e.g. a phone on cellular).
- CI runners register: `kubectl -n arc-runners get pods` after a workflow is queued
  ([ci.md](ci.md)).

## Backups worth taking

Secrets, which are tiny and essential. Put them somewhere encrypted that is not this box:

```
tar -C ~ -czf - .config/lab-k3s .config/cloudflare | gpg -c > lab-k3s-secrets-$(date +%F).tgz.gpg
sudo cat /etc/cloudflared/token | gpg -c > cloudflared-token-$(date +%F).gpg
```

Grafana dashboards made in the UI. Export them as JSON, then commit the ones you want to
keep as ConfigMaps. That beats backing up the SQLite DB. The password goes to curl on stdin,
never in argv:

```
GP="$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)"
G=https://grafana.lab.kleincogroup.com; mkdir -p grafana-export
gcurl() { printf 'user = "admin:%s"\n' "$GP" | curl -sf -K - "$@"; }
for uid in $(gcurl "$G/api/search?type=dash-db&limit=5000" | jq -r '.[].uid'); do
  gcurl "$G/api/dashboards/uid/$uid" | jq '.dashboard | .id = null' > "grafana-export/$uid.json"
done
```

To restore one without git (`gcurl` reads its config from stdin, so the body has to come
from a file):

```
jq '{dashboard: ., overwrite: true}' grafana-export/<uid>.json > /tmp/dash.json
gcurl -X POST -H 'Content-Type: application/json' --data-binary @/tmp/dash.json "$G/api/dashboards/db"
```

(This assumes the admin user is `admin`. If you set `GRAFANA_ADMIN_USER`, use that.)

fishmaps map history (PVC `fishmaps/fishmaps-data`, about 1 GB). NOAA only re-serves a few
days, so older history cannot be rebuilt. The pod can stay up; tar from inside it:

```
kubectl -n fishmaps exec deploy/fishmaps -- tar -C /data -czf - . > fishmaps-data-$(date +%F).tgz
```

Restore into a new PVC the same way, reversed:
`kubectl -n fishmaps exec -i deploy/fishmaps -- tar -C /data -xzf - < fishmaps-data-<date>.tgz`,
then `kubectl -n fishmaps rollout restart deploy/fishmaps` so the manifest is rescanned.

Registry images, only if rebuilding them is painful (stop the registry first so the copy is
consistent):

```
# Argo CD selfHeal would scale it straight back up: pause the root and registry apps first
# (see platform/registry/README.md for the full pause/resume recipe), then
kubectl -n registry scale deploy --all --replicas=0
sudo tar -C /var/lib/rancher/k3s/storage -czf registry-$(date +%F).tgz $(sudo ls /var/lib/rancher/k3s/storage | grep _registry_)
kubectl -n registry scale deploy --all --replicas=1
```

To restore: once Argo CD has created the PVC, pause the root and registry apps as above, scale the registry to 0, untar into
`/var/lib/rancher/k3s/storage/`, renaming the extracted directory to the new PV's
directory name (the PV name changes), then re-enable the root app's automated sync (selfHeal scales it back to 1).
