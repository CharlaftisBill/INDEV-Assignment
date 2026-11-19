# Monitoring runbook

Design: [ADR 0010](../decisions/0010-monitoring-stack.md). Release `kps` in `monitoring`; node-exporter in `node-exporter`.

## Grafana access

Needs the `/etc/hosts` entry (`scripts/hosts-entry.sh --apply`). Open `https://grafana.local`, user `admin`; the certificate chains to `certs/ca.crt`.

The password is on the host in `.secrets/grafana-admin-password` (mode 0600, gitignored) and in Secret `grafana-admin`. Never print it into logs or chat. Copy it to the clipboard without showing it:

```bash
pbcopy < .secrets/grafana-admin-password
kubectl --kubeconfig out/admin.conf describe secret grafana-admin -n monitoring   # existence only, no values
```

To rotate: delete the file, then `make provision TAGS=monitoring` (a new one is generated and the Secret updated); restart Grafana so it reads it:

```bash
rm .secrets/grafana-admin-password
make provision TAGS=monitoring
kubectl --kubeconfig out/admin.conf rollout restart deployment/kps-grafana -n monitoring
```

The Grafana database (on `emptyDir`) keeps no state worth saving: dashboards are provisioned from ConfigMaps.

## Real alert demo

Proves a node alert and an etcd alert reach Alertmanager. Both are reversible. Alert rules wait `for:` minutes before firing. Run from the repo root.

Open Alertmanager in a second terminal:

```bash
kubectl --kubeconfig out/admin.conf port-forward -n monitoring svc/kps-alertmanager 9093:9093
```

Check with `curl -s localhost:9093/api/v2/alerts` or open `http://localhost:9093`.

### etcd: `etcdInsufficientMembers` (about 4 min)

Drop Prometheus's scrape of etcd metrics (pod CIDR to node port 2381) on the node:

```bash
limactl shell k8s -- sudo iptables -t raw -I PREROUTING -s 10.244.0.0/16 -p tcp --dport 2381 -j DROP
```

The etcd target goes down, then the alert fires. Undo:

```bash
limactl shell k8s -- sudo iptables -t raw -D PREROUTING -s 10.244.0.0/16 -p tcp --dport 2381 -j DROP
```

### node: `NodeNetworkInterfaceFlapping`

Flap a throwaway veth pair every 10 s for a few minutes:

```bash
limactl shell k8s -- sudo ip link add demo0 type veth peer name demo1
limactl shell k8s -- sudo ip link set demo0 up
limactl shell k8s -- sudo ip link set demo1 up
for i in $(seq 1 30); do
  limactl shell k8s -- sudo ip link set demo0 down
  sleep 10
  limactl shell k8s -- sudo ip link set demo0 up
  sleep 10
done
```

Undo (deleting one end removes both):

```bash
limactl shell k8s -- sudo ip link del demo0
```

Afterwards the alerts resolve within a few minutes, and `make verify REQ=6 STRICT=1` passes again.

## `check_6` fails while pods are restarting

After a provision, node reboot or Prometheus restart, the rollout and target checks can fail until pods are Ready and every target has been scraped once. Look, wait, re-run:

```bash
kubectl --kubeconfig out/admin.conf get pods -n monitoring
kubectl --kubeconfig out/admin.conf get pods -n node-exporter
make verify REQ=6 STRICT=1
```

Persistent failure: read the failing line; `targets not UP` names job and scrape URL (etcd, scheduler, controller-manager need the `kubeadm` role's bind-address settings, see [architecture](../architecture.md#control-plane-notes-kubeadm-role)). `check_6` needs `jq` on the Mac.

## Series grew: raise query caps and limits

Symptoms: dashboards or rules fail with "too many samples", or Prometheus is OOM-killed. In `ansible/roles/monitoring/defaults/main.yml`, keep this true (asserted by `check_6`):

`monitoring_query_max_concurrency x monitoring_query_overlap x monitoring_query_max_samples x monitoring_query_bytes_per_sample` fits `monitoring_query_headroom_mib`.

Current values: 2 concurrent x 2 overlap x 1.2M samples x 100 B = ~458Mi <= 500Mi. The 1280Mi Prometheus limit gives GOMEMLIMIT ~1152Mi (90%); the idle heap is ~600Mi, so ~500Mi is left for queries. Measured: a wide raw result costs ~85 B per sample per in-flight query, and the JSON is encoded after the query slot is freed, so queued queries overlap the running ones (hence the factor 2). `GOGC=50` (`monitoring_prometheus_gogc`) keeps garbage from floating the heap up to the limit: with the Go default 100, 8 parallel wide queries took the cgroup to 95% of the limit. `monitoring_query_max_samples` must stay above the largest rule window (~0.85M). To re-measure, run N parallel `query_range` calls for `{__name__=~".+"}` sized just under the cap while sampling the container cgroup's `memory.stat` (anon), `memory.current` and `memory.events`.

So raising `monitoring_query_max_samples` or concurrency needs a larger `monitoring_resources.prometheus.limits.memory` and headroom. The total must stay under `monitoring_budget_limits_mib` (3072, now 2880 used) and `monitoring_budget_requests_mib` (1536), or the llama.cpp pod will not fit. Then:

```bash
make provision TAGS=monitoring
make idempotency TAGS=monitoring
make verify REQ=6 STRICT=1
```
