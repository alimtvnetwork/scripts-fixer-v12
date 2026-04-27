# scripts-orchestrator

Multi-OS SSH orchestrator. Bash CLI at the project root level. No UI.

## Quick start

```sh
# 1. Install controller deps (Ubuntu/Debian example)
sudo apt-get install -y openssh-client sshpass sqlite3 openssl

# 2. Copy the example inventory and edit
cp -r scripts-orchestrator/inventory.example scripts-orchestrator/inventory
$EDITOR scripts-orchestrator/inventory/hosts.conf

# 3. Bootstrap one host (password->key)
./scripts-orchestrator/run.sh bootstrap k8s-master

# 4. Run an inline command across the whole cluster group, in parallel
./scripts-orchestrator/run.sh run "uptime" --group cluster --parallel 8 --allow-inline

# 5. Provision Kubernetes (kubeadm v1.31, CRI-O, Weave, Helm)
./scripts-orchestrator/run.sh playbook k8s-kubeadm --group cluster --role control-plane
./scripts-orchestrator/run.sh playbook k8s-kubeadm --group cluster --role worker

# 6. View audit log
./scripts-orchestrator/run.sh log tail
```

## Requirements

| Side | Tools |
|---|---|
| Controller | bash, openssh-client, sshpass, sqlite3, openssl |
| Targets    | sshd, sudo (or root), bash |

Targets in scope: Ubuntu, Debian, RHEL, CentOS, Fedora, Alpine, Arch, macOS.
Windows targets are **out of scope** in this version.

## File layout

See `mem://specs/01-ssh-orchestration` for the full spec.

## Reference

K8s playbook ported from
[aukgit/kubernetes-training-v1/03-kube-Installer](https://github.com/aukgit/kubernetes-training-v1/tree/main/03-kube-Installer).
