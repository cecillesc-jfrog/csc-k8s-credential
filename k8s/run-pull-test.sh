#!/usr/bin/env bash
# Usage: ./k8s/run-pull-test.sh <build number>
set -euo pipefail
N="${1:?build number required, for example 1}"
kubectl delete pod oidc-demo -n default --ignore-not-found
sed "s/BUILD_NUMBER/$N/" "$(dirname "$0")/oidc-demo-pod.yaml" | kubectl apply -f -
kubectl wait --for=condition=Ready pod/oidc-demo -n default --timeout=120s || true
kubectl get pod oidc-demo -n default
kubectl logs oidc-demo -n default || true
echo "--- imagePullSecrets (expect empty):"
kubectl get pod oidc-demo -n default -o jsonpath='{.spec.imagePullSecrets}'; echo
