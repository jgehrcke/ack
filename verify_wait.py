#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = ["requests"]
# ///
"""Poll all ACK pods until every pod reports verify_state=SUCCEEDED, then exit 0.

Expects two arguments: <num_pods> <verify_rounds>.
Resolves pod node IPs via kubectl, then polls /results in parallel.
"""

import json
import logging
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

import requests
from requests.adapters import HTTPAdapter

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s.%(msecs)03dZ %(levelname)s: %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger()

POLL_INTERVAL_S = 0.5
TIMEOUT_S = 300
HTTP_TIMEOUT = (0.3, 0.8)  # (connect, recv) seconds

# Session with no internal retries.
_session = requests.Session()
_session.mount("http://", HTTPAdapter(max_retries=0))


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


def _short_error(exc):
    """Extract the essential error from a requests exception."""
    if isinstance(exc, requests.exceptions.ConnectTimeout):
        return f"connect timed out ({HTTP_TIMEOUT[0]}s)"
    if isinstance(exc, requests.exceptions.ReadTimeout):
        return f"read timed out ({HTTP_TIMEOUT[1]}s)"
    # Extract the innermost bracketed error, e.g.,
    # "[Errno 111] Connection refused" from the verbose requests wrapper.
    import re
    m = re.search(r'\[Errno \d+\] [^")\]]+', str(exc))
    if m:
        return m.group(0)
    s = str(exc)
    if len(s) > 50:
        return s[:20] + "..." + s[-30:]
    return s


def poll_pod(name, ip):
    """Return (pod_name, verify_state, rounds_completed, error)."""
    try:
        resp = _session.get(f"http://{ip}:1337/results", timeout=HTTP_TIMEOUT)
        data = resp.json()
        return (name, data.get("verify_state"),
                data.get("verify_rounds_completed", 0), None)
    except Exception as exc:
        return (name, None, 0, _short_error(exc))


def fetch_results(ip):
    """Fetch /results JSON from a pod. Returns parsed dict or None."""
    try:
        resp = _session.get(f"http://{ip}:1337/results", timeout=HTTP_TIMEOUT)
        return resp.json()
    except Exception:
        return None


def print_summary(pods, show_stddev=False):
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

    print()
    print_matrix("Bandwidth mean (GB/s):", matrix_mean)
    if show_stddev:
        print_matrix("Bandwidth stddev (GB/s):", matrix_std)


def poll_all(num_pods, verify_rounds):
    """Poll all pods. Returns "ok", "failed", or "pending"."""
    try:
        pods = get_pods()
    except Exception as exc:
        log.warning("error getting pods: %s", exc)
        return "pending"

    if not pods:
        log.info("no pods found")
        return "pending"

    with ThreadPoolExecutor(max_workers=len(pods)) as pool:
        futures = [pool.submit(poll_pod, name, ip) for name, ip in pods]
        results = [f.result() for f in futures]

    parts = []
    any_failed = False
    failed_pods = []
    all_succeeded = len(results) == num_pods
    for name, state, rounds_completed, err in results:
        if err:
            parts.append(f"{name}=err({err})")
            all_succeeded = False
        elif state == "SUCCEEDED":
            parts.append(f"{name}=SUCCEEDED")
        elif state == "FAILED":
            parts.append(f"{name}=FAILED")
            any_failed = True
            failed_pods.append(name)
        elif state == "IN_PROGRESS":
            width = len(str(verify_rounds))
            parts.append(f"{name}=IN_PROGRESS({rounds_completed:0{width}d}/{verify_rounds})")
            all_succeeded = False
        else:
            parts.append(f"{name}={state or '?'}")
            all_succeeded = False

    log.info("%s", " ".join(parts))

    if any_failed:
        return ("failed", failed_pods)
    if all_succeeded:
        return ("ok", [])
    return ("pending", [])


def main():
    # Parse positional args and optional --show-stddev flag.
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    show_stddev = "--show-stddev" in sys.argv

    if len(args) < 2:
        print(f"Usage: {sys.argv[0]} <num_pods> <verify_rounds> [timeout_s] [--show-stddev]",
              file=sys.stderr)
        sys.exit(1)

    num_pods = int(args[0])
    verify_rounds = int(args[1])
    timeout_s = int(args[2]) if len(args) > 2 else TIMEOUT_S
    log.info("waiting for %d pods × %d rounds (timeout: %ds)",
             num_pods, verify_rounds, timeout_s)

    start = time.monotonic()
    while True:

        time.sleep(POLL_INTERVAL_S)

        elapsed = time.monotonic() - start
        if elapsed > timeout_s:
            log.error("verification did not complete within %ds", timeout_s)
            sys.exit(1)

        outcome, failed_pods = poll_all(num_pods, verify_rounds)
        if outcome == "ok":
            log.info("all %d pods passed %d rounds", num_pods, verify_rounds)
            pods = get_pods()
            print_summary(pods, show_stddev=show_stddev)
            sys.exit(0)
        if outcome == "failed":
            log.error("verification failed: %s reported FAILED",
                      ", ".join(failed_pods))
            for pod_name in failed_pods:
                try:
                    tail = subprocess.check_output(
                        ["kubectl", "logs", pod_name, "--tail=10"],
                        stderr=subprocess.DEVNULL, timeout=5,
                    ).decode("utf-8", errors="replace").rstrip()
                    print(f"\n--- {pod_name} (last 10 log lines) ---")
                    print(tail)
                except Exception:
                    print(f"\n--- {pod_name}: failed to fetch logs ---")
            sys.exit(1)


if __name__ == "__main__":
    main()
