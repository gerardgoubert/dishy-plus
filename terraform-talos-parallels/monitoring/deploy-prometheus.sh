#!/bin/bash
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl label --overwrite ns monitoring \
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
  --values prometheus-values.yaml

kubectl get pods -n monitoring

# Create Traefik IngressRoute for external Grafana access via Cloudflare tunnel
kubectl apply -f - <<EOF
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

