#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/catalog_lib.sh"

case "${1:-}" in
    --refresh) refresh_refs ;;
    --series) list_series ;;
    --versions) test "$#" -eq 2 || die "usage: $0 --versions SERIES"; list_versions "$2" ;;
    --exact-refs) test "$#" -eq 2 || die "usage: $0 --exact-refs VERSION"; exact_android_refs "$2" ;;
    *)
        cat <<USAGE
usage:
  $0 --refresh
  $0 --series
  $0 --versions SERIES
  $0 --exact-refs VERSION
USAGE
        ;;
esac
