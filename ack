#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# ///

# SPDX-FileCopyrightText: Dr. Jan-Philip Gehrcke
# SPDX-License-Identifier: MIT

"""ACK — All-to-all CUDA memory copy test for Kubernetes.

Deploy a benchmark StatefulSet and optionally run verification.
"""

import argparse
import logging
import time
import os
import subprocess
import sys
from pathlib import Path
from string import Template

logging.Formatter.converter = time.gmtime
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s.%(msecs)03dZ %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger(__name__)

SCRIPT_DIR = Path(__file__).resolve().parent

# K8s resources created by ACK, in deletion order.
ACK_RESOURCES = [
    ("statefulset", "ack"),
    ("service", "svc-ack"),
    ("computedomain", "ack-compute-domain"),
    ("resourceclaimtemplate", "ack-gpu-rct"),
    ("rolebinding", "ack"),
    ("role", "ack"),
    ("serviceaccount", "ack"),
]


def parse_args():
    p = argparse.ArgumentParser(
        description="Deploy ACK benchmark StatefulSet.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("num_pods", type=int,
                   help="number of StatefulSet replicas (one pod per node)")
    p.add_argument("--chunk-mib", type=int, default=2500,
                   help="GPU memory chunk size in MiB (default: 2500, max: 4096)")
    p.add_argument("--gpus-per-pod", type=int, default=4,
                   help="GPUs per pod (default: 4)")
    p.add_argument("--interval-s", type=int, default=1,
                   help="benchmark interval in seconds (default: 1, ignored in verify mode)")
    p.add_argument("--gpus-via-dra", action="store_true",
                   help="request GPUs via DRA instead of device plugin")
    p.add_argument("--verify", type=int, default=0, metavar="N",
                   help="run N full benchmark rounds then exit")
    p.add_argument("--verify-timeout", type=int, default=300, metavar="S",
                   help="verify timeout in seconds (default: 300)")
    p.add_argument("--teardown-on-verify-error", action="store_true",
                   help="tear down resources even on verify failure")
    p.add_argument("--show-stddev", action="store_true",
                   help="show bandwidth stddev matrix after verify")
    p.add_argument("--peer-discovery", choices=["dns", "k8s-api"],
                   default="k8s-api",
                   help="peer discovery method (default: k8s-api)")
    return p.parse_args()


def kubectl(*args, check=True):
    """Run a kubectl command. Returns CompletedProcess."""
    cmd = ["kubectl"] + list(args)
    log.debug("$ %s", " ".join(cmd))
    return subprocess.run(cmd, check=check, text=True)


def cleanup_resources():
    """Delete all ACK Kubernetes resources (idempotent)."""
    log.info("cleaning up previous resources")
    for kind, name in ACK_RESOURCES:
        kubectl("delete", kind, name, "--ignore-not-found", check=False)
    kubectl("wait", "--for=delete", "pod", "-l", "app=ack",
            "--timeout=60s", check=False)


def render_template(args):
    """Read the manifest template and substitute variables."""
    if args.gpus_via_dra:
        template_path = SCRIPT_DIR / "spec" / "ack-dra.yaml.envsubst"
        log.info("using DRA for GPU allocation")
    else:
        template_path = SCRIPT_DIR / "spec" / "ack.yaml.envsubst"

    raw = template_path.read_text()

    # The templates use ${ACK_VAR} syntax — compatible with string.Template.
    # string.Template uses $var or ${var}; our vars all have the ACK_ prefix
    # so there's no collision with other $ in the YAML.
    substitutions = {
        "ACK_REPLICAS": str(args.num_pods),
        "ACK_CHUNK_MIB": str(args.chunk_mib),
        "ACK_GPUS_PER_NODE": str(args.gpus_per_pod),
        "ACK_POLL_INTERVAL_S": str(args.interval_s),
        "ACK_VERIFY_ROUNDS": str(args.verify),
        "ACK_PEER_DISCOVERY": args.peer_discovery,
    }

    log.info("rendering manifest: %s",
             ", ".join(f"{k}={v}" for k, v in substitutions.items()))

    return Template(raw).safe_substitute(substitutions)


def deploy(args):
    """Clean up, render, apply, and wait for rollout."""
    cleanup_resources()
    manifest = render_template(args)
    log.info("applying manifest")
    proc = subprocess.run(
        ["kubectl", "apply", "-f", "-"],
        input=manifest, text=True, check=True,
    )
    log.info("waiting for rollout")
    kubectl("rollout", "status", "statefulset/ack", "--timeout=300s")
    log.info("pod status:")
    kubectl("get", "pods", "-l", "app=ack", "-o", "wide")


def run_verify(args):
    """Run verify_wait.py and handle teardown based on outcome."""

    cmd = [
        "uv", "run",
        str(SCRIPT_DIR / "src" / "verify_wait.py"),
        str(args.num_pods),
        str(args.verify),
        str(args.verify_timeout),
    ]
    if args.show_stddev:
        cmd.append("--show-stddev")

    result = subprocess.run(cmd)
    verify_ok = result.returncode == 0

    if verify_ok:
        cleanup_resources()
        return 0

    if args.teardown_on_verify_error:
        cleanup_resources()
    else:
        log.info("keeping resources for debugging "
                 "(use --teardown-on-verify-error to auto-clean)")
    return 1


def main():
    args = parse_args()
    try:
        deploy(args)
    except subprocess.CalledProcessError as exc:
        log.error("kubectl failed: %s", exc.stderr or exc)
        sys.exit(1)

    if args.verify:
        sys.exit(run_verify(args))


if __name__ == "__main__":
    main()
