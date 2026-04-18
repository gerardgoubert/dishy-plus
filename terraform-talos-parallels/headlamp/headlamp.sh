#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG=/Users/gerardgoubert/projects/terraform-talos-parallels/generated/kubeconfig
export KUBECONFIG

NAMESPACE="kube-system"
KUBE_API="https://192.168.60.210:6443"
SA_NAME="headlamp-admin"
CRB_NAME="headlamp-admin"

usage() {
  echo "Usage: $0 {install|remove}"
  exit 1
}

do_install() {
  echo "=== Installing Headlamp ==="

  # Install/upgrade headlamp via Helm
  helm upgrade --install headlamp headlamp/headlamp \
    --namespace "$NAMESPACE" \
    -f "${SCRIPT_DIR}/values.yaml" \
    --kube-apiserver "$KUBE_API" \
    --timeout 3m

  # Apply the Traefik IngressRoute
  kubectl apply -f "${SCRIPT_DIR}/ingressroute.yaml"

  # Create service account (idempotent)
  kubectl -n "$NAMESPACE" create serviceaccount "$SA_NAME" --dry-run=client -o yaml \
    | kubectl apply -f -

  # Create clusterrolebinding (idempotent)
  kubectl create clusterrolebinding "$CRB_NAME" \
    --serviceaccount="${NAMESPACE}:${SA_NAME}" \
    --clusterrole=cluster-admin \
    --dry-run=client -o yaml \
    | kubectl apply -f -

  # Generate a token
  echo ""
  echo "=== Headlamp Admin Token ==="
  kubectl create token "$SA_NAME" -n "$NAMESPACE"
}

do_remove() {
  echo "=== Removing Headlamp ==="

  # Remove helm release
  helm uninstall headlamp \
    --namespace "$NAMESPACE" \
    --kube-apiserver "$KUBE_API" \
    --timeout 3m 2>/dev/null || echo "Helm release 'headlamp' not found, skipping"

  # Remove IngressRoute
  kubectl delete -f "${SCRIPT_DIR}/ingressroute.yaml" 2>/dev/null \
    || echo "IngressRoute already removed, skipping"

  # Remove clusterrolebinding
  kubectl delete clusterrolebinding "$CRB_NAME" 2>/dev/null \
    || echo "ClusterRoleBinding '$CRB_NAME' not found, skipping"

  # Remove service account
  kubectl -n "$NAMESPACE" delete serviceaccount "$SA_NAME" 2>/dev/null \
    || echo "ServiceAccount '$SA_NAME' not found, skipping"

  # Remove token secret (if it exists)
  kubectl delete secret "${SA_NAME}-token" -n "$NAMESPACE" 2>/dev/null \
    || echo "Secret '${SA_NAME}-token' not found, skipping"

  echo "=== Headlamp removed ==="
}

[[ $# -lt 1 ]] && usage

case "$1" in
  install) do_install ;;
  remove)  do_remove ;;
  *)       usage ;;
esac
