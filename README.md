# JUSTIN

This repository contains the code of Justin along with instructions on how to reproduce the results presented in the paper.

The experiments were conducted on the [Grid5000](https://www.grid5000.fr/w/Grid5000:Home) grid, but we also include instructions to run Justin in a local environment using Kind.

## Local environment
The simplest way to test Justin is to deploy a local cluster.
Please read the following instructions to deploy a cluster, build the project, and run the experiments.
1. [Requirements.md](./Requirements.md) contains the instructions to install the required tools, namely Jupyter Notebook, Kind, Helm, and Kubectl.
At the end of the instructions, you will also be able to build the JARs of Flink and the Flink Kubernetes Operator using Docker.
2. Next, read the [instructions](./Deployment.md) on how to deploy a local cluster and install the required services (Prometheus, Grafana, ...).
3. Finally, [Benchmarks.md](./Benchmarks.md) contains the instructions on how to run the motivation and macro benchmarks

## ~~Grid5000~~

:warning: Grid5000 Recently changed their available distributions when reserving nodes. The Terraform modules used by Justin (i.e., the Grid5000 reservation module, and the Grid5000 Kubernetes deployment module) are currently broken and require an update from the original author. 
While we are looking for an alternative, please use the local environment with Kind to use Justin.

~~We assume the reader has access to the grid.
Please read the following instructions to deploy a cluster, build the project, and run the experiments.~~
1. ~~[Requirements_g5k.md](./Requirements_g5k.md) contains the instructions to install the required tools, namely Terraform, Helm, and Kubectl.
At the end of the instructions, you will also be able to build the JARs of Flink and the Flink Kubernetes Operator using Docker.~~
2. ~~Next, read the [instructions](./Deployment_g5k.md) on how to deploy cluster using Terraform and install the required services (Prometheus, Grafana, ...).~~
3. ~~Finally, [Benchmarks_g5k.md](./Benchmarks_g5k.md) contains the instructions on how to run the motivation and macro benchmarks~~