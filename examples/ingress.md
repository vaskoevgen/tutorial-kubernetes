# Ingress with NGINX on Kind

## Prerequisites

The `kind-config.yaml` must have `extraPortMappings` and the `ingress-ready=true` label on one worker node.
This is already configured — just make sure you use the provided `kind-config.yaml` when creating the cluster.

---

## 1. Add Helm repository

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update
```

---

## 2. Install ingress-nginx

The `nodeSelector` pins the ingress controller to the worker node that has `extraPortMappings` (port 80/443 forwarded to localhost):

```bash
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.hostPort.enabled=true \
  --set-string controller.extraArgs.update-status="true" \
  --set-string controller.nodeSelector."ingress-ready"="true" \
  --set-string controller.nodeSelector."kubernetes\.io/os"="linux"
```

Watch until the controller pod is Running:

```bash
kubectl get service --namespace ingress-nginx ingress-nginx-controller --output wide --watch
```

---

## 3. Add test.local to /etc/hosts

```bash
echo "127.0.0.1 test.local" | sudo tee -a /etc/hosts
```

> This only needs to be done once per machine.

---

## 4. Deploy the test app

```bash
kubectl apply -f examples/test-app-for-ingress/app.yaml
```

---

## 5. Test

Via curl:

```bash
curl -H "Host: test.local" http://localhost
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
