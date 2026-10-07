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

No Alertmanager receivers are configured yet, so alerts show up only in the Alertmanager UI and in Grafana.
`Watchdog` (and sometimes `InfoInhibitor`) is **always** firing on purpose. It is a dead-man's switch
that proves the alert pipeline works.

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
