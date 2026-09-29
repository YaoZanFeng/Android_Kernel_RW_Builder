#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

META_FILE="$CATALOG_DIR/ref-meta.tsv"
META_REPO="$CATALOG_DIR/meta-git"
mkdir -p "$CATALOG_DIR"
touch "$META_FILE"

cache_get() {
    local ref=$1 field=$2 col
    case "$field" in
        version) col=2 ;;
        build_id) col=3 ;;
        *) return 1 ;;
    esac
    awk -F '\t' -v r="$ref" -v c="$col" '$1==r {print $c; exit}' "$META_FILE"
}

cache_put() {
    local ref=$1 version=$2 build_id=$3 tmp="$META_FILE.tmp.$$"
    awk -F '\t' -v r="$ref" '$1!=r' "$META_FILE" > "$tmp" || true
    printf '%s\t%s\t%s\n' "$ref" "$version" "$build_id" >> "$tmp"
    mv -f "$tmp" "$META_FILE"
}

parse_version_from_makefile_text() {
    local raw=$1 v p s
    v=$(printf '%s\n' "$raw" | awk '$1=="VERSION" && $2=="=" {print $3; exit}')
    p=$(printf '%s\n' "$raw" | awk '$1=="PATCHLEVEL" && $2=="=" {print $3; exit}')
    s=$(printf '%s\n' "$raw" | awk '$1=="SUBLEVEL" && $2=="=" {print $3; exit}')
    test -n "$v" -a -n "$p" -a -n "$s" || return 1
    printf '%s.%s.%s\n' "$v" "$p" "$s"
}

extract_build_id() {
    grep -oE 'ci\.android\.com/builds/submitted/[0-9]+/kernel_aarch64/latest' \
        | head -n1 \
        | sed -n 's#.*submitted/\([0-9][0-9]*\)/.*#\1#p'
}

prepare_meta_repo() {
    if ! test -d "$META_REPO/.git"; then
        rm -rf "$META_REPO"
        mkdir -p "$META_REPO"
        git -C "$META_REPO" init -q
    fi
}

set_meta_remote() {
    local remote=$1
    git -C "$META_REPO" remote remove origin >/dev/null 2>&1 || true
    git -C "$META_REPO" remote add origin "$remote"
    # Mark the remote as a promisor so a later git-show may lazily request only
    # the one missing Makefile blob instead of checking out the source tree.
    git -C "$META_REPO" config remote.origin.promisor true
    git -C "$META_REPO" config remote.origin.partialclonefilter blob:none
}

fetch_meta_ref_from() {
    local remote=$1 ref=$2 local_ref='refs/multikernel/probe'

    set_meta_remote "$remote"
    git -C "$META_REPO" update-ref -d "$local_ref" >/dev/null 2>&1 || true

    # blob:none transfers commit/tag/tree metadata only. Kernel source blobs are
    # intentionally excluded. Nearby probes reuse the same object cache.
    git_with_dns_fallback "$remote" \
        -C "$META_REPO" \
        -c protocol.version=2 \
        -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=15 \
        fetch --quiet --no-tags --depth=1 --filter=blob:none \
        origin "$ref:$local_ref"
}

probe_ref_git_from() {
    local remote=$1 ref=$2
    local local_ref='refs/multikernel/probe' makefile version object_type tag_text build_id

    prepare_meta_repo
    fetch_meta_ref_from "$remote" "$ref" || return 1

    # git_with_dns_fallback is also used for git show/cat-file: if the Makefile
    # blob was filtered out, Git's promisor fetch inherits the temporary DNS
    # override and retrieves only that required blob.
    makefile=$(git_with_dns_fallback "$remote" -C "$META_REPO" show "${local_ref}^{commit}:Makefile" 2>/dev/null) || return 1
    version=$(parse_version_from_makefile_text "$makefile") || return 1

    build_id=
    object_type=$(git -C "$META_REPO" cat-file -t "$local_ref" 2>/dev/null || true)
    if test "$object_type" = tag; then
        tag_text=$(git -C "$META_REPO" cat-file -p "$local_ref" 2>/dev/null || true)
        if test -n "$tag_text"; then
            build_id=$(printf '%s\n' "$tag_text" | extract_build_id || true)
        fi
    fi

    cache_put "$ref" "$version" "${build_id:--}"
}

probe_ref_git() {
    local ref=$1
    if probe_ref_git_from "$KERNEL_REMOTE" "$ref"; then
        return 0
    fi
    if test -n "${KERNEL_REMOTE_FALLBACK:-}" && test "$KERNEL_REMOTE_FALLBACK" != "$KERNEL_REMOTE"; then
        probe_ref_git_from "$KERNEL_REMOTE_FALLBACK" "$ref" && return 0
    fi
    return 1
}

# Last-resort lightweight HTTP path. It is intentionally secondary because
# some network setups can use Git HTTPS while Gitiles +show requests
# fail. No kernel source is downloaded here either.
gitiles_base_url() {
    local remote=${1%/}
    remote=${remote%.git}
    case "$remote" in
        https://android.googlesource.com/*|http://android.googlesource.com/*)
            printf '%s\n' "$remote"
            ;;
        *) return 1 ;;
    esac
}

decode_gitiles_text() {
    if have_command base64; then
        base64 -d
    elif have_command openssl; then
        openssl base64 -d -A
    else
        return 1
    fi
}

http_get_meta() {
    local url=$1
    if have_command curl; then
        curl_with_dns_fallback "$url" -fsSL --retry 1 --retry-delay 1 --retry-all-errors \
            --connect-timeout 4 --max-time 12
    elif have_command wget; then
        wget -qO- --timeout=6 --read-timeout=12 --tries=2 "$url"
    else
        return 1
    fi
}

probe_ref_gitiles() {
    local remote=$1 ref=$2 base encoded raw version json html build_id
    base=$(gitiles_base_url "$remote") || return 1

    encoded=$(http_get_meta "$base/+show/$ref/Makefile?format=TEXT") || return 1
    raw=$(printf '%s' "$encoded" | tr -d '\r\n' | decode_gitiles_text 2>/dev/null) || return 1
    version=$(parse_version_from_makefile_text "$raw") || return 1

    build_id=
    json=$(http_get_meta "$base/+show/$ref?format=JSON" 2>/dev/null || true)
    if test -n "$json"; then
        build_id=$(printf '%s\n' "$json" | extract_build_id || true)
    fi
    if test -z "$build_id"; then
        html=$(http_get_meta "$base/+/$ref" 2>/dev/null || true)
        if test -n "$html"; then
            build_id=$(printf '%s\n' "$html" | extract_build_id || true)
        fi
    fi

    cache_put "$ref" "$version" "${build_id:--}"
}

probe_ref() {
    local ref=$1

    # Primary metadata path: Git partial fetch. This uses the same transport as
    # the already-successful tag catalog, but filters out kernel source blobs.
    if probe_ref_git "$ref"; then
        return 0
    fi

    # Optional HTTP fallback. Still metadata-only; never checkout/fetch source.
    if probe_ref_gitiles "$KERNEL_REMOTE" "$ref"; then
        return 0
    fi

    warn "metadata lookup failed for $ref"
    return 1
}

remote_kernel_version() {
    local ref=$1 value
    value=$(cache_get "$ref" version || true)
    if test -z "$value" || test "$value" = '-'; then
        probe_ref "$ref" || return 1
        value=$(cache_get "$ref" version || true)
    fi
    test -n "$value" -a "$value" != '-' || return 1
    printf '%s\n' "$value"
}

remote_build_id() {
    local ref=$1 value
    value=$(cache_get "$ref" build_id || true)
    if test -z "$value" || test "$value" = '-'; then
        probe_ref "$ref" || return 1
        value=$(cache_get "$ref" build_id || true)
    fi
    test -n "$value" -a "$value" != '-' || return 1
    printf '%s\n' "$value"
}

case "${1:-}" in
    --version) test "$#" -eq 2 || exit 2; remote_kernel_version "$2" ;;
    --build-id) test "$#" -eq 2 || exit 2; remote_build_id "$2" ;;
    *) echo "usage: $0 --version REF | --build-id REF" >&2; exit 2 ;;
esac
