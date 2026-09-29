#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

test "$#" -eq 1 || die "usage: $0 MODULE"
MODULE_DIR=$(resolve_module_dir "$1")
MODULE_NAME=$(basename -- "$MODULE_DIR")
USER_SRC="$MODULE_DIR/user"
test -d "$USER_SRC" || die "module has no user/ directory: $MODULE_NAME"
need_command make
need_command rsync

USER_BUILD="$BUILD_ROOT/user/$MODULE_NAME"
USER_BIN="$BIN_ROOT/user/$MODULE_NAME"
rm -rf "$USER_BUILD"
mkdir -p "$USER_BUILD" "$USER_BIN"
rsync -a --exclude='*.o' --exclude='*.a' --exclude='kernel_rw_test' "$USER_SRC/" "$USER_BUILD/"
make -C "$USER_BUILD" clean >/dev/null 2>&1 || true
make -C "$USER_BUILD" -j"$JOBS"

find "$USER_BUILD" -maxdepth 1 -type f \( -perm -0100 -o -name '*.a' \) -print \
  | while IFS= read -r f; do cp -f "$f" "$USER_BIN/"; done
printf 'User binaries: %s\n' "$USER_BIN"
find "$USER_BIN" -maxdepth 1 -type f -print | sort
