#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: $0 <num_pods> [options]"
    echo ""
    echo "  num_pods               number of StatefulSet replicas (one per node)"
    echo ""
    echo "Options:"
    echo "  --chunk-mib N          GPU memory chunk size in MiB (default: 2500)"
    echo "  --gpus-per-pod N      GPUs per pod (default: 4)"
    echo "  --interval-s N      run full benchmark (all-to-all) every N seconds (default: 1)"
    echo "  --gpus-via-dra              use DRA for GPU allocation instead of device plugin"
    exit 1
}

if [[ $# -lt 1 ]]; then
    usage
fi

export ACK_REPLICAS="$1"
shift

# Defaults.
export ACK_CHUNK_MIB="2500"
export ACK_GPUS_PER_NODE="4"
export ACK_POLL_INTERVAL_S="1"
GPU_DRA=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --chunk-mib)
            ACK_CHUNK_MIB="$2"; shift 2 ;;
        --gpus-per-pod)
            ACK_GPUS_PER_NODE="$2"; shift 2 ;;
        --interval-s)
            ACK_POLL_INTERVAL_S="$2"; shift 2 ;;
        --gpus-via-dra)
            GPU_DRA=true; shift ;;
        *)
            echo "Unknown option: $1"
            usage ;;
    esac
done

echo "--- Cleaning up previous resources (if any)"
kubectl delete statefulset ack --ignore-not-found
kubectl delete service svc-ack --ignore-not-found
kubectl delete computedomain ack-compute-domain --ignore-not-found
kubectl delete resourceclaimtemplate ack-gpu-rct --ignore-not-found
# Wait for pods to terminate before redeploying.
kubectl wait --for=delete pod -l app=ack --timeout=60s 2>/dev/null || true

if [[ "$GPU_DRA" == "true" ]]; then
    TEMPLATE="${SCRIPT_DIR}/ack-dra.yaml.envsubst"
    echo "--- Using DRA for GPU allocation"
else
    TEMPLATE="${SCRIPT_DIR}/ack.yaml.envsubst"
fi

echo "--- Rendering manifest: ACK_REPLICAS=${ACK_REPLICAS}, ACK_CHUNK_MIB=${ACK_CHUNK_MIB}, ACK_GPUS_PER_NODE=${ACK_GPUS_PER_NODE}, ACK_POLL_INTERVAL_S=${ACK_POLL_INTERVAL_S}"
RENDERED=$(envsubst '${ACK_REPLICAS} ${ACK_CHUNK_MIB} ${ACK_GPUS_PER_NODE} ${ACK_POLL_INTERVAL_S}' < "$TEMPLATE")

echo "--- Applying manifest"
echo "$RENDERED" | kubectl apply -f -

echo "--- Waiting for pods to become ready"
kubectl rollout status statefulset/ack --timeout=300s

echo "--- Pod status"
kubectl get pods -l app=ack -o wide
