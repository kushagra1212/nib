# llvm-mingw gives one toolchain that targets both Windows arches, links a
# self-contained C++ runtime, and needs no Microsoft SDK download. The engines
# nib loads all expose a C ABI, so the MinGW/MSVC ABI split does not reach us.
FROM ubuntu:24.04

ARG LLVM_MINGW_VERSION=20250528
# Pinned to the version Homebrew installs on the development Mac. Sentence
# segmentation is ICU's, so two ICU versions would mean the two platforms
# disagreeing about where sentences end -- which is the drift the shared core
# exists to prevent.
ARG ICU_VERSION=78.3
ARG ICU_UNDERSCORE=78_3

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl xz-utils ca-certificates cmake ninja-build python3 git \
      build-essential autoconf pkg-config file \
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

# ICU, built here rather than installed.
#
# apt's libicu-dev is Linux-only, and there is no Windows ICU package for this
# toolchain. ICU also cannot be cross-compiled on its own: its build runs tools
# it has just built to generate data, so a native build has to exist first and
# be handed to the cross builds with --with-cross-build.
#
# Static, so the DLL nib ships carries its own ICU and there are no loose
# icu*.dll files next to it that Windows might resolve to a different copy.
RUN set -eux; \
    curl -fsSL -o /tmp/icu.tgz \
      "https://github.com/unicode-org/icu/releases/download/release-${ICU_VERSION}/icu4c-${ICU_VERSION}-sources.tgz"; \
    mkdir -p /build && tar -xzf /tmp/icu.tgz -C /build && rm /tmp/icu.tgz; \
    # Native build first: only its tools are used, so it is never installed.
    mkdir -p /build/icu-native && cd /build/icu-native; \
    /build/icu/source/configure \
        --disable-tests --disable-samples --disable-extras >/dev/null; \
    make -j"$(nproc)" >/dev/null; \
    for arch in x86_64 aarch64; do \
      mkdir -p "/build/icu-$arch" && cd "/build/icu-$arch"; \
      /build/icu/source/configure \
        --host="$arch-w64-mingw32" \
        --with-cross-build=/build/icu-native \
        --prefix="/opt/icu/$arch" \
        --enable-static --disable-shared \
        --disable-tests --disable-samples --disable-extras \
        CC="$arch-w64-mingw32-clang" \
        CXX="$arch-w64-mingw32-clang++" \
        AR=llvm-ar RANLIB=llvm-ranlib >/dev/null; \
      make -j"$(nproc)" >/dev/null; \
      make install >/dev/null; \
    done; \
    rm -rf /build

WORKDIR /src
