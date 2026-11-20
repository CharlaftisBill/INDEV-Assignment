# Prometheus memory and query limits

Read this when dashboards or rules fail with "too many samples", or Prometheus is killed for using too much memory.
Background: [ADR 0010](../decisions/0010-monitoring-stack.md).

## The rule

All settings are in `ansible/roles/monitoring/defaults/main.yml`. This must stay true (`check_6` asserts it):

```
monitoring_query_max_concurrency × monitoring_query_overlap × monitoring_query_max_samples
  × monitoring_query_bytes_per_sample  ≤  monitoring_query_headroom_mib
```

Today: 2 queries × 2 overlap × 1.2M samples × 100 B ≈ 458 MiB ≤ 500 MiB.

## Why these numbers

- Prometheus's limit is 1280 MiB. Go aims to stay under 90% of it (`GOMEMLIMIT` ≈ 1152 MiB).
- Prometheus uses about 600 MiB when idle. That leaves about 500 MiB for queries.
- Measured: a wide raw result costs about 85 B per sample per running query. We count 100 B.
- Overlap is 2: the JSON answer is built after the query slot is freed, so waiting queries run alongside it.
- `GOGC=50` (`monitoring_prometheus_gogc`) frees memory sooner. With Go's default of 100, 8 parallel wide queries
  pushed memory to 95% of the limit.
- `monitoring_query_max_samples` must stay above the largest rule window (about 0.85M samples).

## Series and label APIs

`--query.*` does not cover `/api/v1/series` or the label APIs, and Prometheus 3.15 has no server-side default for their `limit=`.
Grafana sends `monitoring_grafana_series_limit` (5000) as `limit`. An unbounded call (admin only) costs about 700 B of heap per
series: ~100 MiB at 147k series, so 4 in parallel fit and 8 can OOM-kill Prometheus. Always pass `limit=` when calling it by hand.

## Raise the limits

Raising `monitoring_query_max_samples` or concurrency needs a bigger
`monitoring_resources.prometheus.limits.memory` and headroom. The monitoring total must stay under
`monitoring_budget_limits_mib` (3072; 2880 used) and `monitoring_budget_requests_mib` (1536), or the llama.cpp pod
won't fit on the node. Then:

```bash
make provision TAGS=monitoring
make idempotency TAGS=monitoring
make verify REQ=6 STRICT=1
```

## Measure again

Run N parallel `query_range` calls for `{__name__=~".+"}`, each just under the sample limit. Meanwhile, read the
Prometheus container's cgroup files: `memory.stat` (anon), `memory.current` and `memory.events`.
