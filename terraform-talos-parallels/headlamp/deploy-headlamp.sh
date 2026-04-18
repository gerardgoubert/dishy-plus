#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG=/Users/gerardgoubert/projects/terraform-talos-parallels/generated/kubeconfig
export KUBECONFIG

# Install/upgrade headlamp via Helm
helm upgrade --install headlamp headlamp/headlamp \
  --namespace kube-system \
  -f "${SCRIPT_DIR}/values.yaml" \
  --kube-apiserver "https://192.168.60.210:6443" \
  --timeout 3m

# Apply the Traefik IngressRoute
kubectl apply -f "${SCRIPT_DIR}/ingressroute.yaml"

# create service account
kubectl -n kube-system create serviceaccount headlamp-admin

# grant admin rights
kubectl create clusterrolebinding headlamp-admin --serviceaccount=kube-system:headlamp-admin --clusterrole=cluster-admin

# get token
echo "Creating Token:"
kubectl create token headlamp-admin -n kube-system
