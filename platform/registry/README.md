# In-cluster registry

Docker Distribution (`registry:3.1.2`, pinned by digest in `manifests/deployment.yaml`),
namespace `registry`, served at `https://registry.lab.kleincogroup.com` by Traefik with the
wildcard cert. Images live on the `registry-data` PVC (30Gi, local-path), i.e. under
`/var/lib/rancher/k3s/storage/` on notatonix.

```sh
docker build -t registry.lab.kleincogroup.com/<proj>/<img>:<tag> .
docker push registry.lab.kleincogroup.com/<proj>/<img>:<tag>
curl -s https://registry.lab.kleincogroup.com/v2/_catalog
```

There is **no authentication**. Anyone who can reach the LAN name can push, pull and delete.
It is not published through the Cloudflare tunnel and must stay that way unless auth is added.

## Large pushes

Traefik puts no limit on request body size. Its entrypoint `readTimeout` defaults to 60s,
though, and it covers the whole request body, so a slow layer upload would be cut off.
`platform/traefik/manifests/helmchartconfig.yaml` sets it to `0` (no limit) on `web` and
`websecure`. Keep it that way.

The `registry-data` PVC carries `argocd.argoproj.io/sync-options: Prune=false,Delete=false`.
local-path deletes the data together with the claim, so Argo must never prune it.

## Deleting images and garbage collection (manual, on purpose)

Deletes are enabled (`REGISTRY_STORAGE_DELETE_ENABLED=true`). Deleting a manifest only unlinks it.
Disk space comes back only after `registry garbage-collect` runs.

There is **no GC CronJob**. Upstream says GC must not run while the registry accepts writes:
a blob uploaded during the mark phase can be swept, which leaves a corrupt image. Making it safe
from a CronJob means stopping the registry (scale to 0, plus RBAC to let the job do that) or
switching it to `storage.maintenance.readonly.enabled` and restarting. Either way the job edits a
resource Argo CD owns, and selfHeal fights it. That isn't trivially safe, so run it by hand:

```sh
# 1. stop writers. The root app self-heals argocd/apps/registry.yaml, so pause it first,
#    then the registry app, then scale down and wait for the pod to go away.
kubectl -n argocd patch application root     --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl -n argocd patch application registry --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl -n registry scale deploy/registry --replicas=0
kubectl -n registry wait --for=delete pod -l app.kubernetes.io/name=registry --timeout=120s
# 2. run GC in a one-off pod against the same PVC (dry run first, then drop --dry-run)
kubectl -n registry run registry-gc --rm -i --restart=Never --image=registry:3.1.2@sha256:ddf754342cfc8acc51a56d5d0ab6af06826461864460636d8bd5c546dab2a7b8 \
  --overrides='{"apiVersion":"v1","spec":{"securityContext":{"runAsUser":1000,"runAsGroup":1000},"containers":[{"name":"registry-gc","image":"registry:3.1.2@sha256:ddf754342cfc8acc51a56d5d0ab6af06826461864460636d8bd5c546dab2a7b8","stdin":true,"command":["registry","garbage-collect","--delete-untagged","--dry-run","/etc/distribution/config.yml"],"volumeMounts":[{"name":"data","mountPath":"/var/lib/registry"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"registry-data"}}]}}'
# 3. restore: re-enabling the root app's sync puts registry.yaml back (automated sync on),
#    and that app's selfHeal scales the Deployment back to 1.
kubectl -n argocd patch application root --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

(`--delete-untagged` also removes manifests no tag points at. Drop it if you push by digest only.)
