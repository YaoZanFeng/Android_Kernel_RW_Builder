#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"
load_selected_kernel
need_command git

SRC=$(kernel_source_dir)
META_REF="$SRC/.multikernel-ref"
META_COMMIT="$SRC/.multikernel-commit"

printf 'Kernel source request:\n'
printf '  version : %s\n' "$SELECTED_VERSION"
printf '  repo    : %s\n' "$KERNEL_REMOTE"
printf '  ref     : %s\n' "$SELECTED_REF"
printf '  cache   : %s\n' "$SRC"

if test -f "$SRC/Makefile" -a -f "$META_REF"; then
    old_ref=$(cat "$META_REF" 2>/dev/null || true)
    old_ver=$(read_kernel_version_from_makefile "$SRC/Makefile" || true)
    if test "$old_ref" = "$SELECTED_REF" && test "$old_ver" = "$SELECTED_VERSION"; then
        printf 'Reusing cached kernel source.\n'
        if test -f "$META_COMMIT"; then printf '  commit  : %s\n' "$(cat "$META_COMMIT")"; fi
        exit 0
    fi
fi

TMP="$SRC.tmp.$$"
rm -rf "$TMP"
mkdir -p "$(dirname -- "$SRC")" "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

git -C "$TMP" init -q

fetch_from() {
    local remote=$1
    git -C "$TMP" remote remove origin >/dev/null 2>&1 || true
    git -C "$TMP" remote add origin "$remote"
    printf 'Downloading exact source ref:\n'
    printf '  remote : %s\n' "$remote"
    printf '  ref    : %s\n' "$SELECTED_REF"
    printf '  command: git fetch --depth=1 --no-tags origin %s\n' "$SELECTED_REF"
    git_with_dns_fallback "$remote" \
        -C "$TMP" -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=30 \
        fetch --depth=1 --no-tags origin "$SELECTED_REF"
}

if ! fetch_from "$KERNEL_REMOTE"; then
    printf 'Official source fetch failed; trying fallback mirror:\n  %s\n' "$KERNEL_REMOTE_FALLBACK" >&2
    if ! fetch_from "$KERNEL_REMOTE_FALLBACK"; then
        die "kernel source download failed from both configured Git remotes"
    fi
fi

git -C "$TMP" checkout -q --detach FETCH_HEAD

actual=$(read_kernel_version_from_makefile "$TMP/Makefile" || true)
test "$actual" = "$SELECTED_VERSION" || die "downloaded source reports $actual, expected $SELECTED_VERSION"
commit=$(git -C "$TMP" rev-parse HEAD)

# Write builder metadata before moving the completed cache into place.
printf '%s\n' "$SELECTED_REF" > "$TMP/.multikernel-ref"
printf '%s\n' "$commit" > "$TMP/.multikernel-commit"

rm -rf "$SRC"
mv "$TMP" "$SRC"
trap - EXIT INT TERM

printf 'Source ready:\n'
printf '  path   : %s\n' "$SRC"
printf '  version: %s\n' "$actual"
printf '  commit : %s\n' "$commit"
