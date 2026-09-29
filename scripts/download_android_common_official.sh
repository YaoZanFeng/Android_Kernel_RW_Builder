#!/usr/bin/env bash
set -euo pipefail

REPO_URL=${KERNEL_REMOTE:-https://android.googlesource.com/kernel/common}
FALLBACK_URL=${KERNEL_REMOTE_FALLBACK:-https://mirrors.tuna.tsinghua.edu.cn/git/AOSP/kernel/common}
DEST_ROOT="${ANDROID_KERNEL_DEST:-$PWD/android-common-sources}"

usage() {
    cat <<'USAGE'
Android Common Kernel exact-tag source downloader

Usage:
  bash scripts/download_android_common_official.sh --list 5.15.180
  bash scripts/download_android_common_official.sh 5.15.180 5.10.198 6.1.112
  bash scripts/download_android_common_official.sh android13-5.15.180_r00

Set output directory with ANDROID_KERNEL_DEST:
  ANDROID_KERNEL_DEST="$PWD/kernels" bash scripts/download_android_common_official.sh 5.15.180

A numeric version is auto-selected only when exactly one official tag matches.
If multiple Android branches contain that version, pass a complete tag.
USAGE
}

need() {
    command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }
}
need git; need awk; need sed; need sort

if [[ $# -eq 0 ]]; then usage; exit 2; fi
MODE=fetch
if [[ "${1:-}" == --list ]]; then MODE=list; shift; fi
[[ $# -gt 0 ]] || { usage; exit 2; }

TAGS_FILE=$(mktemp "${TMPDIR:-/tmp}/android-common-tags.XXXXXX")
trap 'rm -f "$TAGS_FILE"' EXIT

echo "Reading Android Common Kernel tags..."
if ! git ls-remote --tags "$REPO_URL" > "$TAGS_FILE"; then
    echo "Official endpoint failed; using fallback mirror: $FALLBACK_URL" >&2
    git ls-remote --tags "$FALLBACK_URL" > "$TAGS_FILE"
fi

tag_exists() {
    awk -v ref="refs/tags/$1" '$2 == ref { found=1 } END { exit !found }' "$TAGS_FILE"
}

tags_for_version() {
    local version=$1
    awk -v suffix="-$version" '
        $2 !~ /\^\{\}$/ {
            ref=$2
            sub(/^refs\/tags\//, "", ref)
            if (ref ~ /^android[0-9]*-/ && index(ref, suffix "_r") > 0)
                print ref
        }
    ' "$TAGS_FILE" | grep -E "^android[0-9]*-${version//./\\.}_r[0-9]+$" | sort -V
}

resolve_tag() {
    local spec=$1 matches count
    if [[ "$spec" =~ ^android[0-9]*-[456]\.[0-9]+\.[0-9]+_r[0-9]+$ ]]; then
        tag_exists "$spec" || { echo "tag does not exist: $spec" >&2; return 1; }
        printf '%s\n' "$spec"
        return
    fi
    [[ "$spec" =~ ^[456]\.[0-9]+\.[0-9]+$ ]] || { echo "invalid version: $spec" >&2; return 1; }
    matches=$(tags_for_version "$spec")
    [[ -n "$matches" ]] || { echo "version not found: $spec" >&2; return 1; }
    count=$(printf '%s\n' "$matches" | wc -l | tr -d ' ')
    if [[ "$count" -ne 1 ]]; then
        echo "version $spec has multiple official tags; choose one:" >&2
        while IFS= read -r t; do printf '  %s\n' "$t" >&2; done <<< "$matches"
        return 1
    fi
    printf '%s\n' "$matches"
}

if [[ "$MODE" == list ]]; then
    for version in "$@"; do
        echo "[$version]"
        tags_for_version "$version"
    done
    exit 0
fi

mkdir -p "$DEST_ROOT"
for spec in "$@"; do
    tag=$(resolve_tag "$spec")
    target="$DEST_ROOT/$tag"
    echo
    echo "requested : $spec"
    echo "tag       : $tag"
    echo "repo      : $REPO_URL"
    if [[ -e "$target" ]]; then
        echo "already exists; not overwritten: $target" >&2
        continue
    fi

    mkdir -p "$target"
    git -C "$target" init -q
    git -C "$target" remote add origin "$REPO_URL"
    if ! git -C "$target" fetch --depth=1 --no-tags origin "refs/tags/$tag"; then
        echo "official fetch failed; trying fallback mirror" >&2
        git -C "$target" remote set-url origin "$FALLBACK_URL"
        git -C "$target" fetch --depth=1 --no-tags origin "refs/tags/$tag"
    fi
    git -C "$target" checkout -q --detach FETCH_HEAD

    version=$(awk '
        /^VERSION =/ {v=$3}
        /^PATCHLEVEL =/ {p=$3}
        /^SUBLEVEL =/ {s=$3}
        END {print v "." p "." s}
    ' "$target/Makefile")
    commit=$(git -C "$target" rev-parse HEAD)
    echo "done      : $target"
    echo "version   : $version"
    echo "commit    : $commit"
done
