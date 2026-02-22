# Understanding Kubernetes Volumes

Kubernetes enables containers to access external storage through **Volumes**. By default, containers use ephemeral storage on the node—when a Pod dies or gets deleted, all its local state is lost. Volumes solve this by attaching storage whose lifecycle can overlap or outlive the Pod.

This guide explores two of the most common volume types:
1.  **`emptyDir`**: Temporary scratch space shared between multiple containers residing in the same Pod.
2.  **`PersistentVolumeClaim` (PVC)**: Persistent storage using dynamically provisioned disks that outlive the Pod.

---

## 1. Sharing Data Between Containers (`emptyDir`)

An `emptyDir` volume is created when a Pod is assigned to a node and exists as long as the Pod runs on that node. It starts completely empty. Containers in the Pod can all read and write from the same `emptyDir` mount, though it might be mounted at different paths in the filesystem of each container.

### Deploy the Example

Apply the provided `emptyDir` example:

```bash
kubectl apply -f 1-emptydir.yaml
```

Wait until the Pod is running:

```bash
kubectl get pods
```

### How it Works

The YAML file (`1-emptydir.yaml`) launches **one Pod** containing **two containers**:

1.  **`writer` (busybox)**: Runs a continuous loop appending the current date into `/data/shared/index.txt` every 5 seconds.
2.  **`reader` (nginx)**: Exposes a web server that serves static files from `/usr/share/nginx/html`.

Both containers mount the exact same `emptyDir` volume named `shared-storage` into their respective paths.

### Verify

You can interact with the `reader` container by hitting it directly. Let's send a request to NGINX running in the Pod:

```bash
# Port-forward the nginx container to your localhost on port 8080
kubectl port-forward pod/busybox-emptydir 8080:80 &
```

Now, check the contents by running `curl`:

```bash
curl http://localhost:8080
```

You should see an output log growing with lines like `Writing data at...`. The `writer` is generating the data, and the `reader` is seamlessly serving it because they share the same directory structure on the Node beneath them.

When done testing, kill the port-forward process (e.g., `kill %1`) and delete the pod:

```bash
kubectl delete -f 1-emptydir.yaml
```

**⚠️ Important:** Because this is an `emptyDir`, all the data stored within it is permanently deleted as soon as the Pod is removed.

---

## 2. Persistent Storage with Deployments (PVC)

Because Pods can be destroyed and recreated across different nodes at any time, an `emptyDir` won't preserve data during software rollouts or node failures. To save state permanently (such as Database data or user uploads), use a **PersistentVolumeClaim**.

In a managed Kubernetes cluster (like EKS or GKE) or Kind, creating a PVC dynamically issues a request to the underlying cloud/provider to create a physical block device and map it to your Pod.

### Deploy the PVC and Application

Apply the standard PVC and Deployment manifests:

```bash
kubectl apply -f 2-pvc-deployment.yaml
```

### How it Works

1.  **StorageClass**: Kind automatically installs a default `StorageClass` called `standard` (powered by Rancher's local-path-provisioner within the Docker containers) that watches for new claims.
2.  **PersistentVolumeClaim (PVC)**: The manifest requests `1Gi` of `ReadWriteOnce` storage. The provisioner allocates a `PersistentVolume` (PV) that fulfills this claim.
3.  **Deployment**: Launches an NGINX Pod that mounts this permanent volume to `/usr/share/nginx/html`.

### Verify the Storage

First, confirm the PVC was successfully bound:

```bash
kubectl get pvc
```
You should see `local-pvc` with a status of `Bound`.

Next, let's write permanent data directly to the disk by executing a command inside the Pod:

```bash
# Exec into the running deployment to create an index.html file
kubectl exec -it deploy/nginx-deployment-pv -- sh -c 'echo "<h1>Persistent Data Survives!</h1>" > /usr/share/nginx/html/index.html'

# Access the NGINX pod to verify it serves the file
kubectl port-forward deploy/nginx-deployment-pv 8080:80 &
curl http://localhost:8080
```

### Proving Persistence

If we delete a Pod that uses an `emptyDir`, the data is gone forever. Let's see what happens if we recreate the NGINX deployment Pod, forcing it to lose its local state:

```bash
# Scale the deployment down to 0 (kills all Pods)
kubectl scale deployment nginx-deployment-pv --replicas=0

# Scale back up to 1 (creates a brand new Pod)
kubectl scale deployment nginx-deployment-pv --replicas=1
```

Now, re-access the Pod (stop your previous port-forward and start a new one to the newly generated Pod):

```bash
kill %1
kubectl port-forward deploy/nginx-deployment-pv 8080:80 &

curl http://localhost:8080
```

You will still receive `<h1>Persistent Data Survives!</h1>`. Even though the original Pod was destroyed, the physical host disk backing the PVC survived and was immediately reattached to the newly scheduled Pod.

### Clean Up

To fully wipe the deployment and the underlying data storage:

```bash
kubectl delete -f 2-pvc-deployment.yaml
kill %1
```
