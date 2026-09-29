#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

usage() {
    cat <<USAGE
usage:
  $0 --list
  $0 MODULE

Builds only the selected external module. Intermediate files go to build/;
final .ko files go to bin/modules/<kernel-version>/ and are suffixed with the
selected exact kernel version (dots become underscores).
USAGE
}

if test "${1:-}" = --list; then exec bash "$SCRIPT_DIR/list_modules.sh"; fi
test "$#" -eq 1 || { usage >&2; exit 2; }

load_selected_kernel
check_prepared_kernel
need_command make
need_command rsync
need_command clang
need_command ld.lld

SRC=$(kernel_source_dir)
KOUT=$(kernel_build_dir)
SYM=$(symvers_cache_file)
if ! is_valid_symvers "$SYM"; then
    die "missing cached Module.symvers for $SELECTED_VERSION; run scripts/fetch_symvers.sh"
fi
cp -f "$SYM" "$KOUT/Module.symvers"

MODULE_DIR=$(resolve_module_dir "$1")
MODULE_NAME=$(basename -- "$MODULE_DIR")
OUTPUT_BASE=$(module_output_basename "$MODULE_DIR")
VER_TAG=$(version_key "$SELECTED_VERSION")
MODULE_BUILD="$BUILD_ROOT/modules/$SELECTED_VERSION/$MODULE_NAME"
MODULE_BIN="$BIN_ROOT/modules/$SELECTED_VERSION"

rm -rf "$MODULE_BUILD"
mkdir -p "$MODULE_BUILD" "$MODULE_BIN"

rsync -a \
  --exclude='/user/' \
  --exclude='*.o' --exclude='*.ko' --exclude='*.mod' --exclude='*.mod.c' \
  --exclude='*.a' --exclude='.*.cmd' --exclude='Module.symvers' \
  --exclude='modules.order' --exclude='.tmp_versions/' \
  "$MODULE_DIR/" "$MODULE_BUILD/"

printf 'Building external module only:\n'
printf '  kernel : %s\n  module : %s\n  source : %s\n  build  : %s\n' \
  "$SELECTED_VERSION" "$MODULE_NAME" "$MODULE_DIR" "$MODULE_BUILD"

make -C "$SRC" O="$KOUT" -j"$JOBS" \
  ARCH="$ARCH" LLVM="$LLVM" LLVM_IAS="$LLVM_IAS" \
  M="$MODULE_BUILD" modules

mapfile -t KOS < <(find "$MODULE_BUILD" -type f -name '*.ko' -print | sort)
test "${#KOS[@]}" -gt 0 || die "build completed but no .ko was produced"

# Remove only binaries produced for this module/version, never source/intermediates.
rm -f "$MODULE_BIN/${OUTPUT_BASE}_${VER_TAG}.ko" 2>/dev/null || true

if test "${#KOS[@]}" -eq 1; then
    DEST="$MODULE_BIN/${OUTPUT_BASE}_${VER_TAG}.ko"
    cp -f "${KOS[0]}" "$DEST"
    printf '\nBinary output:\n  %s\n' "$DEST"
else
    printf '\nBinary outputs:\n'
    for ko in "${KOS[@]}"; do
        original=$(basename -- "$ko" .ko)
        DEST="$MODULE_BIN/${original}_${VER_TAG}.ko"
        cp -f "$ko" "$DEST"
        printf '  %s\n' "$DEST"
    done
fi
