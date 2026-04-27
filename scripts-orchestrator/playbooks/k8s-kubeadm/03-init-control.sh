#!/usr/bin/env bash
# Ported from aukgit/kubernetes-training-v1/03-kube-Installer/03-kube-init.sh
set -e
systemctl enable --now crio.service
kubeadm init
mkdir -p "$HOME/.kube"
cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
chown "$(id -u):$(id -g)" "$HOME/.kube/config"
echo
echo "[NEXT] On worker nodes, run the join command printed above."
echo "[NEXT] Or regenerate it: sudo kubeadm token create --print-join-command"
echo "[OK] control-plane initialized on $(hostname)"
