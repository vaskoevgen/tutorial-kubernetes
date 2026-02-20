Check ETCD's status:

```
kubectl exec -n kube-system etcd-tutorial-cluster-control-plane -- \
  etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  endpoint health
```

If the commands above fail, etcd might be crashing. Check the logs for immediate red flags:

```
kubectl logs -n kube-system etcd-tutorial-cluster-control-plane
```
