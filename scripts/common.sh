#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORKSPACE_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=../config/defaults.env
. "$WORKSPACE_ROOT/config/defaults.env"

CACHE_ROOT=${CACHE_ROOT:-"$WORKSPACE_ROOT/cache"}
BUILD_ROOT=${BUILD_ROOT:-"$WORKSPACE_ROOT/build"}
BIN_ROOT=${BIN_ROOT:-"$WORKSPACE_ROOT/bin"}
STATE_ROOT=${STATE_ROOT:-"$WORKSPACE_ROOT/state"}
CATALOG_DIR="$CACHE_ROOT/catalog"
SELECTED_FILE="$STATE_ROOT/selected_kernel.env"

JOBS=${JOBS:-}
if test -z "$JOBS"; then
    JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
fi

export ARCH=${ARCH:-$KERNEL_ARCH}
export LLVM=${LLVM:-1}
export LLVM_IAS=${LLVM_IAS:-1}
export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-gki-module-builder}
export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-android-gki}

mkdir -p "$CACHE_ROOT" "$BUILD_ROOT" "$BIN_ROOT" "$STATE_ROOT" "$CATALOG_DIR"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'warning: %s\n' "$*" >&2
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

have_command() {
    command -v "$1" >/dev/null 2>&1
}

DNS_OVERRIDE_CACHE="$CATALOG_DIR/dns-overrides.tsv"
touch "$DNS_OVERRIDE_CACHE"

url_host() {
    printf '%s\n' "$1" | sed -n 's#^[A-Za-z][A-Za-z0-9+.-]*://\([^/:]*\).*#\1#p'
}

dns_cache_get() {
    local host=$1 now ts ip
    now=$(date +%s 2>/dev/null || printf '0')
    while IFS=$'\t' read -r cached_host ip ts; do
        test "$cached_host" = "$host" || continue
        case "$ts" in *[!0-9]*|'') continue ;; esac
        if test $((now - ts)) -lt 1800 2>/dev/null; then
            printf '%s\n' "$ip"
        fi
    done < "$DNS_OVERRIDE_CACHE"
}

dns_cache_put() {
    local host=$1 ip=$2 now tmp
    now=$(date +%s 2>/dev/null || printf '0')
    tmp="$DNS_OVERRIDE_CACHE.tmp.$$"
    awk -F '\t' -v h="$host" '$1!=h' "$DNS_OVERRIDE_CACHE" > "$tmp" || true
    printf '%s\t%s\t%s\n' "$host" "$ip" "$now" >> "$tmp"
    mv -f "$tmp" "$DNS_OVERRIDE_CACHE"
}

extract_ipv4_from_doh_json() {
    grep -oE '"data"[[:space:]]*:[[:space:]]*"([0-9]{1,3}\.){3}[0-9]{1,3}"' \
        | sed -E 's/.*"(([0-9]{1,3}\.){3}[0-9]{1,3})"/\1/' \
        | awk '!seen[$0]++'
}

doh_lookup_ipv4() {
    local host=$1 json
    have_command curl || return 1

    # These requests connect to fixed IPs, so they work even if the local
    # libc resolver is unavailable. TLS hostname verification remains enabled.
    if json=$(curl -fsSL --connect-timeout 4 --max-time 8 \
            --resolve cloudflare-dns.com:443:1.1.1.1 \
            -H 'accept: application/dns-json' \
            "https://cloudflare-dns.com/dns-query?name=$host&type=A" 2>/dev/null); then
        if printf '%s' "$json" | extract_ipv4_from_doh_json; then
            return 0
        fi
    fi

    if json=$(curl -fsSL --connect-timeout 4 --max-time 8 \
            --resolve dns.google:443:8.8.8.8 \
            -H 'accept: application/dns-json' \
            "https://dns.google/resolve?name=$host&type=A" 2>/dev/null); then
        printf '%s' "$json" | extract_ipv4_from_doh_json
        return $?
    fi

    return 1
}

host_override_ips() {
    local host=$1
    local -a ips=()
    mapfile -t ips < <(dns_cache_get "$host" || true)
    if test "${#ips[@]}" -gt 0; then
        printf '%s\n' "${ips[@]}"
        return 0
    fi

    mapfile -t ips < <(doh_lookup_ipv4 "$host" || true)
    if test "${#ips[@]}" -gt 0; then
        dns_cache_put "$host" "${ips[0]}"
        printf '%s\n' "${ips[@]}"
        return 0
    fi
    return 1
}

curl_with_dns_fallback() {
    local url=$1
    shift
    local host ip
    local -a cached=() fresh=()

    host=$(url_host "$url")
    if test -n "$host"; then
        mapfile -t cached < <(dns_cache_get "$host" || true)
        for ip in "${cached[@]}"; do
            test -n "$ip" || continue
            if curl "$@" --resolve "$host:443:$ip" "$url"; then
                return 0
            fi
        done
    fi

    if curl "$@" "$url"; then
        return 0
    fi

    test -n "$host" || return 1
    mapfile -t fresh < <(doh_lookup_ipv4 "$host" || true)
    for ip in "${fresh[@]}"; do
        test -n "$ip" || continue
        if curl "$@" --resolve "$host:443:$ip" "$url"; then
            dns_cache_put "$host" "$ip"
            return 0
        fi
    done
    return 1
}

git_with_dns_fallback() {
    local remote=$1
    shift
    local host ip
    local -a cached=() fresh=()

    host=$(url_host "$remote")
    if test -n "$host"; then
        mapfile -t cached < <(dns_cache_get "$host" || true)
        for ip in "${cached[@]}"; do
            test -n "$ip" || continue
            if git -c "http.curloptResolve=$host:443:$ip" "$@"; then
                return 0
            fi
        done
    fi

    if git "$@"; then
        return 0
    fi

    test -n "$host" || return 1
    mapfile -t fresh < <(doh_lookup_ipv4 "$host" || true)
    for ip in "${fresh[@]}"; do
        test -n "$ip" || continue
        if git -c "http.curloptResolve=$host:443:$ip" "$@"; then
            dns_cache_put "$host" "$ip"
            return 0
        fi
    done
    return 1
}

http_get() {
    local url=$1
    if have_command curl; then
        curl_with_dns_fallback "$url" -fsSL --retry 2 --retry-delay 1 --retry-all-errors \
            --connect-timeout 8 --max-time 25
    elif have_command wget; then
        wget -qO- --timeout=15 --read-timeout=25 --tries=4 "$url"
    else
        die "install curl or wget first"
    fi
}

http_download() {
    local url=$1 dest=$2
    mkdir -p "$(dirname -- "$dest")"
    if have_command curl; then
        curl_with_dns_fallback "$url" -fL --retry 2 --retry-delay 1 --retry-all-errors \
            --connect-timeout 8 --max-time 180 -o "$dest"
    elif have_command wget; then
        wget -O "$dest" --timeout=15 --read-timeout=60 --tries=4 "$url"
    else
        die "install curl or wget first"
    fi
}

version_key() {
    printf '%s' "$1" | tr '.' '_'
}

validate_kernel_version() {
    case "$1" in
        [456].*.*) ;;
        *) die "kernel version must be an exact 4.x.y / 5.x.y / 6.x.y version: $1" ;;
    esac
    printf '%s\n' "$1" | grep -Eq '^[456]\.[0-9]+\.[0-9]+$' || \
        die "invalid kernel version: $1"
}

kernel_series_of() {
    printf '%s\n' "$1" | awk -F. '{print $1 "." $2}'
}

sanitize_ref() {
    printf '%s' "$1" | sed 's#^refs/tags/##; s#^refs/heads/##; s#[^A-Za-z0-9._-]#_#g'
}

android_branch_from_ref() {
    printf '%s\n' "$1" | sed -n 's#^refs/\(tags\|heads\)/\(android[0-9]*\)-.*#\2#p'
}

kernel_source_page_url() {
    local ref=${1:-}
    printf 'https://android.googlesource.com/kernel/common/+/%s\n' "$ref"
}

kernel_source_archive_url() {
    # Archive URLs are intentionally unused. Source is fetched by exact Git ref.
    printf '\n'
}

load_selected_kernel() {
    test -s "$SELECTED_FILE" || die "no kernel selected; run: bash scripts/select_kernel.sh"
    # shellcheck disable=SC1090
    . "$SELECTED_FILE"
    : "${SELECTED_VERSION:?selected state missing SELECTED_VERSION}"
    : "${SELECTED_REF:?selected state missing SELECTED_REF}"
    SELECTED_REQUESTED_REF=${SELECTED_REQUESTED_REF:-$SELECTED_REF}
    SELECTED_SERIES=${SELECTED_SERIES:-$(kernel_series_of "$SELECTED_VERSION")}
    SELECTED_REF_SLUG=${SELECTED_REF_SLUG:-$(sanitize_ref "$SELECTED_REF")}
    SELECTED_BUILD_ID=${SELECTED_BUILD_ID:-}
    SELECTED_TAG_COMMIT=${SELECTED_TAG_COMMIT:-}
    SELECTED_CI_TARGET=${SELECTED_CI_TARGET:-$CI_TARGET}
    SELECTED_SOURCE_REMOTE=${SELECTED_SOURCE_REMOTE:-$KERNEL_REMOTE}
    SELECTED_SOURCE_PAGE=${SELECTED_SOURCE_PAGE:-$(kernel_source_page_url "$SELECTED_REF")}
    SELECTED_SOURCE_ARCHIVE=${SELECTED_SOURCE_ARCHIVE:-}
}

kernel_source_dir() {
    load_selected_kernel
    printf '%s/kernel-src/%s/%s\n' "$CACHE_ROOT" "$SELECTED_VERSION" "$SELECTED_REF_SLUG"
}

kernel_build_dir() {
    load_selected_kernel
    printf '%s/kernel/%s/%s\n' "$BUILD_ROOT" "$SELECTED_VERSION" "$SELECTED_REF_SLUG"
}

symvers_cache_file() {
    load_selected_kernel
    printf '%s/symvers/%s/%s/Module.symvers\n' "$CACHE_ROOT" "$SELECTED_VERSION" "$SELECTED_REF_SLUG"
}

kernel_make() {
    local src out
    src=$(kernel_source_dir)
    out=$(kernel_build_dir)
    make -C "$src" O="$out" \
        ARCH="$ARCH" LLVM="$LLVM" LLVM_IAS="$LLVM_IAS" "$@"
}

read_kernel_version_from_makefile() {
    local f=$1 v p s
    test -f "$f" || return 1
    v=$(awk '$1=="VERSION" && $2=="=" {print $3; exit}' "$f")
    p=$(awk '$1=="PATCHLEVEL" && $2=="=" {print $3; exit}' "$f")
    s=$(awk '$1=="SUBLEVEL" && $2=="=" {print $3; exit}' "$f")
    test -n "$v" -a -n "$p" -a -n "$s" || return 1
    printf '%s.%s.%s\n' "$v" "$p" "$s"
}


is_valid_symvers() {
    local f=$1
    test -s "$f" || return 1
    awk 'NF >= 4 && $1 ~ /^0x[[:xdigit:]]+$/ { ok=1; exit } END { exit(ok ? 0 : 1) }' "$f"
}

resolve_module_dir() {
    local selector=${1:-} candidate
    test -n "$selector" || die "module selector is empty"
    case "$selector" in
        /*) candidate=$selector ;;
        */*) candidate="$WORKSPACE_ROOT/$selector" ;;
        *) candidate="$WORKSPACE_ROOT/modules/$selector" ;;
    esac
    test -d "$candidate" || die "module not found: $selector"
    test -f "$candidate/Kbuild" -o -f "$candidate/Makefile" || die "no Kbuild/Makefile in $candidate"
    (CDPATH= cd -- "$candidate" && pwd)
}

module_output_basename() {
    local module_dir=$1 base
    base=$(basename -- "$module_dir")
    if test -f "$module_dir/module.env"; then
        OUTPUT_BASENAME=
        # shellcheck disable=SC1090
        . "$module_dir/module.env"
        if test -n "${OUTPUT_BASENAME:-}"; then
            base=$OUTPUT_BASENAME
        fi
    fi
    printf '%s\n' "$base"
}

check_prepared_kernel() {
    local src out
    src=$(kernel_source_dir)
    out=$(kernel_build_dir)
    test -f "$src/Makefile" || die "kernel source missing: $src; run scripts/ensure_kernel.sh"
    test -f "$out/.config" || die "kernel is not prepared: $out/.config missing"
    test -f "$out/include/config/auto.conf" || die "kernel is not prepared: auto.conf missing; run scripts/prepare_kernel.sh"
}
