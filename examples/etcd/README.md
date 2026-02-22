# etcd in Kubernetes

etcd is a distributed key-value store that Kubernetes uses as its **single source of truth**.
Every cluster object (pods, deployments, secrets, configmaps, etc.) is stored in etcd.

> This cluster runs **etcd v3.6.6**. Some commands differ from older versions — see notes below.

---

## What is etcd?

| Property | Detail |
|---|---|
| **Type** | Distributed key-value store |
| **Protocol** | Raft consensus (leader + followers) |
| **Port** | `2379` (client), `2380` (peer) |
| **Location** | Runs as a static pod on every control-plane node |
| **Data** | All Kubernetes objects, their state and configuration |

> 💡 If etcd goes down, `kubectl` stops working — the API server cannot read or write cluster state.

---

## 1. Check etcd Health

### Single endpoint

```bash
kubectl exec -n kube-system etcd-tutorial-cluster-control-plane -- \
  etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  endpoint health
```

### All control-plane endpoints (HA cluster)

```bash
kubectl exec -n kube-system etcd-tutorial-cluster-control-plane -- \
  etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  endpoint status --write-out=table
```

Output shows: **IS LEADER**, **RAFT TERM**, **RAFT INDEX** — use this to identify which node is the leader.

### Check logs for errors

```bash
kubectl logs -n kube-system etcd-tutorial-cluster-control-plane
```

---

## 2. List etcd Members (HA cluster)

In a cluster with 3 control-plane nodes, etcd forms a **3-member cluster**:

```bash
kubectl exec -n kube-system etcd-tutorial-cluster-control-plane -- \
  etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  member list --write-out=table
```

> 💡 **Quorum rule:** With 3 members, cluster tolerates **1 failure**.
> With 5 members → tolerates **2 failures**. Always use an **odd number** of etcd nodes.

---

## 3. Backup etcd

**Always back up etcd before upgrades, major changes, or on a schedule.**

### Create and copy snapshot to your local machine (Kind-specific)

> ⚠️ In Kind, the etcd container has **no `cp` or `tar`** binaries, and `docker cp` can sometimes hang.
> The most reliable way is to save the snapshot to the shared `/var/lib/etcd` directory, then copy it to your host machine using `docker exec`.

```bash
# Step 1 — Save the snapshot to the shared volume mount
kubectl exec -n kube-system etcd-tutorial-cluster-control-plane -- \
  etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  snapshot save /var/lib/etcd/etcd-backup.db

# Step 2 — Copy from the kind node to your current directory
docker exec tutorial-cluster-control-plane cat /var/lib/etcd/etcd-backup.db > ./etcd-backup.db

# Step 3 — Verify the file
ls -lh etcd-backup.db
```

> ⚠️ **etcd v3.6 note:** `etcdctl snapshot status` was **removed** in etcd v3.6.
> Use `ls -lh etcd-backup.db` to verify the file exists and has a non-zero size.


---

## 4. Restore etcd

> ⚠️ **Restore is destructive** — it replaces all cluster data. Only do this in a recovery scenario.
>
> 💡 **HA Cluster Note:** In a multi-node HA cluster (like this tutorial), restoring a snapshot is complex: you must stop etcd on **all** control-plane nodes, restore the snapshot to a new data directory on **every** node using its specific IP address, and start them all together. The procedure below demonstrates a simpler **single-node** restore for learning purposes.

### Step 1 — Stop the API server and etcd

```bash
# On the primary control-plane node (tutorial-cluster-control-plane)
docker exec tutorial-cluster-control-plane bash -c "
  mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
  mv /etc/kubernetes/manifests/etcd.yaml /tmp/
"
```

### Step 2 — Restore from snapshot using containerd

> Because Kind nodes do not have `etcdctl` installed on the host OS, we must use `ctr` to run the restore tool from the official etcd container image.

```bash
docker exec tutorial-cluster-control-plane bash -c "
  rm -rf /var/lib/etcd-restore
  ctr -n k8s.io run --rm \\
    --mount type=bind,src=/var/lib,dst=/var/lib,options=rbind:rw \\
    registry.k8s.io/etcd:3.6.6-0 restore-task \\
    etcdutl snapshot restore /var/lib/etcd/etcd-backup.db \\
    --data-dir=/var/lib/etcd-restore \\
    --name=tutorial-cluster-control-plane \\
    --initial-cluster=tutorial-cluster-control-plane=https://172.18.0.3:2380 \\
    --initial-advertise-peer-urls=https://172.18.0.3:2380 \\
    --initial-cluster-token=etcd-cluster-1
"
```
*(Note: `172.18.0.3` is typically the IP of the first Kind node. Verify with `docker inspect` if this fails).*

### Step 3 — Update etcd to use restored data

```bash
# Edit the etcd static pod manifest to point to new data dir
docker exec tutorial-cluster-control-plane bash -c "
  sed -i 's|/var/lib/etcd|/var/lib/etcd-restore|g' /tmp/etcd.yaml
  sed -i 's/--initial-cluster-state=existing/--initial-cluster-state=new/g' /tmp/etcd.yaml
"
```

### Step 4 — Restore the manifests

```bash
docker exec tutorial-cluster-control-plane bash -c "
  mv /tmp/etcd.yaml /etc/kubernetes/manifests/
  mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
"
```

### Step 5 — Verify cluster recovered

```bash
kubectl get nodes
kubectl get pods -A
```

---

## 5. Key concepts to know

### Raft consensus
etcd uses the **Raft algorithm** to elect a leader and replicate data:
- All **writes** go to the **leader**
- Leader replicates to followers
- A write is committed only when **majority (quorum)** acknowledges it

```
Client → Leader → Follower1 ✓
                → Follower2 ✓  ← quorum reached → committed
```

### Compaction
etcd keeps a history of all revisions. Over time this grows large — **compaction** removes old revisions:

```bash
# Compact up to current revision
REV=$(etcdctl endpoint status --write-out json | jq '.[] | .Status.header.revision')
etcdctl compact $REV

# Defragment after compaction
etcdctl defrag
```

### Encryption at rest
Kubernetes can encrypt etcd data (Secrets) using an `EncryptionConfiguration` — important for production:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: <base64-encoded-32-byte-key>
      - identity: {}
```

---

## 6. etcd in Kind (this cluster)

| Property | Value |
|---|---|
| Members | 3 (one per control-plane node) |
| Leader election | Automatic via Raft |
| Data directory | `/var/lib/etcd` inside control-plane containers |
| Certs location | `/etc/kubernetes/pki/etcd/` |

> 💡 In Kind, etcd data lives **inside Docker containers** — it does not persist if you delete the cluster.
> Always take snapshots before `./delete_cluster.sh` if you want to preserve state.

---

## Quick reference

| Task | Command |
|---|---|
| Health check | `etcdctl endpoint health` |
| Member list | `etcdctl member list --write-out=table` |
| Status (leader info) | `etcdctl endpoint status --write-out=table` |
| Snapshot backup | `etcdctl snapshot save /tmp/etcd-backup.db` |
| Verify snapshot | `etcdctl snapshot status /tmp/etcd-backup.db --write-out=table` |
| Restore snapshot | `etcdctl snapshot restore /tmp/etcd-backup.db --data-dir=...` |
| Compact history | `etcdctl compact $REV` |
| Defragment | `etcdctl defrag` |
