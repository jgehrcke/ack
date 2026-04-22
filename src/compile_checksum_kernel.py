# SPDX-FileCopyrightText: Dr. Jan-Philip Gehrcke
# SPDX-License-Identifier: MIT

"""Pre-compile the checksum CUDA kernel to PTX at image build time.

Compiles for compute_80 (Ampere) — the lowest virtual architecture that
supports all features we use. The PTX is forward-compatible: the driver
JIT-compiles it to whatever GPU is present at runtime. This lets us
ship the image without NVRTC (~100 MB).

The NVRTC version used here must not be newer than the CUDA driver on
the target cluster. NVRTC stamps a PTX ISA version into the output
header (e.g., NVRTC 13.2 emits `.version 9.2`), and the driver rejects
PTX with an ISA version it doesn't recognize — regardless of the
`--gpu-architecture` target. There is no flag to override the PTX ISA
version. The only solution is to use an NVRTC whose major.minor matches
or is older than the driver.

Example: GPU driver 580.105.08 reports CUDA version 13.0
(`cuDriverGetVersion() = 13000`). Using NVRTC 13.2 to compile the
kernel produces PTX that this driver rejects with
CUDA_ERROR_UNSUPPORTED_PTX_VERSION. NVRTC 13.0.x must be used instead.
"""

import sys
from cuda.bindings import nvrtc

def check(result):
    if result[0].value:
        raise RuntimeError(f"NVRTC error: {result[0]}")
    return result[1] if len(result) == 2 else result[1:]

# CUDA kernel that sums all float32 values in the input array.
#
# Design choices optimized for maximizing NVLink read bandwidth:
#
# - Plain double accumulation instead of Kahan compensated summation.
#   Kahan adds 3 extra ALU ops per load (subtract, add, subtract) which
#   throttles the rate at which threads can issue new memory requests.
#   Double precision (~15 decimal digits) is more than sufficient for
#   summing float32 values without compensation.
#
# - __ldg() intrinsic to route loads through the read-only texture cache
#   path, which can improve throughput for read-only access patterns.
#
# - 4x loop unrolling to increase instruction-level parallelism and keep
#   more memory requests in flight per thread.
#
# - Launched with 4 blocks per SM (set at runtime) to maximize occupancy
#   and give the warp scheduler enough warps to hide NVLink latency.
#
# Each block reduces to a partial sum in shared memory. The host sums the
# partial results (a few hundred doubles — trivial).
KERNEL_SRC = r"""
extern "C" __global__
void checksum(const float* __restrict__ data, int n, double* out) {
    __shared__ double ssum[256];
    int tid = threadIdx.x;
    int gid = blockIdx.x * blockDim.x + tid;
    int stride = blockDim.x * gridDim.x;
    double sum = 0.0;

    int i = gid;
    for (; i + 3 * stride < n; i += 4 * stride) {
        sum += (double)__ldg(&data[i]);
        sum += (double)__ldg(&data[i + stride]);
        sum += (double)__ldg(&data[i + 2 * stride]);
        sum += (double)__ldg(&data[i + 3 * stride]);
    }
    for (; i < n; i += stride) {
        sum += (double)__ldg(&data[i]);
    }

    ssum[tid] = sum;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s)
            ssum[tid] += ssum[tid + s];
        __syncthreads();
    }
    if (tid == 0)
        out[blockIdx.x] = ssum[0];
}
"""

prog = check(nvrtc.nvrtcCreateProgram(
    KERNEL_SRC.encode(), b"checksum.cu", 0, [], []))
try:
    check(nvrtc.nvrtcCompileProgram(prog, 1, [b"--gpu-architecture=compute_80"]))
except RuntimeError:
    log_size = check(nvrtc.nvrtcGetProgramLogSize(prog))
    log_buf = b" " * log_size
    check(nvrtc.nvrtcGetProgramLog(prog, log_buf))
    print(f"Compile failed:\n{log_buf.decode()}", file=sys.stderr)
    sys.exit(1)

ptx_size = check(nvrtc.nvrtcGetPTXSize(prog))
ptx = b" " * ptx_size
check(nvrtc.nvrtcGetPTX(prog, ptx))

with open("/ack/checksum.ptx", "wb") as f:
    f.write(ptx)

print(f"Wrote /ack/checksum.ptx ({len(ptx)} bytes)")
