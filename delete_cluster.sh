#!/bin/bash

echo "Deleting Kubernetes cluster 'tutorial-cluster'..."
kind delete cluster --name tutorial-cluster

echo "Cluster deleted."
