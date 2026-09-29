#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"
find "$WORKSPACE_ROOT/modules" -mindepth 1 -maxdepth 1 -type d -print \
  | while IFS= read -r d; do
        if test -f "$d/Kbuild" -o -f "$d/Makefile"; then basename -- "$d"; fi
    done | sort
