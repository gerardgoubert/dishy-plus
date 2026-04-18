#!/bin/bash
set -euo pipefail

NAMESPACE="thirteenft"

echo "=== Deploying 13ft ==="

# Create namespace (idempotent)
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Deployment
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: thirteenft
  namespace: thirteenft
  labels:
    app.kubernetes.io/name: thirteenft
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: thirteenft
  template:
    metadata:
      labels:
        app.kubernetes.io/name: thirteenft
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: thirteenft
          image: "ghcr.io/wasi-master/13ft:latest"
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false
            capabilities:
              drop:
                - ALL
          ports:
            - name: http
              containerPort: 5000
              protocol: TCP
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 10
            periodSeconds: 15
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 250m
              memory: 256Mi
EOF

# Service
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: thirteenft
  namespace: thirteenft
  labels:
    app.kubernetes.io/name: thirteenft
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: thirteenft
  ports:
    - name: http
      port: 5000
      targetPort: http
      protocol: TCP
EOF

# IngressRoute with Homepage discovery annotations
kubectl apply -f - <<'EOF'
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: thirteenft
  namespace: thirteenft
  annotations:
    gethomepage.dev/enabled: "true"
    gethomepage.dev/name: "13ft"
    gethomepage.dev/description: "Bypass paywalls"
    gethomepage.dev/group: "Applications"
    gethomepage.dev/icon: "mdi-newspaper-variant-outline"
    gethomepage.dev/href: "http://13ft.cluster.local"
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`13ft.cluster.local`)
      kind: Rule
      services:
        - name: thirteenft
          port: 5000
    - match: Host(`13ft.wickedgoodwifi.com`)
      kind: Rule
      services:
        - name: thirteenft
          port: 5000
EOF

echo "=== 13ft deployed ==="
