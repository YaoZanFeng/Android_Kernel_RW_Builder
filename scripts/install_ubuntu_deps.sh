#!/usr/bin/env bash
set -euo pipefail
if test "$(id -u)" -ne 0; then
    echo 'Run this on Ubuntu/Debian as root.' >&2
    exit 1
fi
apt update
DEBIAN_FRONTEND=noninteractive apt install -y \
    build-essential clang lld llvm make git curl wget rsync \
    bc bison flex libssl-dev libelf-dev dwarves cpio kmod \
    python3 perl openssl ca-certificates coreutils
