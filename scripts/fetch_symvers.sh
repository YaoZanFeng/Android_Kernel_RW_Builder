#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"
load_selected_kernel

usage() {
    cat <<USAGE
usage:
  $0                         # use the CI build id bound to the selected GKI release
  $0 --file LOCAL_FILE       # manually import Module.symvers/vmlinux.symvers
  $0 --build-id BUILD_ID     # override Android CI build id
  $0 --url URL               # download a custom symvers URL

Automatic mode never reads uname/current-phone information. The normal kernel
selector binds source and vmlinux.symvers to the same monthly GKI release.
USAGE
}

MODE=auto
VALUE=
while test "$#" -gt 0; do
    case "$1" in
        --file) test "$#" -ge 2 || die "--file requires a path"; MODE=file; VALUE=$2; shift 2 ;;
        --build-id) test "$#" -ge 2 || die "--build-id requires a value"; MODE=build; VALUE=$2; shift 2 ;;
        --url) test "$#" -ge 2 || die "--url requires a URL"; MODE=url; VALUE=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

DEST=$(symvers_cache_file)
mkdir -p "$(dirname -- "$DEST")"
LOCAL_IMPORT="$CACHE_ROOT/imports/$SELECTED_VERSION/Module.symvers"

if test "$MODE" = auto && is_valid_symvers "$DEST"; then
    printf 'Reusing cached Module.symvers:\n  %s\n' "$DEST"
    exit 0
fi

if test "$MODE" = auto && is_valid_symvers "$LOCAL_IMPORT"; then
    printf 'Using local imported Module.symvers:\n  %s\n' "$LOCAL_IMPORT"
    cp -f "$LOCAL_IMPORT" "$DEST"
    exit 0
fi

case "$MODE" in
    auto)
        BUILD_ID=${SELECTED_BUILD_ID:-}
        if test -z "$BUILD_ID"; then
            BUILD_ID=$(bash "$SCRIPT_DIR/remote_meta.sh" --build-id "$SELECTED_REF" 2>/dev/null || true)
        fi
        test -n "$BUILD_ID" || \
            die "selected release has no CI build id. Re-select a published GKI release or use --build-id/--url/--file."
        URL="https://ci.android.com/builds/submitted/$BUILD_ID/$SELECTED_CI_TARGET/latest/raw/vmlinux.symvers"
        ;;
    build)
        case "$VALUE" in *[!0-9]*|'') die "invalid build id: $VALUE";; esac
        URL="https://ci.android.com/builds/submitted/$VALUE/$SELECTED_CI_TARGET/latest/raw/vmlinux.symvers"
        ;;
    url) URL=$VALUE ;;
    file)
        test -f "$VALUE" || die "symvers file not found: $VALUE"
        tmp="$DEST.tmp.$$"
        cp -f "$VALUE" "$tmp"
        if ! is_valid_symvers "$tmp"; then
            rm -f "$tmp"
            die "file does not look like Module.symvers/vmlinux.symvers"
        fi
        mv -f "$tmp" "$DEST"
        printf 'Imported Module.symvers: %s\n' "$DEST"
        exit 0
        ;;
esac

tmp="$DEST.tmp.$$"
trap 'rm -f "$tmp"' EXIT INT TERM
printf 'Module.symvers download (same selected GKI release):\n  %s\n' "$URL"
if ! http_download "$URL" "$tmp"; then
    rm -f "$tmp"
    if is_valid_symvers "$LOCAL_IMPORT"; then
        printf 'Network artifact download failed; using local import:\n  %s\n' "$LOCAL_IMPORT"
        cp -f "$LOCAL_IMPORT" "$DEST"
        trap - EXIT INT TERM
        exit 0
    fi
    die "symvers download failed. Use --file /path/Module.symvers if you already have the matching file."
fi
if ! is_valid_symvers "$tmp"; then
    rm -f "$tmp"
    die "download is not a valid Module.symvers/vmlinux.symvers"
fi
mv -f "$tmp" "$DEST"
trap - EXIT INT TERM
printf 'Module.symvers ready: %s (%s lines)\n' "$DEST" "$(wc -l < "$DEST" | tr -d ' ')"
