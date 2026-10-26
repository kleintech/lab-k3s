# Scheduling: keeping CI from stomping on everything else

One node, so "isolation" means deciding who gets squeezed first when memory or disk runs
out, and who may push whom aside to get scheduled. `platform/scheduling/` defines four
PriorityClasses; every platform component references one.

| class | value | who | notes |
|---|---|---|---|
| `system-*-critical` | 2e9 | k3s itself: coredns, traefik, metrics-server, local-path | set by k3s |
| `lab-critical` | 1,000,000 | Argo CD, cert-manager | what repairs the rest |
| `lab-platform` | 500,000 | Prometheus, Alertmanager, Grafana, operator, exporters, registry, ARC controller + listeners | |
| `lab-workload` | 100,000 | **default** for every pod without a class: prod and dev apps | `globalDefault: true` |
| `lab-ci` | 0 | GitHub Actions runner pods | `preemptionPolicy: Never` |

## What this buys

- **Node-pressure eviction** (kubelet, when free memory < 1Gi or disk < 5%): pods using more
  than they request go first, ordered by priority. Runners request 1Gi and burst to GBs, so
  they are always the first to go. A dev app is next, then platform, then Argo CD, and k3s
  system pods last. The kubelet also keeps 10Gi back for the host (`system-reserved`, in
  `bootstrap/00-install-k3s.sh`), so the desktop is not what runs out.
- **Scheduler preemption**: when a pending pod cannot fit by *requests*, the scheduler may
  evict lower-priority pods to make room. Runners never do this (`preemptionPolicy: Never`);
  anything else may evict a runner. With small requests on a 30 GiB node this rarely
  triggers; eviction is the mechanism that actually fires.
- **Hard caps**: each runner container is limited to 8Gi memory and 4 CPU (LimitRange in
  `arc-runners`), and at most 3 runners per repo run at once (`maxRunners`). CI therefore
  cannot take more than ~24 GiB / 12 cores even in theory, and in practice is evicted long
  before that.

## PodDisruptionBudgets

Single-replica services have `minAvailable: 1` PDBs: Argo CD (server, repo-server,
controller, redis), Traefik, Prometheus, Alertmanager, registry. On one node a PDB does
**not** stop node-pressure eviction or an OOM kill; it only blocks *voluntary* disruption
through the eviction API (`kubectl drain`, a descheduler, a future k3s node upgrade). That
is the intent: nothing automated may take those pods down. It also means `kubectl drain
notatonix` will hang; use `--disable-eviction` if you really mean it.

## For app authors

Do nothing: pods get `lab-workload` automatically. Set `priorityClassName: lab-platform`
only for something other services depend on. Never use `lab-critical` or `system-*` for an
app. Set realistic memory **requests** on app pods: eviction picks on pods that exceed their
request before it looks at priority, so an app that requests 64Mi and uses 2Gi is treated
like a runner.

Priority is read when a pod is created, so pods that existed before this change keep
`<none>` until they are recreated (`kubectl -n <ns> rollout restart deploy/<name>`).
