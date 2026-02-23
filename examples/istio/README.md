# Istio Installation Guide

This guide explains how to install Istio on your local multi-node `kind` cluster.

## Prerequisites

- A running `tutorial-kubernetes` cluster (3 control-plane, 2 worker nodes).
- `kubectl` configured to communicate with your cluster.
- `curl` installed on your local machine.

## Method 1: The Easiest Way (`istioctl`)

This is the recommended method for tutorials and local testing. It installs the `istioctl` CLI and uses the `demo` profile.

### 1. Download and Extract Istio

```bash
curl -L https://istio.io/downloadIstio | sh -
```

This script will download the latest Istio package and extract it into a directory named `istio-<version>` (e.g., `istio-1.20.0`).

### 2. Add `istioctl` to Your Path

Navigate to the extracted directory and add the `bin` folder to your system's PATH.

```bash
cd istio-*
export PATH=$PWD/bin:$PATH
```

### 3. Install Istio with the `demo` Profile

The `demo` profile is designed for evaluating Istio. It installs the Istio core, `istiod` (control plane), and both ingress and egress gateways.

```bash
istioctl install --set profile=demo -y
```

### 4. Enable Automatic Sidecar Injection

To make Istio automatically inject Envoy proxy sidecars into your application pods, you need to label the namespace where your applications will run. For the `default` namespace:

```bash
kubectl label namespace default istio-injection=enabled
```

After labeling the namespace, any new pods created in the `default` namespace will automatically get an Istio sidecar proxy.

## Method 2: The Production Way (Helm)

If you prefer using Helm (which is often better for GitOps and infrastructure-as-code), follow these steps.

### 1. Add the Istio Helm Repository

```bash
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update
```

### 2. Create the Istio System Namespace

```bash
kubectl create namespace istio-system
```

### 3. Install the Istio Base Chart

This installs cluster-wide Custom Resource Definitions (CRDs).

```bash
helm install istio-base istio/base -n istio-system --set defaultRevision=default
```

### 4. Install the Istio Discovery Chart (`istiod`)

This deploys the Istio control plane.

```bash
helm install istiod istio/istiod -n istio-system --wait
```

### 5. Install the Ingress Gateway (Optional but Recommended)

For handling incoming traffic to your cluster:

```bash
kubectl create namespace istio-ingress
helm install istio-ingressgateway istio/gateway -n istio-ingress --wait
```

## Verifying the Installation

Regardless of which method you chose, you can verify that Istio is installed and running correctly:

```bash
kubectl get pods -n istio-system
```

You should see pods like `istiod` and `istio-ingressgateway` (if installed) in a `Running` state.

## Testing Istio Routing

We have included a sample application to demonstrate Istio's traffic routing capabilities. This example uses `hashicorp/http-echo` to deploy two versions (`v1` and `v2`) of a simple web server, along with an Istio `Gateway` and a `VirtualService` configured to split traffic 50/50 between the two versions.

### 1. Deploy the Application and Routing Rules

Assuming your `default` namespace is labeled with `istio-injection=enabled`:

```bash
kubectl apply -f examples/istio/test-app.yaml
kubectl apply -f examples/istio/istio-routing.yaml
```

### 2. Verify Pods are Running with Sidecars

Check the pods in the default namespace. You should see `2/2` under the `READY` column, indicating that the Envoy sidecar container was successfully injected alongside your application container:

```bash
kubectl get pods
```

### 3. Determine the Ingress IP and Port

To access the application from outside the cluster, we need the IP address of the `istio-ingressgateway`.

```bash
kubectl get svc istio-ingressgateway -n istio-system
```

If you are using MetalLB (as set up in `examples/metallb`), your ingress gateway will get an `EXTERNAL-IP`.

```bash
export INGRESS_HOST=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
export INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')
export GATEWAY_URL=$INGRESS_HOST:$INGRESS_PORT
```

*Note: If `EXTERNAL-IP` is `<pending>`, you may need to configure MetalLB first or access it via `NodePort`.*

### 4. Test the Traffic Routing

Send multiple requests to the Gateway URL (e.g. `172.18.255.200` from MetalLB). Because the `VirtualService` is configured for a 50/50 split, you should see the responses alternating roughly evenly between "hello from version 1" and "hello from version 2":

```bash
for i in {1..10}; do curl -s "http://172.18.255.200/"; echo; done
```

### Alternative: Testing via Port-Forwarding

If your `EXTERNAL-IP` remains `<pending>`, you can test the routing by port-forwarding the ingress gateway to your local machine:

```bash
kubectl port-forward svc/istio-ingressgateway -n istio-system 8080:80
```

Then, in a separate terminal window, send requests to `localhost:8080`:

```bash
for i in {1..10}; do curl -s "http://127.0.0.1:8080/"; echo; done
```

You should see an output similar to this:

```text
hello from version 2
hello from version 1
hello from version 2
hello from version 2
hello from version 1
hello from version 1
...
```
