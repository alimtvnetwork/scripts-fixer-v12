#!/usr/bin/env bash
# Ported from aukgit/kubernetes-training-v1/03-kube-Installer/05-helm.install.sh
# Decoupled from the original 01-base-shell-scripts dependency chain.
set -e
VERSION="${HELM_VERSION:-3.16.2}"
FILE="helm-v${VERSION}-linux-amd64.tar.gz"
URL="https://get.helm.sh/${FILE}"
TMP="/tmp/helm-install"

if command -v helm >/dev/null 2>&1; then
  echo "[SKIP] helm already installed: $(helm version --short)"
  exit 0
fi

mkdir -p "$TMP"
cd "$TMP"
curl -fsSL -o "$FILE" "$URL"
tar xzf "$FILE"
mv linux-amd64/helm /usr/local/bin/helm
cd -
rm -rf "$TMP"
echo "[OK] helm v${VERSION} installed: $(helm version --short)"
