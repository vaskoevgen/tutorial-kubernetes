# Ingress with NGINX on Kind + MetalLB

## Prerequisites

- Kind cluster is running (see `kind-config.yaml`)
- MetalLB is installed (see [../metallb/metallb.md](../metallb/metallb.md))

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
kubectl apply -f examples/ingress/app.yaml
```

---

## 5. Enable HTTPS (TLS)

To secure the ingress with HTTPS, generate a self-signed certificate and store it in a Kubernetes Secret:

```bash
# 1. Generate a self-signed certificate for test.local
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt -subj "/CN=test.local/O=test.local"

# 2. Create a Kubernetes Secret containing the certificate
kubectl create secret tls test-local-tls --key tls.key --cert tls.crt

# 3. Clean up the local files
rm tls.key tls.crt
```

The provided `app.yaml` is already configured to use the `test-local-tls` secret.

---

## 6. Test

Via curl (using `-k` to accept the self-signed warning):

```bash
curl -k https://test.local
```

Via browser — open: **https://test.local/** (you will likely need to bypass a browser security warning because the certificate is self-signed).

Expected response: `Hello from KIND Cluster!`

---

## Cleanup

```bash
# Remove test app
kubectl delete -f examples/ingress/app.yaml

# Remove ingress controller
helm delete ingress-nginx -n ingress-nginx
```
