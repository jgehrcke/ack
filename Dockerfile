FROM ubuntu:24.04 AS build

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

WORKDIR /ack

RUN uv venv .venv --python 3.13

# cuda-bindings: Python bindings for the CUDA driver API.
# nvidia-cuda-nvrtc: only needed at build time to pre-compile the
# checksum kernel to PTX. Not included in the final image (~100 MB).
# Not using cuda-python[all] — it pulls ~250 MB of libs we don't need
# (nvjitlink, nvvm, cufile, nvfatbin).
RUN uv pip install \
    cuda-bindings==13.2.0 \
    "nvidia-cuda-nvrtc>=13.0,<13.1" \
    dnspython orjson pyzstd py-spy yappi

# Pre-compile the checksum kernel to PTX for compute_80 (Ampere).
# PTX is forward-compatible — the driver JIT-compiles it to the
# target GPU at runtime.
COPY compile_kernel.py /ack/
RUN .venv/bin/python compile_kernel.py

# Remove NVRTC from the venv — it's no longer needed at runtime.
RUN rm -rf .venv/lib/python3.13/site-packages/nvidia

FROM ubuntu:24.04

COPY --from=build /root/.local/share/uv/python /root/.local/share/uv/python
COPY --from=build /ack/.venv /ack/.venv
COPY --from=build /ack/checksum.ptx /ack/
COPY ./ack.py /ack/

ENV PATH="/ack/.venv/bin:${PATH}"
WORKDIR /ack
ENTRYPOINT []
