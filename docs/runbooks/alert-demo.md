# Fire a real node alert and etcd alert

Shows that a node alert and an etcd alert reach Alertmanager. Both steps can be undone.
Alerts wait a few minutes (`for:`) before they fire. Run from the repo root.
Background: [ADR 0010](../decisions/0010-monitoring-stack.md).

## Watch Alertmanager

In a second terminal:

```bash
kubectl --kubeconfig out/admin.conf port-forward -n monitoring svc/kps-alertmanager 9093:9093
```

Then open `http://localhost:9093`, or run `curl -s localhost:9093/api/v2/alerts`.

## etcd alert: `etcdInsufficientMembers` (about 4 minutes)

Block Prometheus from reading etcd metrics (pod network → node port 2381):

```bash
limactl shell k8s -- sudo iptables -t raw -I PREROUTING -s 10.244.0.0/16 -p tcp --dport 2381 -j DROP
```

The etcd target goes down, then the alert fires. Undo:

```bash
limactl shell k8s -- sudo iptables -t raw -D PREROUTING -s 10.244.0.0/16 -p tcp --dport 2381 -j DROP
```

## Node alert: `NodeNetworkInterfaceFlapping`

Create a throwaway network link and switch it off and on every 10 seconds, for a few minutes:

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

## After

The alerts clear within a few minutes. Then this passes again:

```bash
make verify REQ=6 STRICT=1
```
