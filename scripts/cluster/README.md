# Justin Cluster Setup Scripts

Repeatable scripts to set up and manage the Justin Flink cluster on bare-metal
machines using **kubeadm** (not Kind, not Grid5000).

## Cluster Layout

| Machine | Role | K8s Label |
|---------|------|-----------|
| **c180** | Control-plane, JobManager, Monitoring | `tier=jobmanager` |
| **c182** | Worker – TaskManager pods | `tier=taskmanager` |
| **c167** | Worker – TaskManager pods | `tier=taskmanager` |

## Prerequisites (already installed)

- Kubernetes 1.29 (kubeadm, kubelet, kubectl) on all 3 machines
- containerd 1.7.28 on all machines
- Docker 28.x on c180 (for building images)
- Helm 3.19 on c180
- Local Docker registry on c180:5000
- SSH access from c180 → c182, c167

## Script Execution Order

Run these **in order** from c180 (`/opt/flink-justin/scripts/cluster/`):

```
# 0. Verify all dependencies are present
./00-check-prereqs.sh

# 1. CHOOSE ONE:
./01-reset-cluster.sh     # Full reset: tears down k8s and reinitializes
./01b-soft-reset.sh       # Soft reset: keeps k8s, removes Flink/monitoring

# 2. Label nodes for scheduling
./02-label-nodes.sh

# 3. Deploy Prometheus, Grafana, Loki, cert-manager
./03-deploy-monitoring.sh

# 4. Build Docker images (flink-justin + operator) — ~15 min
./04-build-images.sh

# 4b. Build the Nexmark SQL overlay image
./04b-build-nexmark-sql-image.sh

# 5. Deploy the Flink Kubernetes Operator via Helm
./05-deploy-operator.sh

# 6. Generate ready-to-submit query YAML files
./06-prepare-jobs.sh

# 7. (Optional) Start port-forwarding for UIs
./07-port-forward.sh
```

## Configuration

Edit **`env.sh`** to change:
- Machine hostnames and IPs
- Docker image names and tags
- Helm chart versions
- File paths

## Running Experiments

After all scripts complete, query YAML files are in `scripts/cluster/jobs/`:

```bash
# Submit a Nexmark query with Justin autoscaler enabled
kubectl apply -f jobs/query5-justin.yaml

# Submit a Nexmark SQL query with Justin autoscaler enabled
kubectl apply -f jobs/q20_unique-sql-justin.yaml

# Watch the deployment
kubectl get flinkdeployment -w

# Watch pods
kubectl get pods -w

# Access Flink UI
kubectl port-forward svc/flink-rest 8081:8081

# Delete the job when done
kubectl delete -f jobs/query5-justin.yaml
```

### DS2 vs Justin

Each query has two variants:
- `queryX-ds2.yaml` — Uses the default DS2 autoscaler (`justin.enabled: false`)
- `queryX-justin.yaml` — Uses the Justin autoscaler (`justin.enabled: true`)
- `qX-sql-ds2.yaml` / `qX-sql-justin.yaml` — Runs the curated SQL query set via `com.github.nexmark.flink.sql.SqlQueryJob` on the dedicated `flink-justin-sql` overlay image

### SQL Jobs

`06-prepare-jobs.sh` also generates SQL CRs for:
`q20`, `q20_unique`, `q9`, `q9_unique`, `q4`, `q4_unique`, `q18`, `q19`, `q1`, `q3`, `q5`, `q8`, `q11`.

Build the SQL overlay image first with `./04b-build-nexmark-sql-image.sh`. That script compiles
`nexmark-v2` and layers `nexmark-flink-0.3-SNAPSHOT.jar` onto the base `flink-justin` image without
rebuilding the entire Flink distribution. By default it also pre-pulls the SQL image onto
`c180`, `c182`, and `c167` so the first SQL job does not stall in `ContainerCreating` while the
nodes fetch the image. Set `PREPULL_SQL_IMAGE=false` to skip that step.

By default these use `--tps 10000` and `--events 0`; override them when generating by exporting
`NEXMARK_SQL_TPS` and `NEXMARK_SQL_EVENTS` before running the script.

Generated files are not overwritten on subsequent runs. If you want to rebuild them from source,
run `FORCE_REGENERATE=true ./06-prepare-jobs.sh`.

### Justin Tuning Parameters

In the query YAML files, you can adjust:
- `job.autoscaler.cache-hit-rate.min.threshold: "0.8"` (ratio)
- `job.autoscaler.state-latency.threshold: "1000000.0"` (nanoseconds)
- `job.autoscaler.stabilization.interval: "1m"`
- `job.autoscaler.metrics.window: "2m"`

## Utility Scripts

```bash
# Check cluster status at a glance
./status.sh

# Tear down just the Flink operator + jobs
bash /opt/flink-justin/scripts/delete.sh
```

## Monitoring Access

| Service | Port-forward command | URL | Credentials |
|---------|---------------------|-----|-------------|
| Grafana | `kubectl port-forward -n manager svc/prom-grafana 3000:80` | http://c180:3000 | admin / prom-operator |
| Prometheus | `kubectl port-forward -n manager svc/prom-kube-prometheus-stack-prometheus 9090:9090` | http://c180:9090 | — |
| Flink UI | `kubectl port-forward svc/flink-rest 8081:8081` | http://c180:8081 | — |
