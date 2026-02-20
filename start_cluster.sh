#!/bin/bash

echo "Starting Kubernetes cluster with 3 master and 2 worker nodes using kind..."
kind create cluster --name tutorial-cluster --config kind-config.yaml

echo "Cluster started successfully."
echo "Checking nodes..."
kubectl get nodes
