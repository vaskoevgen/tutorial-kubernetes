# Ingress with NGINX on Kind + MetalLB

## Prerequisites

- Kind cluster is running (see `kind-config.yaml`)
- MetalLB is installed (see [metallb.md](metallb.md))

---

## 1. Add Helm repository

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update
```

---

## 2. Install ingress-nginx

```bash
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set-string controller.extraArgs.update-status="true"
```

Wait until the controller gets an `EXTERNAL-IP` from MetalLB:

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller --watch
# EXTERNAL-IP should change from <pending> to 172.18.255.200
```

---

## 3. Add test.local to /etc/hosts

Get the MetalLB-assigned IP and add it to `/etc/hosts`:

```bash
LB_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "$LB_IP test.local" | sudo tee -a /etc/hosts
```

> This only needs to be done once per machine (or when LB IP changes).

---

## 4. Deploy the test app

```bash
kubectl apply -f examples/test-app-for-ingress/app.yaml
```

---

## 5. Test

Via curl:

```bash
curl http://test.local
```

Via browser — open: **http://test.local/**

Expected response: `Hello from KIND Cluster!`

---

## Cleanup

```bash
# Remove test app
kubectl delete -f examples/test-app-for-ingress/app.yaml

# Remove ingress controller
helm delete ingress-nginx -n ingress-nginx
```
