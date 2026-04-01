#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <num_pods> <chunk_mib> [gpus_per_node] [poll_interval_s]"
    echo "  num_pods:         number of StatefulSet replicas (one per node)"
    echo "  chunk_mib:        GPU memory chunk size in MiB per peer-round"
    echo "  gpus_per_node:    GPUs per pod (default: 1)"
    echo "  poll_interval_s:  seconds between benchmark rounds (default: 3)"
    exit 1
fi

export REPLICAS="$1"
export CHUNK_MIB="$2"
export GPUS_PER_NODE="${3:-1}"
export POLL_INTERVAL_S="${4:-3}"

echo "--- Cleaning up previous resources (if any)"
kubectl delete statefulset ack --ignore-not-found
kubectl delete service svc-ack --ignore-not-found
kubectl delete computedomain ack-compute-domain --ignore-not-found
# Wait for pods to terminate before redeploying.
kubectl wait --for=delete pod -l app=ack --timeout=60s 2>/dev/null || true

echo "--- Rendering manifest: REPLICAS=${REPLICAS}, CHUNK_MIB=${CHUNK_MIB}, GPUS_PER_NODE=${GPUS_PER_NODE}, POLL_INTERVAL_S=${POLL_INTERVAL_S}"
RENDERED=$(envsubst '${REPLICAS} ${CHUNK_MIB} ${GPUS_PER_NODE} ${POLL_INTERVAL_S}' < "${SCRIPT_DIR}/ack.yaml.envsubst")

echo "--- Applying manifest"
echo "$RENDERED" | kubectl apply -f -

echo "--- Waiting for pods to become ready"
kubectl rollout status statefulset/ack --timeout=300s

echo "--- Pod status"
kubectl get pods -l app=ack -o wide
