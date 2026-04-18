#!/bin/bash
set -euo pipefail

NAMESPACE="homepage"

usage() {
  echo "Usage: $0 {install|remove}"
  exit 1
}

do_install() {
  echo "=== Installing Homepage ==="

  # Create namespace (idempotent)
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  # Create Service Account
  kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: homepage
  namespace: homepage
  labels:
    app.kubernetes.io/name: homepage
secrets:
  - name: homepage
EOF

  # Create Homepage Secrets
  kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
type: kubernetes.io/service-account-token
metadata:
  name: homepage
  namespace: homepage
  labels:
    app.kubernetes.io/name: homepage
  annotations:
    kubernetes.io/service-account.name: homepage
EOF

  # Create ConfigMap
  kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: homepage
  namespace: homepage
  labels:
    app.kubernetes.io/name: homepage
data:
  kubernetes.yaml: |
    mode: cluster
    ingress: true
    traefik: true
  settings.yaml: |
    providers:
      longhorn:
        url: https://longhorn.cluster.local
  custom.css: ""
  custom.js: ""
  bookmarks.yaml: |
    - Developer:
        - Github:
            - abbr: GH
              href: https://github.com/
        - Longhorn:
            - abbr: LH
              href: http://longhorn.cluster.local
        - Grafana:
            - abbr: GF
              href: http://grafana.cluster.local
        - Headlamp:
            - abbr: HL
              href: http://headlamp.cluster.local
  services.yaml: |
    - Applications: []
    
    - My First Group:
        - My First Service:
            href: http://localhost/
            description: Homepage is awesome

    - My Second Group:
        - My Second Service:
            href: http://localhost/
            description: Homepage is the best

  widgets.yaml: |
    - kubernetes:
        cluster:
          show: true
          cpu: true
          memory: true
          showLabel: true
          label: "cluster"
        nodes:
          show: true
          cpu: true
          memory: true
          showLabel: true
    - resources:
        backend: resources
        expanded: true
        cpu: true
        memory: true
        network: default
    - search:
        provider: duckduckgo
        target: _blank
  docker.yaml: ""
  proxmox.yaml: ""
EOF

  # Create ClusterRole and ClusterRoleBinding
  kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: homepage
  labels:
    app.kubernetes.io/name: homepage
rules:
  - apiGroups:
      - ""
    resources:
      - namespaces
      - pods
      - nodes
    verbs:
      - get
      - list
  - apiGroups:
      - extensions
      - networking.k8s.io
    resources:
      - ingresses
    verbs:
      - get
      - list
  - apiGroups:
      - traefik.io
    resources:
      - ingressroutes
    verbs:
      - get
      - list
  - apiGroups:
      - gateway.networking.k8s.io
    resources:
      - httproutes
      - gateways
    verbs:
      - get
      - list
  - apiGroups:
      - metrics.k8s.io
    resources:
      - nodes
      - pods
    verbs:
      - get
      - list
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: homepage
  labels:
    app.kubernetes.io/name: homepage
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: homepage
subjects:
  - kind: ServiceAccount
    name: homepage
    namespace: homepage
EOF

  # Create Homepage Service
  kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: homepage
  namespace: homepage
  labels:
    app.kubernetes.io/name: homepage
spec:
  type: LoadBalancer
  ports:
    - port: 3000
      targetPort: http
      protocol: TCP
      name: http
  selector:
    app.kubernetes.io/name: homepage
EOF

  # Create Deployment
  kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: homepage
  namespace: homepage
  labels:
    app.kubernetes.io/name: homepage
spec:
  revisionHistoryLimit: 3
  replicas: 1
  strategy:
    type: RollingUpdate
  selector:
    matchLabels:
      app.kubernetes.io/name: homepage
  template:
    metadata:
      labels:
        app.kubernetes.io/name: homepage
    spec:
      serviceAccountName: homepage
      automountServiceAccountToken: true
      dnsPolicy: ClusterFirst
      enableServiceLinks: true
      containers:
        - name: homepage
          image: "ghcr.io/gethomepage/homepage:latest"
          imagePullPolicy: Always
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            runAsNonRoot: true
            runAsUser: 1000
            runAsGroup: 1000
            seccompProfile:
              type: RuntimeDefault
          env:
            - name: MY_POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            - name: HOMEPAGE_ALLOWED_HOSTS
              value: "$(MY_POD_IP):3000,homepage.cluster.local,homepage.wickedgoodwifi.com"
          ports:
            - name: http
              containerPort: 3000
              protocol: TCP
          livenessProbe:
            httpGet:
              path: /api/healthcheck
              port: http
            initialDelaySeconds: 10
            periodSeconds: 30
            failureThreshold: 5
          readinessProbe:
            httpGet:
              path: /api/healthcheck
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          volumeMounts:
            - mountPath: /app/config/custom.js
              name: homepage-config
              subPath: custom.js
            - mountPath: /app/config/custom.css
              name: homepage-config
              subPath: custom.css
            - mountPath: /app/config/bookmarks.yaml
              name: homepage-config
              subPath: bookmarks.yaml
            - mountPath: /app/config/docker.yaml
              name: homepage-config
              subPath: docker.yaml
            - mountPath: /app/config/kubernetes.yaml
              name: homepage-config
              subPath: kubernetes.yaml
            - mountPath: /app/config/services.yaml
              name: homepage-config
              subPath: services.yaml
            - mountPath: /app/config/settings.yaml
              name: homepage-config
              subPath: settings.yaml
            - mountPath: /app/config/widgets.yaml
              name: homepage-config
              subPath: widgets.yaml
            - mountPath: /app/config/proxmox.yaml
              name: homepage-config
              subPath: proxmox.yaml
            - mountPath: /app/config/logs
              name: logs
      volumes:
        - name: homepage-config
          configMap:
            name: homepage
        - name: logs
          emptyDir: {}
EOF

  # Create Ingress
  kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: homepage
  namespace: homepage
  labels:
    app.kubernetes.io/name: homepage
  annotations:
    gethomepage.dev/description: Dynamically Detected Homepage
    gethomepage.dev/enabled: "true"
    gethomepage.dev/group: Cluster Management
    gethomepage.dev/icon: homepage.png
    gethomepage.dev/name: Homepage
spec:
  rules:
    - host: "homepage.cluster.local"
      http:
        paths:
          - path: "/"
            pathType: Prefix
            backend:
              service:
                name: homepage
                port:
                  number: 3000
EOF

  # Create internal IngressRoute
  kubectl apply -f - <<'EOF'
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: homepage
  namespace: homepage
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`homepage.cluster.local`)
      services:
        - kind: Service
          name: homepage
          port: 3000
          sticky:
            cookie:
              httpOnly: true
              secure: false
              sameSite: none
EOF

  # Create external IngressRoute for Cloudflare tunnel
  kubectl apply -f - <<'EOF'
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: homepage-external
  namespace: homepage
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`homepage.wickedgoodwifi.com`)
      kind: Rule
      services:
        - name: homepage
          port: 3000
          sticky:
            cookie:
              httpOnly: true
              secure: false
              sameSite: none
EOF

  echo "=== Homepage installed ==="
}

do_remove() {
  echo "=== Removing Homepage ==="

  # Remove cluster-scoped resources first (not deleted by namespace removal)
  kubectl delete clusterrolebinding homepage 2>/dev/null \
    || echo "ClusterRoleBinding 'homepage' not found, skipping"
  kubectl delete clusterrole homepage 2>/dev/null \
    || echo "ClusterRole 'homepage' not found, skipping"

  # Delete namespace (removes all namespaced resources)
  kubectl delete namespace "$NAMESPACE" 2>/dev/null \
    || echo "Namespace '$NAMESPACE' not found, skipping"

  echo "=== Homepage removed ==="
}

[[ $# -lt 1 ]] && usage

case "$1" in
  install) do_install ;;
  remove)  do_remove ;;
  *)       usage ;;
esac
