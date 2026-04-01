"""Pre-compile the checksum CUDA kernel to PTX at image build time.

Compiles for compute_80 (Ampere) — the lowest virtual architecture that
supports all features we use. The PTX is forward-compatible: the driver
JIT-compiles it to whatever GPU is present at runtime. This lets us
ship the image without NVRTC (~100 MB).
"""

import sys
from cuda.bindings import nvrtc

def check(result):
    if result[0].value:
        raise RuntimeError(f"NVRTC error: {result[0]}")
    return result[1] if len(result) == 2 else result[1:]

# The kernel source is duplicated here (also in ack.py) to avoid import
# dependencies. It changes rarely.
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
