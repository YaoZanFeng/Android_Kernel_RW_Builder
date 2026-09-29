#!/usr/bin/env bash
# Library: requires common.sh to be sourced first.
REFS_FILE="$CATALOG_DIR/refs.txt"

query_refs_from() {
    local remote=$1 out=$2
    git_with_dns_fallback "$remote" \
        -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=30 \
        ls-remote --tags "$remote" > "$out"
}

refresh_refs() {
    need_command git
    local tmp="$REFS_FILE.tmp.$$"
    printf 'Reading official Android Common Kernel tags from:\n  %s\n' "$KERNEL_REMOTE" >&2
    if ! query_refs_from "$KERNEL_REMOTE" "$tmp"; then
        rm -f "$tmp"
        printf 'Official Git endpoint failed; trying fallback mirror:\n  %s\n' "$KERNEL_REMOTE_FALLBACK" >&2
        query_refs_from "$KERNEL_REMOTE_FALLBACK" "$tmp" || die "unable to query Android Common Kernel tags"
    fi
    test -s "$tmp" || die "remote returned no tags"
    mv -f "$tmp" "$REFS_FILE"
}

refs_are_stale() {
    test -s "$REFS_FILE" || return 0
    if find "$REFS_FILE" -mmin +360 -print -quit 2>/dev/null | grep -q .; then
        return 0
    fi
    return 1
}

ensure_refs() {
    if refs_are_stale; then
        refresh_refs
    fi
    return 0
}

# Only expose exact official Android version tags of the form:
#   android13-5.15.180_r00
# This deliberately excludes monthly tags/branch names so choosing 5.15.180
# never triggers a month-by-month resolver.
list_exact_version_tags() {
    ensure_refs
    awk '$2 !~ /\^\{\}$/ {print $2}' "$REFS_FILE" \
      | grep -E '^refs/tags/android([0-9]+)?-[456]\.[0-9]+\.[0-9]+_r[0-9]+$' \
      | sort -Vu
}

list_series() {
    list_exact_version_tags \
      | sed -E -n 's#^refs/tags/android([0-9]+)?-([456]\.[0-9]+)\.[0-9]+_r[0-9]+$#\2#p' \
      | sort -Vu
}

list_versions() {
    local series=$1 esc
    esc=$(printf '%s' "$series" | sed 's/\./\\./g')
    list_exact_version_tags \
      | sed -E -n 's#^refs/tags/android([0-9]+)?-('"$esc"'\.[0-9]+)_r[0-9]+$#\2#p' \
      | sort -Vu
}

exact_android_refs() {
    local version=$1 esc
    esc=$(printf '%s' "$version" | sed 's/\./\\./g')
    list_exact_version_tags \
      | grep -E "^refs/tags/android([0-9]+)?-${esc}_r[0-9]+$" \
      | sort -V
}

tag_commit_from_catalog() {
    local ref=$1 sha
    ensure_refs
    sha=$(awk -v r="$ref" '$2==r {print $1; exit}' "$REFS_FILE")
    test -n "$sha" || return 1
    printf '%s\n' "$sha"
}

# Published monthly GKI release tags, for example:
#   refs/tags/android13-5.15-2024-11_r2
monthly_release_refs() {
    local android_branch=$1 series=$2 branch_re series_re
    branch_re=$(printf '%s' "$android_branch" | sed 's/[][\\.^$*+?{}|()]/\\&/g')
    series_re=$(printf '%s' "$series" | sed 's/\./\\./g')
    ensure_refs
    awk '$2 !~ /\^\{\}$/ {print $2}' "$REFS_FILE" \
      | grep -E "^refs/tags/${branch_re}-${series_re}-[0-9]{4}-[0-9]{2}_r[0-9]+$" \
      | sort -V
}

monthly_release_prefixes() {
    local android_branch=$1 series=$2
    monthly_release_refs "$android_branch" "$series" \
      | sed -E 's/_r[0-9]+$//' \
      | sort -Vu
}

monthly_refs_for_prefix() {
    local prefix=$1 prefix_re
    prefix_re=$(printf '%s' "$prefix" | sed 's/[][\\.^$*+?{}|()]/\\&/g')
    ensure_refs
    awk '$2 !~ /\^\{\}$/ {print $2}' "$REFS_FILE" \
      | grep -E "^${prefix_re}_r[0-9]+$" \
      | sort -V
}

latest_monthly_ref_for_prefix() {
    monthly_refs_for_prefix "$1" | tail -n1
}
