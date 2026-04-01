# ACK

All-to-all CUDA memory copy test for Kubernetes.

A tool for testing multi-node NVLink (MNNVL) communication between GPU pairs.
Can be thought of as an MPI-free, dynamic re-implementation of [nvbandwidth](https://github.com/NVIDIA/nvbandwidth).

Supports adding and removing nodes/pods/GPUs at runtime.

Originally built to demonstrate the elastic `ComputeDomain` concept provided by the [NVIDIA DRA Driver for GPUs](https://github.com/NVIDIA/k8s-dra-driver-gpu).


## Method

The application is deployed as a Kubernetes StatefulSet.
Each pod in this set runs a main loop which repeats:
1. **Discover** (all current peers)
2. **Communicate** (pull memory from all remote GPUs into all local GPUs)
3. **Report** (emit benchmark results)

Measurement method:
* After allocating local GPU memory, it is being prepared for multi-node NVLink exchange by creating a handle of type `CU_MEM_HANDLE_TYPE_FABRIC`.
* The actual exchange is performed by `cuMemcpyDtoD()` (copying remote GPU memory into local GPU memory, in this case).
* The duration is measured on-GPU via `cuEventRecord()` &`cuEventElapsedTime()`.
* After each copy, a checksum kernel verifies data integrity of the transferred chunk.
* Relevant CUDA API calls involved are `cuMemCreate()`,
`cuMemExportToShareableHandle()`,
`cuMemImportFromShareableHandle()`, `cuMemMap()` -- that's about it.

## Architecture

**ack.py** — benchmark runner and HTTP server.

Key concepts:

- Per-GPU HTTP-based locking ensures exclusive GPU access during measurement. Locks are acquired in consistent (pod_index, gpu_index) order to prevent deadlock, use random tokens so stale unlocks cannot release a re-acquired lock, and auto-expire via a watchdog thread to recover from crashed clients.
- A fabric handle import cache avoids the expensive import/map/setAccess path (~35-100 ms) on every benchmark. Stale entries are evicted when handle bytes change (chunk refresh) or the peer disappears.
- A deadline-based poll loop with parallel per-peer benchmarking (one thread per peer). Peers are discovered via DNS SRV lookup on the headless Service.

HTTP endpoints:

| Endpoint | Method | Purpose |
|---|---|---|
| `/results` | GET | Last 5 rounds of structured benchmark data |
| `/healthz` | GET | Liveness: fails on fatal CUDA error or stale results |
| `/readyz` | GET | Readiness: confirms HTTP server is responsive |
| `/prepare-chunk` | GET | Exports a fresh fabric handle for a GPU |
| `/lock-gpu` | POST | Acquires exclusive GPU lock, returns token |
| `/unlock-gpu` | POST | Releases GPU lock (token must match) |
| `/evict-peer` | POST | Unmaps and releases cached imports of a peer's handles |

**dashboard.py** — Rich TUI with four panels:

- Pods: live status of ack StatefulSet pods
- ComputeDomain daemons: status of `computedomain-daemon` pods
- ComputeDomain status: node-level CD state
- Bandwidth matrix: NVLink bandwidth (GB/s) between all GPU pairs

Per-pod polling threads fetch `/results` via node IP + hostPort. Pod and CD state comes from kubectl.

## Elasticity

The StatefulSet can be scaled up or down at any time (`make scale-up`, `make scale-down`).

**Scale-up:** new pods appear in DNS SRV records for the headless Service. Existing pods discover them on the next poll round and begin benchmarking. No coordination or restart of existing pods is needed.

**Scale-down (graceful):** when a pod receives SIGTERM, it sets a shutdown flag that immediately rejects new `/prepare-chunk` and `/lock-gpu` requests (HTTP 503). It then waits for any remotely-held local GPU locks to drain (a peer holding our lock is mid-DtoD from our memory), broadcasts `/evict-peer` to all peers so they unmap their cached imports of our fabric handles, and finally releases all local CUDA resources. This sequence ensures no peer is left holding a reference to freed GPU memory.

**Unexpected peer loss:** if a pod disappears without graceful shutdown (node failure, OOM kill, `kubectl delete --force`), its fabric handles become invalid. The IMEX daemon on surviving nodes may report `CUDA_ERROR_ILLEGAL_STATE`, which poisons the CUDA context — all subsequent CUDA API calls fail. When `cucheck()` sees this error it sets `FATAL_CUDA_ERROR`, `/healthz` starts returning 500, the kubelet liveness probe fails (failureThreshold 3 at periodSeconds 3 gives ~9 seconds to pod kill), and the pod is restarted. On restart the pod re-initializes CUDA from scratch with a clean context. If the IMEX daemon recovers before the liveness probe kills the pod, a clean round clears `FATAL_CUDA_ERROR` and the pod continues without restart.

## Deployment

A StatefulSet with ComputeDomain, headless Service, and DRA resource claims. One pod per node (enforced via `podAntiAffinity` on `kubernetes.io/hostname`), co-scheduled on the same GPU clique (via `podAffinity` on `nvidia.com/gpu.clique`). Each pod uses `hostPort: 1337`.

```
./run.sh <num_pods> <chunk_mib> [gpus_per_node]
```

This cleans up previous resources, renders the manifest via `envsubst`, applies it, and waits for rollout.

## Makefile targets

| Target | Description |
|---|---|
| `make build` | Build container image |
| `make build-and-push` | Build and push (tagged with git short rev) |
| `make build-and-push-as-latest` | Build and push as both rev-tagged and `latest` |
| `make dashboard` | Run the TUI dashboard via `uv run` |
| `make scale-up` / `scale-down` | Adjust StatefulSet replica count by 1 |
| `make clean` | Delete StatefulSet, Service, and ComputeDomain |

## Configuration

Environment variables (set via the manifest):

| Variable | Default | Description |
|---|---|---|
| `HTTPD_PORT` | 1337 | HTTP server port |
| `CHUNK_MIB` | 2500 | GPU memory chunk size in MiB per allocation |
| `FLOAT_VALUE` | 1.0 | Fill value for GPU memory (used for checksum verification) |
| `SVC_NAME` | svc-ack | Headless service name for DNS peer discovery |
| `POLL_INTERVAL_S` | 1 | Seconds between benchmark rounds |
| `GPUS_PER_NODE` | 1 | Number of GPUs per pod |
