#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"
case "${1:-build}" in
    build)
        rm -rf "$BUILD_ROOT" "$BIN_ROOT"
        mkdir -p "$BUILD_ROOT" "$BIN_ROOT"
        echo 'Removed build/ and bin/. Cached kernel sources/symvers were kept.'
        ;;
    all)
        rm -rf "$BUILD_ROOT" "$BIN_ROOT" "$CACHE_ROOT" "$STATE_ROOT"
        mkdir -p "$BUILD_ROOT" "$BIN_ROOT" "$CACHE_ROOT" "$STATE_ROOT" "$CATALOG_DIR"
        echo 'Removed build/, bin/, cache/, and selection state.'
        ;;
    *) die "usage: $0 [build|all]" ;;
esac
