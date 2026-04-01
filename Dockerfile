FROM nvidia/cuda:13.2.0-base-ubuntu24.04

# Install Ubuntu 24's system Python (3.12).
RUN <<EOT
    apt update -qy
    apt install -qyy python3.12 python3.12-venv
    apt clean
    rm -rf /var/lib/apt/lists/*

EOT

RUN mkdir /ack
WORKDIR /ack

RUN python3.12 -m venv .venv
ENV PATH="/ack/.venv/bin:${PATH}"
RUN pip install cuda-python[all]==13.2.0 dnspython orjson zstandard py-spy yappi

COPY ./ack.py /ack

ENTRYPOINT []
