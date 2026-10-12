#!/usr/bin/env bash
# Run the pull test on one or both node groups.
#
# Usage: ./k8s/run-pull-test.sh <build number> [a|b|both]
#   a     Path A: node group csc-ng01 (provider installed by Helm), pod oidc-demo
#   b     Path B: node group csc-lt-ng01 (provider installed by a launch template), pod lt-test
#   both  both paths (default)
set -euo pipefail

N="${1:?build number required, for example 1}"
WHICH="${2:-both}"
DIR="$(cd "$(dirname "$0")" && pwd)"

run() {
  local name="$1" nodegroup="$2"
  echo "=== $name on node group $nodegroup"
  kubectl delete pod "$name" -n default --ignore-not-found
  sed -e "s/POD_NAME/$name/" -e "s/NODE_GROUP/$nodegroup/" -e "s/BUILD_NUMBER/$N/" "$DIR/oidc-demo-pod.yaml" | kubectl apply -f -
  kubectl wait --for=condition=Ready "pod/$name" -n default --timeout=120s || true
  kubectl get pod "$name" -n default -o wide
  kubectl logs "$name" -n default || true
  echo "--- imagePullSecrets (expect empty):"
  kubectl get pod "$name" -n default -o jsonpath='{.spec.imagePullSecrets}'; echo
  echo "--- events:"
  kubectl get events -n default --field-selector "involvedObject.name=$name" --sort-by=.lastTimestamp \
    -o custom-columns=REASON:.reason,MESSAGE:.message | cut -c1-200
}

case "$WHICH" in
  a)    run oidc-demo csc-ng01 ;;
  b)    run lt-test csc-lt-ng01 ;;
  both) run oidc-demo csc-ng01; run lt-test csc-lt-ng01 ;;
  *)    echo "second argument must be a, b or both" >&2; exit 1 ;;
esac

echo
echo "Kubernetes events expire after about an hour: capture screenshots now."
echo "Then check hts2 > Administration > Identity and Access > Access Tokens for"
echo "'Generated access token for Aws assumed role token exchange'."
