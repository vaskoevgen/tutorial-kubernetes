# CloudNativePG Backups on KIND with MinIO

This guide sets up automated PostgreSQL backups on a local KIND cluster using:

- **MinIO** — S3-compatible object storage running inside the cluster
- **barman-cloud plugin** — CNPG's plugin for WAL archiving and base backups
- **ScheduledBackup** — CNPG resource that triggers backups on a cron schedule

---

## Prerequisites

- CNPG operator installed and `postgres-cluster` running (see `README.md`)
- barman-cloud plugin deployed in `cnpg-system`
- `kubectl cnpg` plugin installed

---

## Architecture

```
postgres-cluster (primary)
    │  WAL archiving (continuous)
    │  base backup (scheduled)
    ▼
barman-cloud plugin (cnpg-system)
    │  S3 API
    ▼
MinIO (minio namespace)
    └── postgres-backups/  (bucket)
```

---

## 1. Deploy MinIO

```bash
kubectl apply -f examples/cloudnativepg/3-minio.yaml
kubectl rollout status deployment/minio -n minio
```

This creates:
- A `minio` namespace with a PVC-backed MinIO instance (5 Gi)
- A `minio` Service exposing the S3 API on port `9000` and the web console on `9001`

Create the backup bucket:

```bash
kubectl run mc-setup --image=quay.io/minio/mc --restart=Never \
  --command -- sh -c \
  "mc alias set local http://minio.minio.svc:9000 minioadmin minioadmin && mc mb local/postgres-backups"
kubectl wait pod/mc-setup --for=condition=Ready --timeout=30s
kubectl logs mc-setup
kubectl delete pod mc-setup
```

---

## 2. Create the ObjectStore and credentials

```bash
kubectl apply -f examples/cloudnativepg/4-objectstore.yaml
```

This creates:
- **`s3-creds`** — Secret with MinIO access/secret keys
- **`my-objectstore`** — `ObjectStore` resource pointing to `s3://postgres-backups/` via MinIO

---

## 3. Fix barman-cloud plugin TLS (KIND only)

On a local KIND cluster the CNPG operator does not auto-generate the plugin TLS secrets.
Create them manually using the CNPG CA:

```bash
mkdir -p /tmp/barman-tls && cd /tmp/barman-tls

# Extract CNPG CA
kubectl get secret cnpg-ca-secret -n cnpg-system \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
kubectl get secret cnpg-ca-secret -n cnpg-system \
  -o jsonpath='{.data.ca\.key}' | base64 -d > ca.key

# Server cert
openssl genrsa -out server.key 2048
openssl req -new -key server.key -subj "/CN=barman-cloud.cnpg-system.svc" \
  -addext "subjectAltName=DNS:barman-cloud,DNS:barman-cloud.cnpg-system.svc,DNS:barman-cloud.cnpg-system.svc.cluster.local" \
  -out server.csr
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 3650 -sha256 \
  -extfile <(echo "subjectAltName=DNS:barman-cloud,DNS:barman-cloud.cnpg-system.svc,DNS:barman-cloud.cnpg-system.svc.cluster.local") \
  -out server.crt

# Client cert
openssl genrsa -out client.key 2048
openssl req -new -key client.key -subj "/CN=barman-cloud-client" -out client.csr
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 3650 -sha256 -out client.crt

# Create secrets
kubectl create secret tls barman-cloud-server-tls \
  -n cnpg-system --cert=server.crt --key=server.key

kubectl create secret generic barman-cloud-client-tls \
  -n cnpg-system \
  --from-file=tls.crt=client.crt \
  --from-file=tls.key=client.key \
  --from-file=ca.crt=ca.crt

# Bounce the plugin pod to pick up the new secrets
kubectl delete pod -n cnpg-system -l app=barman-cloud
kubectl rollout status deployment/barman-cloud -n cnpg-system
```

> **Note**: This is a workaround for KIND. In production clusters (EKS, GKE, etc.) with cert-manager
> installed, the CNPG operator manages these certs automatically. The certs must be **self-signed**
> (not signed by the CNPG CA), matching what cert-manager's `selfSigned` issuer would generate.
> The secret type must be `kubernetes.io/tls`.

---

## 4. Enable the plugin on the cluster

Patch the `postgres-cluster` to reference the barman-cloud plugin and ObjectStore:

```bash
kubectl patch cluster postgres-cluster --type=merge -p '{
  "spec": {
    "plugins": [{
      "name": "barman-cloud.cloudnative-pg.io",
      "parameters": {
        "barmanObjectName": "my-objectstore"
      }
    }]
  }
}'
```

---

## 5. Enable scheduled backups

```bash
kubectl apply -f examples/cloudnativepg/5-scheduled-backup.yaml
```

This creates a `ScheduledBackup` that runs every hour. Adjust the `schedule` field (standard
6-field cron: `seconds minutes hours day month weekday`) to fit your needs.

---

## 6. Trigger and verify a manual backup

```bash
# Trigger immediately
kubectl cnpg backup postgres-cluster \
  --method=plugin \
  --plugin-name=barman-cloud.cloudnative-pg.io

# Watch progress
kubectl get backup -l cnpg.io/cluster=postgres-cluster --watch
```

A successful backup shows `PHASE: completed`.

Verify the data landed in MinIO:

```bash
kubectl run mc-check --image=quay.io/minio/mc --restart=Never \
  --command -- sh -c \
  "mc alias set local http://minio.minio.svc:9000 minioadmin minioadmin && mc ls -r local/postgres-backups/"
kubectl logs mc-check
kubectl delete pod mc-check
```

---

## How it works

```
Cluster reconciliation loop (every 5 min WAL archive timeout)
  ├─ WAL segments → barman-cloud plugin → MinIO (continuous)
  └─ ScheduledBackup fires → base backup → MinIO (hourly)

Backup object in Kubernetes tracks:
  - phase (running / completed / failed)
  - start / stop time
  - backup ID (used for PITR)
```

---

## Cleanup

```bash
kubectl delete -f examples/cloudnativepg/5-scheduled-backup.yaml
kubectl delete -f examples/cloudnativepg/4-objectstore.yaml
kubectl delete -f examples/cloudnativepg/3-minio.yaml
kubectl delete secret barman-cloud-server-tls barman-cloud-client-tls -n cnpg-system
kubectl delete secret s3-creds
kubectl delete pvc minio-data -n minio
```

Remove the plugin from the cluster (reverts to no backup config):

```bash
kubectl patch cluster postgres-cluster --type=merge -p '{"spec":{"plugins":[]}}'
```
