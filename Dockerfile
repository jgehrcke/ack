FROM nvidia/cuda:13.2.0-base-ubuntu24.04

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

RUN mkdir /ack
WORKDIR /ack

RUN uv venv .venv --python 3.13
ENV PATH="/ack/.venv/bin:${PATH}"
RUN uv pip install cuda-python[all]==13.2.0 dnspython orjson pyzstd py-spy yappi

COPY ./ack.py /ack

ENTRYPOINT []
