#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"
if ! test -s "$SELECTED_FILE"; then
    echo 'No kernel selected.'
    exit 0
fi
load_selected_kernel
SRC=$(kernel_source_dir)
OUT=$(kernel_build_dir)
SYM=$(symvers_cache_file)
printf 'Selected version : %s\n' "$SELECTED_VERSION"
printf 'Source ref       : %s\n' "$SELECTED_REF"
printf 'Source remote    : %s\n' "$SELECTED_SOURCE_REMOTE"
printf 'Tag catalog sha  : %s\n' "${SELECTED_TAG_COMMIT:-<none>}"
printf 'CI build id      : %s\n' "${SELECTED_BUILD_ID:-<none>}"
printf 'Source cache     : %s [%s]\n' "$SRC" "$(test -f "$SRC/Makefile" && echo ready || echo missing)"
if test -f "$SRC/.multikernel-commit"; then printf 'Source commit    : %s\n' "$(cat "$SRC/.multikernel-commit")"; fi
printf 'Symvers cache    : %s [%s]\n' "$SYM" "$(is_valid_symvers "$SYM" && echo ready || echo missing)"
printf 'Kbuild output    : %s [%s]\n' "$OUT" "$(test -f "$OUT/include/config/auto.conf" && echo ready || echo missing)"
