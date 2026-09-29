#!/usr/bin/env bash
set -euo pipefail
pkg update
pkg install -y clang lld llvm make git curl wget rsync python coreutils
cat <<'MSG'
Termux dependencies installed.

For user-space examples, Termux is fine.
For kernel source preparation/Kbuild host tools, a standard Ubuntu/Debian
environment is recommended because Android/Bionic can be incompatible with older
kernel host tools (for example bcmp-related kconfig link failures).
MSG
