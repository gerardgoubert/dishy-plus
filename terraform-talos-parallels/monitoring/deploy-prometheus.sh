#!/bin/bash
set -euo pipefail

# Resolve this script's own directory so it can be invoked from anywhere
# (e.g. without the caller having to `cd` first, which would otherwise break
# any relative KUBECONFIG path already exported by the caller).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# KUBE_API should be exported by the caller (preferring the controlplane VIP,
# falling back to a control-plane node IP if the VIP is unreachable from the
# host due to Parallels bridged-network quirks). Fall back to kubectl's
# current context if run standalone without KUBE_API set. Plain string flags
# (not arrays) are used for compatibility with macOS's bundled bash 3.2.
KUBECTL_SERVER_ARG=""
HELM_API_ARG=""
if [ -n "${KUBE_API:-}" ]; then
  KUBECTL_SERVER_ARG="--server=$KUBE_API"
  HELM_API_ARG="--kube-apiserver $KUBE_API"
fi

kubectl $KUBECTL_SERVER_ARG create namespace monitoring --dry-run=client -o yaml | kubectl $KUBECTL_SERVER_ARG apply -f -
kubectl $KUBECTL_SERVER_ARG label --overwrite ns monitoring \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=baseline \
  pod-security.kubernetes.io/warn-version=latest \
  pod-security.kubernetes.io/audit=baseline \
  pod-security.kubernetes.io/audit-version=latest

# Add the repo
#helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
#helm repo update

# Install the prometheus stack

helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values "$SCRIPT_DIR/prometheus-values.yaml" \
  $HELM_API_ARG \
  --wait --timeout 5m

kubectl $KUBECTL_SERVER_ARG get pods -n monitoring

# Create Traefik IngressRoute for external Grafana access via Cloudflare tunnel
kubectl $KUBECTL_SERVER_ARG apply -f - <<EOF
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: grafana-external
  namespace: monitoring
  annotations:
    gethomepage.dev/enabled: "true"
    gethomepage.dev/name: "Grafana"
    gethomepage.dev/description: "Monitoring dashboards"
    gethomepage.dev/group: "Cluster Management"
    gethomepage.dev/icon: "grafana"
    gethomepage.dev/href: "http://grafana.cluster.local"
    gethomepage.dev/pod-selector: ""
spec:
  entryPoints:
    - web
  routes:
    - match: Host(\`grafana.wickedgoodwifi.com\`)
      kind: Rule
      services:
        - name: prometheus-grafana
          port: 80
EOF

echo "IngressRoute grafana-external created for grafana.wickedgoodwifi.com"

