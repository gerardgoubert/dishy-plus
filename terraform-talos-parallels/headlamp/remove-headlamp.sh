#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG=/Users/gerardgoubert/projects/terraform-talos-parallels/generated/kubeconfig
export KUBECONFIG

# Remove headlamp via Helm
helm uninstall headlamp \
  --namespace kube-system \
  --kube-apiserver "https://192.168.60.210:6443" \
  --timeout 3m

# Apply the Traefik IngressRoute
kubectl delete -f "${SCRIPT_DIR}/ingressroute.yaml"

# create service account
kubectl -n kube-system delete serviceaccount headlamp-admin

# grant admin rights
kubectl delete clusterrolebinding headlamp-admin

# get token
kubectl delete secret headlamp-admin-token -n kube-system
