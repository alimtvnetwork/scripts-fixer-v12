#!/usr/bin/env bash
# Apply Weave CNI on the control-plane (per reference repo).
set -e
export KUBECONFIG="$HOME/.kube/config"
kubectl apply -f https://reweave.azurewebsites.net/k8s/v1.31/net.yaml
kubectl -n kube-system get pods
echo "[OK] Weave CNI applied on $(hostname)"
