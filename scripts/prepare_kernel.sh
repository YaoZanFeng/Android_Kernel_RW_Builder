#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"
load_selected_kernel

KEEP_CONFIG=0
case "${1:-}" in
    '') ;;
    --keep-config) KEEP_CONFIG=1 ;;
    *) die "usage: $0 [--keep-config]" ;;
esac

SRC=$(kernel_source_dir)
OUT=$(kernel_build_dir)
SYM=$(symvers_cache_file)
test -f "$SRC/Makefile" || die "kernel source missing; run scripts/fetch_kernel_source.sh"

for tool in make clang ld.lld flex bison perl python3 openssl; do need_command "$tool"; done
mkdir -p "$OUT"

if test "$KEEP_CONFIG" -eq 0 || ! test -f "$OUT/.config"; then
    if test -f "$SRC/arch/$ARCH/configs/gki_defconfig"; then
        DEFCONFIG=gki_defconfig
    else
        DEFCONFIG=defconfig
    fi
    printf 'Configuring %s with %s ...\n' "$SELECTED_VERSION" "$DEFCONFIG"
    kernel_make "$DEFCONFIG"
else
    printf 'Reusing existing config: %s/.config\n' "$OUT"
fi

# These settings avoid host distribution signing-key/BTF dependencies for an
# external-module development tree. Older kernels may not support every knob.
if test -x "$SRC/scripts/config"; then
    if ! have_command pahole; then
        "$SRC/scripts/config" --file "$OUT/.config" --disable DEBUG_INFO_BTF 2>/dev/null || true
    fi
    "$SRC/scripts/config" --file "$OUT/.config" --set-str SYSTEM_TRUSTED_KEYS "" 2>/dev/null || true
    "$SRC/scripts/config" --file "$OUT/.config" --set-str SYSTEM_REVOCATION_KEYS "" 2>/dev/null || true
fi

kernel_make olddefconfig
kernel_make prepare modules_prepare

if is_valid_symvers "$SYM"; then
    cp -f "$SYM" "$OUT/Module.symvers"
    printf 'Installed cached symvers into Kbuild tree.\n'
else
    warn "Module.symvers is not cached yet. Run scripts/fetch_symvers.sh before building modules."
fi

printf '\nPrepared external-module Kbuild tree only (no Image/modules full build):\n'
printf '  version: %s\n  source:  %s\n  build:   %s\n' "$SELECTED_VERSION" "$SRC" "$OUT"
