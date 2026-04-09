# Gateway API on Kind + MetalLB

The [Gateway API](https://gateway-api.sigs.k8s.io/) is the official successor to the Ingress API.
It separates routing concerns into three distinct resources — **GatewayClass**, **Gateway**, and **HTTPRoute** — giving you first-class support for cross-namespace routing, traffic splitting, and stronger RBAC, all without annotations.

> **Migration note**: If you are coming from the [ingress example](../ingress/README.md), see the [Migrating from Ingress](#migrating-from-ingress-with-ingress2gateway) section at the bottom for a step-by-step conversion using the `ingress2gateway` tool.

## Prerequisites

- Kind cluster is running (see `kind-config.yaml`)
- MetalLB is installed and configured (see [../metallb/README.md](../metallb/README.md))

---

## 1. Install Gateway API CRDs

The CRDs ship separately from any controller:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml
```

Verify:

```bash
kubectl get crd gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io
```

---

## 2. Install NGINX Gateway Fabric

NGINX Gateway Fabric is the NGINX implementation of the Gateway API spec.
Install it via Helm — the chart also creates the `GatewayClass` automatically:

```bash
helm install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  --namespace nginx-gateway \
  --create-namespace \
  --set service.type=LoadBalancer
```

Wait until the controller pod is running:

```bash
kubectl get pods -n nginx-gateway --watch
```

> In NGF v2.x the data plane (nginx) pod and its `LoadBalancer` service are provisioned
> dynamically when a `Gateway` resource is applied — not at install time.

---

## 3. Create the payment namespace

```bash
kubectl create namespace payment
```

---

## 4. Deploy test apps

```bash
kubectl apply -f examples/gateway-api/1-apps.yaml
```

This creates:
- `main-api` Deployment + `api-service` Service in the `default` namespace
- `payment` Deployment + `payment` Service in the `payment` namespace

---

## 5. Deploy the Gateway

```bash
kubectl apply -f examples/gateway-api/2-gateway.yaml
```

This creates the **Gateway** (declares an HTTP listener on port 80 that accepts routes from any namespace).
The `GatewayClass` named `nginx` was already created by the Helm chart.

Check it is `Programmed` and has received a MetalLB IP:

```bash
kubectl get gateway api-gateway -n nginx-gateway
kubectl get svc api-gateway-nginx -n nginx-gateway
# EXTERNAL-IP should show an IP from the MetalLB pool (e.g. 172.20.255.200)
# The exact IP depends on your Docker network subnet — see ../metallb/README.md
```

---

## 6. Deploy HTTPRoutes

```bash
kubectl apply -f examples/gateway-api/3-httproutes.yaml
```

This creates:
- A **ReferenceGrant** in the `payment` namespace — grants the `HTTPRoute` in `default` permission to reference the `payment` Service across namespaces
- An **HTTPRoute** in the `default` namespace — routes `/payment/webhooks/stripe` to the payment service and everything else to the main API

Check the route is accepted:

```bash
kubectl get httproute api-route -n default
```

---

## 7. Add api.local to /etc/hosts

```bash
LB_IP=$(kubectl get svc api-gateway-nginx -n nginx-gateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "$LB_IP api.local" | sudo tee -a /etc/hosts
```

---

## 8. Test

```bash
# Main API — catch-all rule
curl http://api.local/

# Stripe webhook — routes directly to the payment namespace
curl -X POST http://api.local/payment/webhooks/stripe
```

Expected responses:
- `/` → `Hello from main API service!`
- `/payment/webhooks/stripe` → `Hello from payment service — Stripe webhook received!`

---

## Platform notes

### Linux

Works out of the box. Docker runs natively so the Kind network (e.g. `172.18.x.x` or `172.20.x.x`
depending on your Docker installation) is directly routable from the host — MetalLB IPs are
reachable without any extra setup.

### macOS (Docker Desktop)

MetalLB IPs are inside Docker Desktop's Linux VM and are **not** routable from your Mac.
Use `kubectl port-forward` as a workaround:

```bash
kubectl port-forward -n nginx-gateway svc/api-gateway-nginx 8080:80
```

Then test with an explicit `Host` header:

```bash
curl -H "Host: api.local" http://localhost:8080/
curl -X POST -H "Host: api.local" http://localhost:8080/payment/webhooks/stripe
```

### macOS (Colima)

Start Colima with `--network-address` to give the VM a routable IP on your Mac,
then create the Kind cluster using Colima's Docker socket:

```bash
colima start --network-address --cpu 4 --memory 8
DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock" kind create cluster \
  --name tutorial-cluster --config kind-config.yaml
```

MetalLB IPs will then be reachable directly from your Mac — no port-forward needed.

---

## How it works

```
client
  │
  ▼
Gateway (nginx-gateway namespace)
  │  listener: HTTP :80  ←  MetalLB assigns a real external IP
  │
  ▼
HTTPRoute (default namespace)
  │
  ├─ POST /payment/webhooks/stripe  ──► Service/payment (payment namespace)
  │                                          │
  │       ReferenceGrant permits ◄───────────┘
  │       cross-namespace backendRef
  │
  └─ /*  (catch-all)               ──► Service/api-service (default namespace)
```

### Why this is better than the Ingress equivalent

| Concern | Ingress (old) | Gateway API (new) |
|---|---|---|
| Cross-namespace routing | ExternalName Service hack | Native `backendRef` + `ReferenceGrant` |
| Who owns the listener | Annotation on the Ingress | Separate `Gateway` resource (ops team) |
| Who owns the routes | Same Ingress (mixed concerns) | Separate `HTTPRoute` (app team) |
| RBAC | All-or-nothing | Per-resource — infra vs. app separation |
| Proxy tuning | Annotations (NGINX-specific) | Typed policy resources (portable) |

---

## Migrating from Ingress with ingress2gateway

[`ingress2gateway`](https://github.com/kubernetes-sigs/ingress2gateway) (v1.0) is the official
tool for converting existing Ingress resources to Gateway API resources. It translates 30+ NGINX
annotations and flags untranslatable configuration with clear warnings.

### Install

```bash
# Homebrew
brew install ingress2gateway

# or via Go
go install github.com/kubernetes-sigs/ingress2gateway@v1.0.0
```

### Convert from files

```bash
ingress2gateway print \
  --input-file examples/ingress/ingress.yaml \
  --providers=ingress-nginx
```

### Convert from a live cluster namespace

```bash
ingress2gateway print \
  --namespace default \
  --providers=ingress-nginx > gwapi.yaml
```

Review the output and any warnings before applying — the tool surfaces configuration that
could not be translated automatically so you can handle it manually.

---

## Cleanup

```bash
kubectl delete -f examples/gateway-api/3-httproutes.yaml
kubectl delete -f examples/gateway-api/2-gateway.yaml
kubectl delete -f examples/gateway-api/1-apps.yaml
kubectl delete namespace payment
helm uninstall ngf -n nginx-gateway
kubectl delete namespace nginx-gateway
kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml
```
