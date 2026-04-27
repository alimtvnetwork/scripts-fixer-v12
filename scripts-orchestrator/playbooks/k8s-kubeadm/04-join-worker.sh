#!/usr/bin/env bash
# Worker join. Expects the join command in /etc/ssh-orchestrator/k8s-join.cmd
# (orchestrator copies this from control-plane via `kubeadm token create --print-join-command`).
set -e
JOIN_FILE="/etc/ssh-orchestrator/k8s-join.cmd"
if [ ! -f "$JOIN_FILE" ]; then
  echo "[FILE-ERROR] path=$JOIN_FILE reason=worker join command not provisioned (run control-plane init first then re-dispatch)" >&2
  exit 1
fi
systemctl enable --now crio.service
bash "$JOIN_FILE"
echo "[OK] $(hostname) joined the cluster"
