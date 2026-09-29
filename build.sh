#!/usr/bin/env bash
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$ROOT/scripts/common.sh"

usage() {
    cat <<USAGE
usage:
  bash build.sh                         # interactive kernel + module chooser
  bash build.sh VERSION MODULE          # e.g. 5.15.180 kernel_rw
  bash build.sh --reuse MODULE          # reuse currently selected kernel
  bash build.sh --list-kernels          # show exact-tag 4.x-6.x series from Android common
  bash build.sh --status
USAGE
}

choose_module() {
    mapfile -t mods < <(bash "$ROOT/scripts/list_modules.sh")
    test "${#mods[@]}" -gt 0 || die "no modules found"
    local i n
    printf '\nAvailable modules:\n' >&2
    for i in "${!mods[@]}"; do printf '%3d) %s\n' "$((i+1))" "${mods[$i]}" >&2; done
    while :; do
        printf 'Choose module: ' >&2
        IFS= read -r n
        if printf '%s\n' "$n" | grep -Eq '^[0-9]+$' && test "$n" -ge 1 && test "$n" -le "${#mods[@]}"; then
            printf '%s\n' "${mods[$((n-1))]}"
            return
        fi
        echo 'Invalid choice.' >&2
    done
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --list-kernels)
        echo 'Android common kernel series discovered from the repository:'
        bash "$ROOT/scripts/catalog.sh" --series
        exit 0
        ;;
    --status) exec bash "$ROOT/scripts/status.sh" ;;
    --reuse)
        test "$#" -eq 2 || die "usage: bash build.sh --reuse MODULE"
        MODULE=$2
        load_selected_kernel
        ;;
    '')
        bash "$ROOT/scripts/select_kernel.sh"
        MODULE=$(choose_module)
        ;;
    *)
        test "$#" -eq 2 || { usage >&2; exit 2; }
        bash "$ROOT/scripts/select_kernel.sh" "$1"
        MODULE=$2
        ;;
esac

printf '\nEnsuring selected kernel dependencies...\n'
bash "$ROOT/scripts/ensure_kernel.sh"
printf '\nBuilding selected module...\n'
bash "$ROOT/scripts/build_external_module.sh" "$MODULE"
