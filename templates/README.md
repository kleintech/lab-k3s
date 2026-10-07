# Project templates

Starter files for a new project that builds a container image, runs CI on the lab cluster and
deploys through Argo CD. Copy them into the project repo and replace the placeholders; nothing
here is deployed from this repo.

## `app/`

| file | goes to | what |
|---|---|---|
| `Dockerfile` | project root | multi-stage Node example (deps -> build -> slim runtime, non-root, port 8080) |
| `k8s/` | project `k8s/` | Deployment, Service, Ingress at `<name>.lab.kleincogroup.com`, Kustomization |
| `.github/workflows/ci.yaml` | project `.github/workflows/` | test -> build -> push to `registry.lab.kleincogroup.com`, on `runs-on: lab-k3s` |
| `argocd-application.yaml` | **this** repo: `argocd/apps/<name>.yaml` | the "prod" Argo CD Application pointing at the project's `k8s/` |

Placeholders: `myapp` = service name (also the prod namespace and hostname), `myproject` =
project / image namespace in the registry, `kleintech/myproject` = GitHub repo. Find them all
with `grep -rn 'myapp\|myproject' .`.

## Using them

```bash
cp -r ~/dev/lab-k3s/templates/app/. ~/dev/<project>/   # note the /. so .github is copied
cd ~/dev/<project>
grep -rln 'myapp\|myproject' Dockerfile k8s .github argocd-application.yaml \
  | xargs sed -i 's/myapp/<name>/g; s/myproject/<project>/g'
mv argocd-application.yaml ~/dev/lab-k3s/argocd/apps/<name>.yaml   # when ready for prod
```

1. **CI**: add `- repo: <github-repo>` to `argocd/apps/arc-runners.yaml` in this repo, add the
   repo to the runner token's repository access, push (see `docs/ci.md`). Then pushes and PRs
   run `test` and `build`; images land at
   `registry.lab.kleincogroup.com/<project>/<name>:<git-sha>` (plus `:main` on main).
2. **Dev deploy** (throwaway): set `newTag` in `k8s/kustomization.yaml` to a pushed SHA, then
   `kubectl create ns dev-<project>; kubectl -n dev-<project> apply -k k8s/`.
   Delete the namespace when done.
3. **Prod deploy**: commit the SHA tag in `k8s/kustomization.yaml` in the project repo, and the
   Application (`argocd/apps/<name>.yaml` here) in this repo. Argo CD syncs both from `main`.
   The commented `deploy` job in `ci.yaml` automates the tag bump on every push to main.

## Notes

- The Ingress has no `secretName` on purpose: Traefik serves the wildcard cert by default
  (`CONVENTIONS.md`). Hosts outside `*.lab.kleincogroup.com` / `*.kleincogroup.com` get no
  valid cert.
- The registry has no auth and is LAN-only, so GitHub-hosted runners cannot push to it; CI has
  to run on `lab-k3s`.
- Keep the Dockerfile's `USER` numeric: the Deployment sets `runAsNonRoot`, and the kubelet
  rejects a named user it cannot verify.
- A private project repo needs an Argo CD repository credential before the Application can sync
  (see the comment in `argocd-application.yaml`).
