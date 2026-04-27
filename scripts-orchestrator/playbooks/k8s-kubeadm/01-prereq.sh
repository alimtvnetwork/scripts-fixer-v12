#!/usr/bin/env bash
# Ported from aukgit/kubernetes-training-v1/03-kube-Installer/01-ubuntu-prereq.sh
set -e
apt update -y
apt-get update -y
apt upgrade -y
apt-get install -y \
  vim build-essential wget nano curl file git \
  libpcre3 libpcre3-dev zlib1g zlib1g-dev libssl-dev \
  git-core sshpass apt-transport-https ca-certificates gpg
echo "[OK] prereq complete on $(hostname)"
