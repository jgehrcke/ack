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
    echo "  --gpus-per-pod N       GPUs per pod (default: 4)"
    echo "  --interval-s N         run full benchmark (all-to-all) every N seconds (default: 1, ignored in verify mode)"
    echo "  --gpus-via-dra         use DRA for GPU allocation instead of device plugin"
    echo "  --verify N             run N full benchmark rounds then exit (verification mode)"
    echo "  --peer-discovery M     peer discovery method: dns (default) or k8s-api"
    echo "  --teardown-on-verify-error  tear down resources even on verify failure (default: keep for debugging)"
    echo "  --verify-timeout N     with --verify: timeout in seconds (default: 300)"
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
export ACK_VERIFY_ROUNDS="0"
export ACK_PEER_DISCOVERY="k8s-api"
GPU_DRA=false
TEARDOWN_ON_VERIFY_ERROR=false
VERIFY_TIMEOUT_S="300"
SHOW_STDDEV=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --chunk-mib)
            [[ $# -ge 2 ]] || { echo "Error: --chunk-mib requires a value"; exit 1; }
            ACK_CHUNK_MIB="$2"; shift 2 ;;
        --gpus-per-pod)
            [[ $# -ge 2 ]] || { echo "Error: --gpus-per-pod requires a value"; exit 1; }
            ACK_GPUS_PER_NODE="$2"; shift 2 ;;
        --interval-s)
            [[ $# -ge 2 ]] || { echo "Error: --interval-s requires a value"; exit 1; }
            ACK_POLL_INTERVAL_S="$2"; shift 2 ;;
        --gpus-via-dra)
            GPU_DRA=true; shift ;;
        --verify)
            [[ $# -ge 2 ]] || { echo "Error: --verify requires a value (number of rounds)"; exit 1; }
            ACK_VERIFY_ROUNDS="$2"; shift 2 ;;
        --peer-discovery)
            [[ $# -ge 2 ]] || { echo "Error: --peer-discovery requires a value"; exit 1; }
            ACK_PEER_DISCOVERY="$2"; shift 2 ;;
        --teardown-on-verify-error)
            TEARDOWN_ON_VERIFY_ERROR=true; shift ;;
        --show-stddev)
            SHOW_STDDEV=true; shift ;;
        --verify-timeout)
            [[ $# -ge 2 ]] || { echo "Error: --verify-timeout requires a value"; exit 1; }
            VERIFY_TIMEOUT_S="$2"; shift 2 ;;
        *)
            echo "Unknown option: $1"
            usage ;;
    esac
done

echo "--- Cleaning up previous resources (if any)"
kubectl delete statefulset ack --ignore-not-found
kubectl delete service svc-ack --ignore-not-found
kubectl delete rolebinding ack --ignore-not-found
kubectl delete role ack --ignore-not-found
kubectl delete serviceaccount ack --ignore-not-found
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

echo "--- Rendering manifest: ACK_REPLICAS=${ACK_REPLICAS}, ACK_CHUNK_MIB=${ACK_CHUNK_MIB}, ACK_GPUS_PER_NODE=${ACK_GPUS_PER_NODE}, ACK_POLL_INTERVAL_S=${ACK_POLL_INTERVAL_S}, ACK_VERIFY_ROUNDS=${ACK_VERIFY_ROUNDS}"
RENDERED=$(sed \
    -e "s|\${ACK_REPLICAS}|${ACK_REPLICAS}|g" \
    -e "s|\${ACK_CHUNK_MIB}|${ACK_CHUNK_MIB}|g" \
    -e "s|\${ACK_GPUS_PER_NODE}|${ACK_GPUS_PER_NODE}|g" \
    -e "s|\${ACK_POLL_INTERVAL_S}|${ACK_POLL_INTERVAL_S}|g" \
    -e "s|\${ACK_VERIFY_ROUNDS}|${ACK_VERIFY_ROUNDS}|g" \
    -e "s|\${ACK_PEER_DISCOVERY}|${ACK_PEER_DISCOVERY}|g" \
    < "$TEMPLATE")

echo "--- Applying manifest"
echo "$RENDERED" | kubectl apply -f -

echo "--- Waiting for pods to become ready"
kubectl rollout status statefulset/ack --timeout=300s

echo "--- Pod status"
kubectl get pods -l app=ack -o wide

if [[ "$ACK_VERIFY_ROUNDS" != "0" ]]; then
    echo "--- Verify mode: waiting for all pods to complete ${ACK_VERIFY_ROUNDS} full rounds"
    VERIFY_RC=0
    STDDEV_FLAG=""
    if [[ "$SHOW_STDDEV" == "true" ]]; then STDDEV_FLAG="--show-stddev"; fi
    uv run "${SCRIPT_DIR}/verify_wait.py" "${ACK_REPLICAS}" "${ACK_VERIFY_ROUNDS}" "${VERIFY_TIMEOUT_S}" $STDDEV_FLAG || VERIFY_RC=$?
    if [[ "$VERIFY_RC" -eq 0 ]]; then
        make -C "${SCRIPT_DIR}" clean
    elif [[ "$TEARDOWN_ON_VERIFY_ERROR" == "true" ]]; then
        make -C "${SCRIPT_DIR}" clean
    else
        echo "--- Keeping resources for debugging (use --teardown-on-verify-error to auto-clean)"
    fi
    exit $VERIFY_RC
fi
