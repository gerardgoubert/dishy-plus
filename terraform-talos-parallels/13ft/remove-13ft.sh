#!/bin/bash
set -euo pipefail

NAMESPACE="thirteenft"

echo "=== Removing 13ft ==="

kubectl delete namespace "$NAMESPACE" 2>/dev/null \
  || echo "Namespace '$NAMESPACE' not found, skipping"

echo "=== 13ft removed ==="
