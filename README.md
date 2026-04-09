# Kubernetes Tutorial: multi-node kind cluster

This tutorial explains how to start and manage a local Kubernetes cluster using `kind` (Kubernetes IN Docker). The cluster configuration uses **3 master (control-plane) nodes** and **2 worker nodes**, based on `kind` cluster documentation.

## Prerequisites
- [Docker](https://docs.docker.com/get-docker/) installed and running
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) CLI installed
- [kubectl](https://kubernetes.io/docs/tasks/tools/) CLI installed

## Using the Cluster

### 1. Starting the Cluster
A helper script is provided to start the cluster using the `kind-config.yaml` file.

```bash
# Make the script executable
chmod +x start_cluster.sh

# Run the script to create the cluster
./start_cluster.sh
```
This process may take a few minutes as it pulls the necessary Docker images and provisions the nodes.

### 2. Verifying the Nodes
Once the cluster is up and running, you can ensure all 5 nodes are present and `Ready` by running:
```bash
kubectl get nodes
```
You should see 3 nodes labeled as `control-plane` and 2 unlabeled or labeled as `<none>` which act as your workers.

### 3. Deleting the Cluster
After you have finished the tutorial or your experiments, you can clean up the resources:

```bash
# Make the delete script executable
chmod +x delete_cluster.sh

# Run the script to delete the cluster
./delete_cluster.sh
```
This will remove the `kind` Docker containers and clean up your `kubeconfig`.

---

## Examples & Documentation

Explore the `examples/` directory for detailed guides on working with this cluster:

*   **[MetalLB Setup](examples/metallb/README.md)**: How to configure bare-metal LoadBalancer support for Kind so your services get real IPs.
*   **[Ingress with NGINX](examples/ingress/README.md)**: How to deploy an ingress controller, route traffic using MetalLB, and configure path-based routing across namespaces (including raw webhook forwarding).
*   **[Kubernetes Volumes](examples/volumes/README.md)**: How to use `emptyDir` and `PersistentVolumeClaim` (PVC) for pods and deployments.
*   **[etcd deep dive](examples/README.md)**: How to check etcd health, list HA members, and perform backup & restore operations. (Note: The `etcd-backup.db` file generated during the tutorial is ignored by Git to prevent accidentally committing sensitive cluster state).
*   **[Istio Service Mesh](examples/istio/README.md)**: How to install Istio, configure automatic sidecar injection, and test traffic routing functionality.
