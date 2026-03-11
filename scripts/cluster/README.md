# Justin Cluster Scripts

Scripts to set up and run the Justin Flink cluster on bare-metal (kubeadm).

## Cluster Layout

| Machine | Role | K8s Label |
|---------|------|-----------|
| **c180** | Control-plane, JobManager, Monitoring | `tier=jobmanager` |
| **c182** | Worker (TaskManager) | `tier=taskmanager` |
| **c167** | Worker (TaskManager) | `tier=taskmanager` |

Workers have a 512 GB SSD (`/dev/sdb`) mounted at `/data`.
RocksDB SSD experiments use `/data/flink/rocksdb`.

## Prerequisites

- Kubernetes 1.29 (kubeadm, kubelet, kubectl) on all nodes
- containerd 1.7.28 on all nodes
- Docker 28.x on c180
- Helm 3.19 on c180
- Local Docker registry at c180:5000
- SSH from c180 → workers

## Setup (run in order from c180)

```bash
./00-check-prereqs.sh          # Verify dependencies
./01-reset-cluster.sh          # Full k8s reset (or ./01b-soft-reset.sh for soft)
./02-label-nodes.sh            # Label nodes for JM/TM scheduling
./03-deploy-monitoring.sh      # Prometheus, Grafana, Loki, cert-manager
./04-build-images.sh           # Build flink-justin + operator images (~15 min)
./04b-build-nexmark-sql-image.sh  # Build SQL overlay image (if running SQL queries)
./05-deploy-operator.sh        # Deploy Flink K8s Operator via Helm
./06-generate-jobs.sh          # Generate job YAMLs from templates
```

## Configuration

All machine hostnames, image names/tags, paths, and chart versions live in
**`env.sh`**. Every other script sources it.

## Generating Jobs

`jobs/` is git-ignored. Run `06-generate-jobs.sh` to generate job YAMLs for
your environment.

### How it works

Templates live in `templates/`:

| Template | Description |
|----------|-------------|
| `nexmark-query{N}.yaml.template` | Per-query DataStream template (q1, q2, q3, q5, q8, q11) with its jar, args, and config |
| `nexmark-sql-job.yaml.template` | Shared template for all 13 SQL queries with `__QUERY__`, `__TPS__`, etc. placeholders |

Every template has two common placeholders:

- **`__FLINK_IMAGE__`** — replaced with `FLINK_IMAGE` (DataStream) or `FLINK_SQL_IMAGE` (SQL) from `env.sh`
- **`__JUSTIN_ENABLED__`** — set to `"true"` for `-justin` variants or `"false"` for `-ds2` variants

For SSD variants, a Python helper (`inject_ssd_config`) post-processes the
generated YAML to add `state.backend.rocksdb.localdir`, a `hostPath` volume,
and a `volumeMount` to the taskManager podTemplate.

### Modes

| Mode | Output files |
|---------|--------------------------------------------------------------|
| `default` | `queryX-ds2.yaml`, `queryX-justin.yaml` |
| `ssd` | `queryX-ssd-ds2.yaml`, `queryX-ssd-justin.yaml` |
| `sql` | `qX-sql-ds2.yaml`, `qX-sql-justin.yaml` |
| `sql-ssd` | `qX-sql-ssd-ds2.yaml`, `qX-sql-ssd-justin.yaml` |
| `all` | All of the above (default) |

Combine modes: `./06-generate-jobs.sh default sql`

### Options

| Env var | Default | Description |
|---------|---------|-------------|
| `CLEAN` | `false` | Delete all `.yaml` in `jobs/` first |
| `FORCE_REGENERATE` | `false` | Overwrite existing files |
| `SSD_HOST_PATH` | `/data/flink/rocksdb` | Host path for SSD on workers |

### Examples

```bash
./06-generate-jobs.sh                             # everything
./06-generate-jobs.sh default sql                 # DataStream + SQL, no SSD
./06-generate-jobs.sh ssd sql-ssd                 # SSD variants only
CLEAN=true ./06-generate-jobs.sh                  # wipe and regenerate
FORCE_REGENERATE=true ./06-generate-jobs.sh sql   # overwrite SQL jobs
SSD_HOST_PATH=/mnt/nvme ./06-generate-jobs.sh ssd # custom SSD path
```

## Running Experiments

Submit a job with `run-job.sh`. It applies the YAML, waits for pods, and
starts a Flink UI port-forward automatically.

```bash
./run-job.sh jobs/query5-justin.yaml
./run-job.sh jobs/query5-ssd-ds2.yaml
./run-job.sh jobs/q20_unique-sql-justin.yaml
```

Once the job is up, in a **separate terminal** run `./07-port-forward.sh` to
access Grafana and Prometheus locally.

Useful watch commands:

```bash
kubectl get flinkdeployment -w -o wide
kubectl get pods -o wide -w
```

To stop a job:

```bash
kubectl delete -f jobs/query5-justin.yaml
```

To stop the current in-cluster Flink deployment and free local port `8081`
without uninstalling the operator:

```bash
./09-stop-flink.sh
```

### Between Experiment Runs

Redeploy the operator for a clean state:

```bash
./05b-redeploy-operator.sh
```

### Observing Scaling Decisions

```bash
./08-observe-scaling.py              # latest scaling config
./08-observe-scaling.py --follow     # poll every 30s
./08-observe-scaling.py --json       # JSON output
```

### DS2 vs Justin

Every query has two variants:
- `-ds2` — default DS2 autoscaler (`justin.enabled: false`)
- `-justin` — Justin autoscaler (`justin.enabled: true`)

SSD variants add `-ssd-` to the name (e.g., `query5-ssd-justin.yaml`).

### Tuning Parameters

Adjust in the generated YAML (or edit the template):
- `job.autoscaler.cache-hit-rate.min.threshold` — ratio (default `"0.8"`)
- `job.autoscaler.state-latency.threshold` — nanoseconds (default `"1000000.0"`)
- `job.autoscaler.stabilization.interval` — default `"1m"`
- `job.autoscaler.metrics.window` — default `"2m"`

## Monitoring

`./07-port-forward.sh` forwards all three UIs:

| Service | URL | Credentials |
|---------|-----|-------------|
| Flink UI | http://c180:8081 | — |
| Grafana | http://c180:3001 | admin / prom-operator |
| Prometheus | http://c180:9091 | — |

## Utility

```bash
./status.sh                          # cluster status at a glance
./09-stop-flink.sh                   # stop only the in-cluster Flink deployment
bash /opt/flink-justin/scripts/delete.sh  # tear down operator + jobs
```
