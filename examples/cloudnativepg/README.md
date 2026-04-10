# Cloud Native PostgreSQL on Kind

[CloudNativePG (CNPG)](https://cloudnative-pg.io/) is a Kubernetes operator that manages the full
lifecycle of a PostgreSQL cluster — provisioning, failover, backups, and upgrades — using a single
**Cluster** custom resource.

## Prerequisites

- Kind cluster is running (see `kind-config.yaml`)
- `helm` CLI installed
- `kubectl krew` installed (optional — for the `kubectl cnpg` plugin in step 6)

---

## 1. Install the CNPG operator

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update

helm install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system \
  --create-namespace
```

Wait for the operator pod to be ready:

```bash
kubectl rollout status deployment/cnpg-cloudnative-pg -n cnpg-system
```

---

## 2. Create the PostgreSQL cluster

```bash
kubectl apply -f examples/cloudnativepg/1-cluster.yaml
```

This creates a **3-instance** cluster (1 primary + 2 hot-standby replicas) with:
- database `appdb` owned by `appuser`
- 1 Gi of storage per instance
- Auto-generated credentials stored in Kubernetes Secrets

Wait until all three pods are running:

```bash
kubectl get pods -l cnpg.io/cluster=postgres-cluster --watch
```

You should see three pods reach the `Running` state. Check the overall cluster status:

```bash
kubectl get cluster postgres-cluster
```

The `STATUS` column should show `Cluster in healthy state` and `INSTANCES` should read `3`.

---

## 3. Inspect auto-created resources

CNPG creates three **Services** for different access patterns:

```bash
kubectl get svc -l cnpg.io/cluster=postgres-cluster
```

| Service | Type | Purpose |
|---------|------|---------|
| `postgres-cluster-rw` | ClusterIP | Read/write — primary only |
| `postgres-cluster-ro` | ClusterIP | Read-only — replicas only |
| `postgres-cluster-r`  | ClusterIP | Read — all instances |

It also creates **Secrets** for credentials and TLS:

```bash
kubectl get secret -l cnpg.io/cluster=postgres-cluster
```

| Secret | Contains |
|--------|----------|
| `postgres-cluster-app`         | `appuser` credentials for `appdb` |
| `postgres-cluster-ca`          | Cluster CA certificate |
| `postgres-cluster-server`      | Server TLS certificate |
| `postgres-cluster-replication` | Replication TLS certificate |

> **Note**: The `postgres` superuser Secret is **not** created by default in CNPG v1.22+.
> To enable it, add `enableSuperuserAccess: true` to the Cluster spec.

---

## 4. Connect to the cluster

Start a psql client pod:

```bash
kubectl apply -f examples/cloudnativepg/2-test-pod.yaml
kubectl wait pod/psql-client --for=condition=Ready
```

Extract the appuser password from the auto-generated Secret:

```bash
APP_PASSWORD=$(kubectl get secret postgres-cluster-app \
  -o jsonpath='{.data.password}' | base64 -d)
```

Connect to the **primary** (read-write):

```bash
kubectl exec -it psql-client -- \
  psql "host=postgres-cluster-rw dbname=appdb user=appuser password=$APP_PASSWORD"
```

---

## 5. Write and replicate data

Inside the psql session, create a table and insert a row:

```sql
CREATE TABLE greetings (
  id         serial PRIMARY KEY,
  message    text,
  created_at timestamptz DEFAULT now()
);

INSERT INTO greetings (message) VALUES ('Hello from CNPG!');
SELECT * FROM greetings;
```

Exit psql (`\q`), then verify the row is already available on a **replica**:

```bash
kubectl exec -it psql-client -- \
  psql "host=postgres-cluster-ro dbname=appdb user=appuser password=$APP_PASSWORD" \
  -c "SELECT * FROM greetings;"
```

Streaming replication copies every WAL record from the primary to all replicas in real time.

---

## 6. Operate the cluster with `kubectl cnpg`

The CNPG project ships a `kubectl` plugin that gives you a higher-level view of the cluster and
lets you trigger operator actions without writing YAML.

### Install the plugin

```bash
# via krew (recommended)
kubectl krew install cnpg

# or download a binary directly from GitHub releases
# https://github.com/cloudnative-pg/cloudnative-pg/releases
```

### Cluster status overview

```bash
kubectl cnpg status postgres-cluster
```

This prints a summary of the cluster: primary pod, replica lag, backup status, and any
conditions set by the operator — much more readable than `kubectl get cluster -o yaml`.

### Trigger an on-demand backup

CNPG supports two backup methods. The **barman-cloud plugin** method streams WAL and base
backups directly to object storage (S3, GCS, Azure Blob):

```bash
kubectl cnpg backup postgres-cluster \
  --method=plugin \
  --plugin-name=barman-cloud.cloudnative-pg.io
```

This creates a `Backup` resource — you can watch its progress:

```bash
kubectl get backup -l cnpg.io/cluster=postgres-cluster --watch
```

> **Note**: The barman-cloud plugin must be installed and the `Cluster` must have a
> `spec.backup.barmanObjectStore` (or a `BackupPlugin` configuration) pointing to your
> object store before this command succeeds. See the
> [CNPG backup documentation](https://cloudnative-pg.io/documentation/current/backup/) for setup.

### Other useful plugin commands

```bash
# Promote a specific replica to primary (planned switchover)
kubectl cnpg promote postgres-cluster postgres-cluster-2

# Reload postgresql.conf on all pods without a full restart
kubectl cnpg reload postgres-cluster

# Open a psql session directly (no separate client pod needed)
kubectl cnpg psql postgres-cluster

# Show logs from all cluster pods in one stream
kubectl cnpg logs cluster postgres-cluster
```

---

## How it works

```
kubectl apply -f 1-cluster.yaml
         │
         ▼
CNPG Operator (cnpg-system)
  watches Cluster CRD
         │
         ▼
Three PostgreSQL Pods
  postgres-cluster-1  (primary)  ──► postgres-cluster-rw  (ClusterIP, read/write)
  postgres-cluster-2  (replica)  ─┐
  postgres-cluster-3  (replica)  ─┴► postgres-cluster-ro  (ClusterIP, read-only)

WAL streaming replication flows primary → replicas continuously.
If the primary fails, CNPG elects the most up-to-date replica automatically.
```

### What the Cluster resource controls

| Field | What it does |
|-------|-------------|
| `instances` | Total pod count — 1 primary + (`instances - 1`) replicas |
| `storage.size` | PVC size attached to each pod |
| `bootstrap.initdb.database` | Initial database name created on first start |
| `bootstrap.initdb.owner` | Owner role — CNPG generates a matching credential Secret |
| `postgresql.parameters` | Any `postgresql.conf` knob (max_connections, etc.) |

---

## Troubleshooting

### Pods stuck in `Pending`

The storage class must support `ReadWriteOnce`. Check:

```bash
kubectl get pvc -l cnpg.io/cluster=postgres-cluster
kubectl describe pvc <pending-pvc-name>
```

Kind ships with the `standard` storage class (`rancher.io/local-path`) which is `ReadWriteOnce`
and works out of the box — no extra setup needed.

### Cluster reports `Switchover in progress`

A switchover is a planned leadership change triggered when you patch the Cluster resource
(e.g., changing `instances` or a PostgreSQL parameter). Wait a few seconds — CNPG completes it
automatically and returns to `Cluster in healthy state`.

### Replica rejects connections (`FATAL: the database system is starting up`)

The replica is still catching up with the primary after a restart. Wait until the pod is `Running`
and all 3 instances are healthy in `kubectl get cluster postgres-cluster`, then retry.

---

## Cleanup

```bash
kubectl delete -f examples/cloudnativepg/2-test-pod.yaml
kubectl delete -f examples/cloudnativepg/1-cluster.yaml
# PVCs are not deleted automatically — remove them explicitly
kubectl delete pvc -l cnpg.io/cluster=postgres-cluster
helm uninstall cnpg -n cnpg-system
kubectl delete namespace cnpg-system
```

---

> **Next steps**: CNPG also supports `ScheduledBackup` resources for automatic recurring backups,
> point-in-time recovery, TLS via cert-manager, and Prometheus metrics out of the box.
> See the [official CNPG documentation](https://cloudnative-pg.io/documentation/) for details.
