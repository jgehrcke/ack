#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# ///
"""Poll all ACK pods until every pod reports verify_ok=true, then exit 0.

Expects two arguments: <num_pods> <verify_rounds>.
Resolves pod node IPs via kubectl, then polls /results in parallel.
"""

import json
import logging
import subprocess
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s.%(msecs)03dZ %(levelname)s: %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger()

POLL_INTERVAL_S = 0.5
TIMEOUT_S = 300
HTTP_TIMEOUT_S = 2


def get_pods():
    """Return list of (pod_name, node_ip) from kubectl."""
    out = subprocess.check_output(
        ["kubectl", "get", "pods", "-l", "app=ack", "-o", "json"],
        timeout=5,
    )
    data = json.loads(out)
    pods = []
    for item in data.get("items", []):
        name = item["metadata"]["name"]
        ip = item.get("status", {}).get("hostIP", "")
        if name and ip:
            pods.append((name, ip))
    return pods


def poll_pod(name, ip):
    """Return (pod_name, verify_ok, rounds_completed, error)."""
    try:
        req = urllib.request.Request(f"http://{ip}:1337/results")
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S) as resp:
            data = json.loads(resp.read())
            return (name, data.get("verify_ok", False),
                    data.get("verify_rounds_completed", 0), None)
    except Exception as exc:
        return (name, False, 0, str(exc))


def fetch_results(ip):
    """Fetch /results JSON from a pod. Returns parsed dict or None."""
    try:
        req = urllib.request.Request(f"http://{ip}:1337/results")
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S) as resp:
            return json.loads(resp.read())
    except Exception:
        return None


def print_summary(pods):
    """Fetch latest results from all pods and print a bandwidth matrix."""
    with ThreadPoolExecutor(max_workers=len(pods)) as pool:
        futures = {pool.submit(fetch_results, ip): name
                   for name, ip in pods}
        pod_data = {}
        for f in futures:
            name = futures[f]
            data = f.result()
            if data:
                pod_data[name] = data

    # Collect bandwidth values from all rounds across all pods.
    # For each (row, col) cell, accumulate all numeric values and
    # compute the mean.
    samples = {}  # {(row_label, col_label): [float, ...]}
    for pod_name, data in pod_data.items():
        idx = pod_name.rsplit("-", 1)[1]
        for result in data.get("results", []):
            for b in result.get("benchmarks", []):
                row = f"{idx}-g{b['local_gpu']}"
                col = f"{b['peer_idx']}-g{b['remote_gpu']}"
                val = b["value"]
                if val.endswith(" GB/s"):
                    try:
                        samples.setdefault((row, col), []).append(
                            float(val[:-5]))
                    except ValueError:
                        pass

    matrix_mean = {}
    matrix_std = {}
    for key, vals in samples.items():
        mean = sum(vals) / len(vals)
        matrix_mean[key] = f"{mean:.1f}"
        if len(vals) > 1:
            variance = sum((v - mean) ** 2 for v in vals) / (len(vals) - 1)
            matrix_std[key] = f"{variance ** 0.5:.2f}"
        else:
            matrix_std[key] = "—"

    if not matrix_mean:
        return

    # Build sorted axis labels.
    def sort_key(label):
        parts = label.split("-g")
        return (int(parts[0]), int(parts[1]))

    all_labels = sorted(
        set(k[0] for k in matrix_mean) | set(k[1] for k in matrix_mean),
        key=sort_key)

    def print_matrix(title, matrix, col_width=8):
        print(title)
        header = " " * 8
        for col in all_labels:
            header += f"{col:>{col_width}}"
        print(header)
        for row in all_labels:
            line = f"{row:<8}"
            row_pod = row.split("-g")[0]
            for col in all_labels:
                col_pod = col.split("-g")[0]
                if row_pod == col_pod:
                    line += f"{'—':>{col_width}}"
                else:
                    line += f"{matrix.get((row, col), '?'):>{col_width}}"
            print(line)
        print()

    print_matrix("Bandwidth mean (GB/s):", matrix_mean)
    print_matrix("Bandwidth stddev (GB/s):", matrix_std)


def poll_all(num_pods, verify_rounds):
    """Poll all pods. Return True when all pods report verify_ok."""
    try:
        pods = get_pods()
    except Exception as exc:
        log.warning("error getting pods: %s", exc)
        return False

    if not pods:
        log.info("no pods found")
        return False

    with ThreadPoolExecutor(max_workers=len(pods)) as pool:
        futures = [pool.submit(poll_pod, name, ip) for name, ip in pods]
        results = [f.result() for f in futures]

    parts = []
    all_ok = len(results) == num_pods
    for name, ok, rounds_completed, err in results:
        if ok:
            parts.append(f"{name}=ok")
        elif err:
            parts.append(f"{name}=err({err})")
            all_ok = False
        else:
            parts.append(f"{name}={rounds_completed}/{verify_rounds}")
            all_ok = False

    log.info("%s", " ".join(parts))
    return all_ok


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <num_pods> <verify_rounds>", file=sys.stderr)
        sys.exit(1)

    num_pods = int(sys.argv[1])
    verify_rounds = int(sys.argv[2])

    start = time.monotonic()
    while True:

        time.sleep(POLL_INTERVAL_S)

        if time.monotonic() - start > TIMEOUT_S:
            log.error("timeout after %ds", TIMEOUT_S)
            sys.exit(1)

        if poll_all(num_pods, verify_rounds):
            log.info("all %d pods passed %d rounds", num_pods, verify_rounds)
            pods = get_pods()
            print_summary(pods)
            sys.exit(0)


if __name__ == "__main__":
    main()
