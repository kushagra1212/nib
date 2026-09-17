# llvm-mingw gives one toolchain that targets both Windows arches, links a
# self-contained C++ runtime, and needs no Microsoft SDK download. The engines
# nib loads all expose a C ABI, so the MinGW/MSVC ABI split does not reach us.
FROM ubuntu:24.04

ARG LLVM_MINGW_VERSION=20250528
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl xz-utils ca-certificates cmake ninja-build python3 git \
    && rm -rf /var/lib/apt/lists/*

# The release is published per build-host arch, and this image runs both under
# Docker on Apple silicon (aarch64) and on GitHub's ubuntu runners (x86_64).
# Selecting by uname rather than hardcoding keeps one Dockerfile for both.
RUN set -eux; \
    case "$(uname -m)" in \
      aarch64) HOST=aarch64 ;; \
      x86_64)  HOST=x86_64 ;; \
      *) echo "unsupported build host: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/llvm-mingw.tar.xz \
      "https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-ubuntu-22.04-${HOST}.tar.xz"; \
    mkdir -p /opt/llvm-mingw; \
    tar -xJf /tmp/llvm-mingw.tar.xz -C /opt/llvm-mingw --strip-components=1; \
    rm /tmp/llvm-mingw.tar.xz

ENV PATH="/opt/llvm-mingw/bin:${PATH}"
WORKDIR /src
