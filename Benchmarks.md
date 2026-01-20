# Running the benchmarks

## Accesses to Flink UI, Grafana, And Promotheus

We include, in the deployment scripts, the deployment of Ingresses to access the 3 desired services. They can be accessed via the following URLs.

- Prometheus: [prometheus.127.0.0.1.sslip.io](prometheus.127.0.0.1.sslip.io)
- Grafana: [grafana.127.0.0.1.sslip.io](grafana.127.0.0.1.sslip.io) (login: admin, password: prom-operator)
- Flink UI: [flink.127.0.0.1.sslip.io](flink.127.0.0.1.sslip.io)

The ingresses might not work in some setups. In that case, the easiest way to access those services is throw the Port-Forwarding capabilities of Kubernetes.
In separate terminals, run the following commands:
```bash
# Grafana
$ kubectl port-forward -n manager svc/prom-grafana 3000:80
```

```bash
# Prometheus
$ kubectl port-forward -n manager svc/prom-kube-prometheus-stack-prometheus 9090:9090
```

```bash
# Flink (make sure the service is running, i.e., after submitting the query)
$ kubectl port-forward svc/flink-rest 8081:8081
```

## Nexmark benchmarks
Open the [./notebooks/nexmark/xp.ipynb](http://localhost:8888/notebooks/notebooks/nexmark/xp.ipynb) notebook in your browser (make sure your jupyter server is still up and running, following the Requirements.md instruction).

Before continuing, make sure that the Flink image name in the following file is the same as the one you used during the build phase:
```yaml
apiVersion: flink.apache.org/v1beta1
kind: FlinkDeployment
metadata:
  name: flink
spec:
  image: flink-justin:dais <------- Your Flink image name
```
1. [./notebooks/motivation/read-only/query.yaml](./notebooks/nexmark/queryX/queryX.yaml), with X being the query number.

The notebook contains a cell for each query. These cells will execute the query twice, one with the default auto scaler, and one with the Justin auto scaler.

### Playing with Justin

As explained in the paper, Justin relies on multiple parameters such as a minimum cache hit rate and minimum state access latency.
These parameters can be modified via the YAML file of the query, namely the lines:
1. `job.autoscaler.cache-hit-rate.min.threshold: "0.8"` (ratio)
2. `job.autoscaler.state-latency.threshold: "1000000.0"` (nano seconds)

Note that changing those values can result in different scaling decisions.

Additionally, the reader can also modify the stabilization interval (`job.autoscaler.stabilization.interval`) and metric window (`job.autoscaler.metrics.window`).

### Modifying the Justin Policy.

The Justin policy is implemented in the Flink Kubernetes Operator's auto scaler module.
The reader can easily apply its own policy logic by modifying the [policy](https://github.com/CloudLargeScale-UCLouvain/flink-justin/blob/a3d6539d40668a92f910ea22adb15e7120884e8c/flink-kubernetes-operator/flink-autoscaler/src/main/java/org/apache/flink/autoscaler/ScalingExecutor.java#L567) method of the [ScalingExecutor.java](./flink-kubernetes-operator/flink-autoscaler/src/main/java/org/apache/flink/autoscaler/ScalingExecutor.java) file. 
The reviewer has access to previous Scaling Decisions (if any) through the `scaling` parameter.

Once modified, the image needs to be rebuilt and pushed to the nodes.
Delete the operator and its resources by executing the script `delete.sh` located in the `scripts`folder. This script will delete any Flink job pending, the operator, and the 3 custom resource definitions.
Once deleted, you can re-deploy the operator following the previous instructions.


## Motivation benchmarks
Open the [./notebooks/motivation/xp.ipynb](http://localhost:8888/notebooks/notebooks/motivation/xp.ipynb) notebook in your browser (make sure your jupyter server is still up and running, following the Requirements.md instruction).

Before continuing, make sure that the Flink image name in the following file is the same as the one you used during the build phase:
```yaml
apiVersion: flink.apache.org/v1beta1
kind: FlinkDeployment
metadata:
  name: flink
spec:
  image: flink-justin:dais <------- Your Flink image name
```
1. [./notebooks/motivation/read-only/query.yaml](./notebooks/motivation/read-only/query.yaml)
1. [./notebooks/motivation/write-only/query.yaml](./notebooks/motivation/write-only/query.yaml)
1. [./notebooks/motivation/update/query.yaml](./notebooks/motivation/update/query.yaml)
