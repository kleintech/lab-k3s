# Observability

kube-prometheus-stack in namespace `monitoring`. It runs Prometheus, Alertmanager, Grafana,
node-exporter, kube-state-metrics and prometheus-operator. Argo CD deploys it
(`argocd/apps/monitoring.yaml`, chart version pinned there), and the values are in
`platform/monitoring/values.yaml`.

## Grafana

- URL: <https://grafana.lab.kleincogroup.com> (LAN; wildcard cert, no browser warning).
- User: `admin`, unless you set `GRAFANA_ADMIN_USER` in the secrets file.
- Password: `GRAFANA_ADMIN_PASSWORD` in `~/.config/lab-k3s/secrets.env` on notatonix.
  `bootstrap/10-secrets.sh` generates one if it's missing and stores it in the secret
  `monitoring/grafana-admin`. To read it back from the cluster:

  ```sh
  kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
  ```

  To change it, edit `secrets.env` and re-run `bootstrap/10-secrets.sh`. Grafana reads
  the secret **only when it first creates its database**, so you also have to reset the stored
  password. Until you do, Grafana's dashboard/datasource sidecars (which log in with the
  secret) get 401s:

  ```sh
  kubectl -n monitoring exec deploy/kube-prometheus-stack-grafana -c grafana -- \
    grafana cli admin reset-admin-password \
    "$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)"
  kubectl -n monitoring rollout restart deploy/kube-prometheus-stack-grafana
  ```

  Changing `GRAFANA_ADMIN_USER` later does not rename the existing admin either. Do that in the UI.

The Prometheus datasource and the standard Kubernetes/node dashboards are provisioned for you.
To add a dashboard, put a ConfigMap labelled `grafana_dashboard: "1"` in any namespace, with
the dashboard JSON as a data key. Grafana's sidecar loads it.

Prometheus and Alertmanager have no ingress. Use a port-forward:

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093
```

`Watchdog` (and sometimes `InfoInhibitor`) is **always** firing on purpose. It is a dead-man's switch
that proves the alert pipeline works.

## Alerts by email

Alertmanager emails alerts to kleintech@gmail.com through Gmail SMTP
(`alertmanager.config` in `platform/monitoring/values.yaml`). Every alert is sent except
`severity: info`, `Watchdog` and `InfoInhibitor`. That includes alerts with no severity
label, so give a new rule `severity: info` if it should stay quiet. Alerts are grouped by alert name and namespace.
A group that is still firing is re-sent every 4h if critical and every 12h if warning, and
you get a second email when it resolves.

On top of the chart's default rules, `additionalPrometheusRulesMap` in the same file adds
the `Lab*` rules:

| alert | severity | fires when |
|---|---|---|
| LabDiskUsageHigh / Critical | warning / critical | a real filesystem is over 80% (15m) / 90% (5m) used. Kubelet image GC starts at 85% and eviction at 95% |
| LabMemoryLow / Critical | warning / critical | MemAvailable under 10% (10m) / 5% (3m) |
| LabMemoryThrashing | critical | over 60s of memory PSI "full" stall (every task waiting on memory) within 10 minutes |
| LabSwapInHigh | warning | over 1000 pages/s (~4 MB/s) swapped in for 10m |
| LabOOMKill | warning | the kernel OOM-killed any process in the last 15m |
| LabNodePressure | critical | node has DiskPressure / MemoryPressure / PIDPressure |
| LabArgoAppUnhealthy / OutOfSync | warning | an Argo CD app is not Healthy for 20m / not Synced for 30m |
| LabCertificateExpiring / NotReady | warning | a cert-manager certificate has under 14 days left / is not Ready for 1h |

Host alerts use `keep_firing_for`, so a value hovering around a threshold produces one alert,
not a flapping series. Overlaps are inhibited (critical disk silences high disk and the
chart's `NodeFilesystem*` alerts on the same mountpoint; critical memory / thrashing silences
low memory and swap-in). The chart's `NodeMemoryHighUtilization` is disabled as a duplicate of
`LabMemoryLow`.

The Argo CD and cert-manager rules depend on their ServiceMonitors (`controller.metrics` in
`platform/argocd/values.yaml`, `prometheus.additionalServiceMonitors` in `platform/monitoring/values.yaml`, kept out of the cert-manager chart so a rebuild's wave -3 doesn't need the ServiceMonitor CRD).

**SMTP credential.** Set `ALERTMANAGER_SMTP_PASSWORD` in `~/.config/lab-k3s/secrets.env` to a
Gmail app password for kleintech@gmail.com. Creating one needs 2-Step Verification: go to
<https://myaccount.google.com/apppasswords>. Then run `bootstrap/10-secrets.sh`, which creates
`monitoring/alertmanager-smtp`. Alertmanager reads the file at send time, so a new password is
picked up without a restart (allow ~1 min for the kubelet to refresh the mounted secret).
The secret volume is `optional`, so if the secret is missing, Alertmanager still runs and only
email sending fails.

**Test email.** Fire a synthetic alert through Alertmanager:

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093 &
curl -s -XPOST localhost:9093/api/v2/alerts -H 'Content-Type: application/json' -d \
  '[{"labels":{"alertname":"LabTestAlert","severity":"warning"},"annotations":{"summary":"test"}}]'
```

The email arrives after `group_wait` (1 min). If it doesn't, check
`kubectl -n monitoring logs alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager | grep -i notify`.

**Limitation.** Every alert comes from inside the box. If notatonix loses power, the network
drops, or k3s dies, no email is sent. Detecting that needs an external check-in, such as `Watchdog` → healthchecks.io.
That is not set up yet.

## Scraping your app (ServiceMonitor)

Prometheus selects **every** ServiceMonitor, PodMonitor, PrometheusRule, Probe and ScrapeConfig in **any**
namespace. No `release:` label is needed. Expose metrics on a named Service port and add the
following next to your app's manifests:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: myapp
  namespace: myapp            # the app's namespace
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: myapp   # labels on the *Service*
  endpoints:
    - port: metrics           # the Service port *name*, not the number
      path: /metrics
      interval: 30s
```

Check it under Prometheus → Status → Targets (`serviceMonitor/myapp/myapp/0`). If the target
is missing, the selector doesn't match the Service labels or the port name is wrong.

If an Argo CD app ships a ServiceMonitor, add `SkipDryRunOnMissingResource=true` to its
`syncOptions`. Its first sync can then run before the monitoring CRDs exist, and the retry
picks it up later.

## Where data lives and how long it is kept

All three volumes are local-path PVCs, so the data is under
`/var/lib/rancher/k3s/storage/` on notatonix (one directory per PV). local-path does **not**
enforce PVC sizes; they're bookkeeping. Prometheus is bounded by its `retentionSize`; the
others are small.

| what         | PVC (namespace monitoring)                                      | size | retention |
|--------------|-----------------------------------------------------------------|------|-----------|
| Prometheus   | `prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0` | 20Gi | 15 days, or 17GB, whichever is hit first |
| Alertmanager | `alertmanager-kube-prometheus-stack-alertmanager-db-alertmanager-kube-prometheus-stack-alertmanager-0` | 2Gi | silences/notification log, 120h |
| Grafana      | `kube-prometheus-stack-grafana`                                  | 5Gi  | until deleted (SQLite DB: users, UI-made dashboards) |

Run `kubectl -n monitoring get pvc` to see the real names. Retention settings are in
`platform/monitoring/values.yaml` (`prometheus.prometheusSpec.retention` / `retentionSize`).

## Control-plane metrics on k3s

k3s runs every control-plane component in one process with one metrics registry. The kubelet
and apiserver endpoints therefore already carry scheduler, controller-manager and kube-proxy
metrics. Their separate endpoints are bound to localhost, and single-node k3s uses SQLite,
not etcd. So the chart's dedicated etcd/scheduler/controller-manager/kube-proxy jobs, rules
and dashboards are disabled in the values. Without that, their "down" alerts would fire all
the time. The kubelet job drops its duplicate `apiserver_*`/`etcd_*` series. The `apiserver`
job keeps them.
