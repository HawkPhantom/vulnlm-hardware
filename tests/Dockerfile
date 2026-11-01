FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential linux-headers-arm64 device-tree-compiler python3 tcl iverilog \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /work
