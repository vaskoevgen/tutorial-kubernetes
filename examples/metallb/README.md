# MetalLB on Kind

MetalLB provides `LoadBalancer` support for bare-metal / local Kind clusters.
Without it, `Service` of type `LoadBalancer` stays `EXTERNAL-IP: <pending>` forever.

---

## 1. Install MetalLB

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml
```

Wait until pods are ready:

```bash
kubectl get pods -n metallb-system --watch
# controller and all speaker pods should be 1/1 Running
```

---

## 2. Configure IP address pool

Find the Docker bridge subnet:

```bash
docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
# e.g. 172.18.0.0/16
```

Apply the IP pool config using the upper range of that subnet:

```bash
kubectl apply -f examples/metallb/metallb-config.yaml
```

This creates:
- **`IPAddressPool`** — allocates IPs from `172.18.255.200–172.18.255.250`
- **`L2Advertisement`** — advertises IPs via ARP so they are reachable from your machine

---

## 3. Verify

Any `LoadBalancer` service now gets an `EXTERNAL-IP` if ingress-nginx is installed:

```bash
kubectl get svc -A | grep LoadBalancer
# EXTERNAL-IP should show 172.18.255.200 (not <pending>)
```

Test directly:

```bash
curl http://172.18.255.200
```

---

## How it works

```
Your machine
     │
     │  curl http://172.18.255.200
     ▼
MetalLB L2 (ARP)
     │  172.18.255.200 → tutorial-cluster-worker node
     ▼
ingress-nginx-controller (any worker node)
     │  matches Host header
     ▼
echo-service → echo-app pod
```

MetalLB's **speaker** pods (DaemonSet, one per node) respond to ARP requests for the assigned IP,
routing traffic to the node where the target service pod is running.

---

## Cleanup

```bash
kubectl delete -f examples/metallb/metallb-config.yaml
kubectl delete -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml
```
