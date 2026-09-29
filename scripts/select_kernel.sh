#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/catalog_lib.sh"

usage() {
    cat <<USAGE
usage:
  $0                              # interactive series/version selection
  $0 VERSION                      # e.g. 5.15.180
  $0 VERSION --ref REF            # force an exact monthly GKI release tag
  $0 VERSION --revision rN        # force one revision in the matched month

Selection is host-independent: no uname/current-phone information is used.
A numeric version first chooses its Android branch, then resolves a published
monthly GKI release whose source and vmlinux.symvers come from the same build.
By default the highest revision with a usable CI artifact is selected automatically.
USAGE
}

choose_from_lines() {
    local prompt=$1; shift
    local -a items=("$@")
    local i answer
    test "${#items[@]}" -gt 0 || return 1
    for i in "${!items[@]}"; do
        printf '%3d) %s\n' "$((i+1))" "${items[$i]}" >&2
    done
    while :; do
        printf '%s' "$prompt" >&2
        IFS= read -r answer
        case "$answer" in
            *[!0-9]*|'') printf 'Please enter a number.\n' >&2 ;;
            *)
                if test "$answer" -ge 1 2>/dev/null && test "$answer" -le "${#items[@]}" 2>/dev/null; then
                    printf '%s\n' "${items[$((answer-1))]}"
                    return 0
                fi
                printf 'Out of range.\n' >&2
                ;;
        esac
    done
}

version_cmp() {
    local a=$1 b=$2 first
    if test "$a" = "$b"; then
        printf '0\n'
        return
    fi
    first=$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)
    if test "$first" = "$a"; then printf '%s\n' -1; else printf '%s\n' 1; fi
}

probe_prefix_version() {
    local prefix=$1 ref ver
    ref=$(latest_monthly_ref_for_prefix "$prefix")
    test -n "$ref" || return 1
    printf '  checking %-42s ... ' "$(sanitize_ref "$ref")" >&2
    if ver=$(bash "$SCRIPT_DIR/remote_meta.sh" --version "$ref" 2>/dev/null); then
        printf '%s\n' "$ver" >&2
        printf '%s\n' "$ver"
        return 0
    fi
    printf 'network/error\n' >&2
    return 1
}

find_matching_release_prefix() {
    local target=$1 android_branch=$2 series=$3
    local low high mid cmp ver
    local -a prefixes

    mapfile -t prefixes < <(monthly_release_prefixes "$android_branch" "$series")
    test "${#prefixes[@]}" -gt 0 || return 1

    low=0
    high=$((${#prefixes[@]} - 1))

    # Monthly GKI kernel versions are monotonic. Binary search therefore needs
    # only a handful of tiny metadata requests. No kernel source is downloaded
    # here; the selected release is fetched later by fetch_kernel_source.sh.
    while test "$low" -le "$high"; do
        mid=$(((low + high) / 2))
        ver=$(probe_prefix_version "${prefixes[$mid]}") || return 2
        cmp=$(version_cmp "$ver" "$target")
        if test "$cmp" -eq 0; then
            printf '%s\n' "${prefixes[$mid]}"
            return 0
        elif test "$cmp" -lt 0; then
            low=$((mid + 1))
        else
            high=$((mid - 1))
        fi
    done

    return 1
}

VERSION=
FORCED_REF=
FORCED_REVISION=
if test "$#" -gt 0; then
    case "$1" in -h|--help) usage; exit 0;; esac
    VERSION=$1
    shift
fi
while test "$#" -gt 0; do
    case "$1" in
        --ref) test "$#" -ge 2 || die "--ref requires a value"; FORCED_REF=$2; shift 2 ;;
        --revision)
            test "$#" -ge 2 || die "--revision requires a value"
            FORCED_REVISION=$2
            case "$FORCED_REVISION" in
                r[0-9]*) ;;
                [0-9]*) FORCED_REVISION="r$FORCED_REVISION" ;;
                *) die "invalid revision: $FORCED_REVISION (use r2 or 2)" ;;
            esac
            shift 2
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

ensure_refs

if test -z "$VERSION"; then
    mapfile -t SERIES < <(list_series)
    test "${#SERIES[@]}" -gt 0 || die "no exact Android Common Kernel tags found"
    printf '\nAvailable Android Common Kernel series:\n' >&2
    SERIES_PICK=$(choose_from_lines 'Choose series: ' "${SERIES[@]}")

    mapfile -t VERSIONS < <(list_versions "$SERIES_PICK")
    test "${#VERSIONS[@]}" -gt 0 || die "no exact patch versions found for $SERIES_PICK"
    printf '\nExact versions for %s:\n' "$SERIES_PICK" >&2
    VERSION=$(choose_from_lines 'Choose exact version: ' "${VERSIONS[@]}")
fi

validate_kernel_version "$VERSION"
SERIES=$(kernel_series_of "$VERSION")
REQUESTED_REF=
RELEASE_REF=
BUILD_ID=

if test -n "$FORCED_REF"; then
    tag_commit_from_catalog "$FORCED_REF" >/dev/null || \
        die "selected ref is not present in the fetched official tag catalog: $FORCED_REF"
    actual=$(bash "$SCRIPT_DIR/remote_meta.sh" --version "$FORCED_REF" 2>/dev/null || true)
    test "$actual" = "$VERSION" || die "forced ref reports kernel $actual, expected $VERSION"
    BUILD_ID=$(bash "$SCRIPT_DIR/remote_meta.sh" --build-id "$FORCED_REF" 2>/dev/null || true)
    test -n "$BUILD_ID" || die "forced ref has no published kernel_aarch64 CI artifact: $FORCED_REF"
    RELEASE_REF=$FORCED_REF
    REQUESTED_REF=$FORCED_REF
else
    mapfile -t EXACT_REFS < <(exact_android_refs "$VERSION")
    test "${#EXACT_REFS[@]}" -gt 0 || die "no exact Android Common Kernel tag found for $VERSION"

    if test "${#EXACT_REFS[@]}" -eq 1; then
        REQUESTED_REF=${EXACT_REFS[0]}
    else
        printf '\nMultiple Android branches contain %s. Choose the Android source branch:\n' "$VERSION" >&2
        REQUESTED_REF=$(choose_from_lines 'Choose source ref: ' "${EXACT_REFS[@]}")
    fi

    ANDROID_BRANCH=$(android_branch_from_ref "$REQUESTED_REF" || true)
    test -n "$ANDROID_BRANCH" || die "cannot determine Android branch from $REQUESTED_REF"

    printf '\nResolving a published GKI release for %s (%s-%s).\n' \
        "$VERSION" "$ANDROID_BRANCH" "$SERIES" >&2
    printf 'Metadata lookup is lightweight; kernel source is downloaded only after selection.\n' >&2
    printf 'The selected release will provide BOTH source and vmlinux.symvers.\n' >&2

    set +e
    RELEASE_PREFIX_OUTPUT=$(find_matching_release_prefix "$VERSION" "$ANDROID_BRANCH" "$SERIES")
    rc=$?
    set -e
    if test "$rc" -eq 2; then
        die "release metadata lookup failed. Check network access and retry; no phone/kernel information is used as a fallback."
    elif test "$rc" -ne 0 || test -z "$RELEASE_PREFIX_OUTPUT"; then
        die "no published monthly GKI release was found for $VERSION on $ANDROID_BRANCH-$SERIES; an automatic matching Module.symvers cannot be guaranteed"
    fi

    RELEASE_PREFIX=$RELEASE_PREFIX_OUTPUT
    printf 'Matched monthly release: %s\n' "$(sanitize_ref "$RELEASE_PREFIX")" >&2

    mapfile -t RELEASE_REFS < <(monthly_refs_for_prefix "$RELEASE_PREFIX")
    test "${#RELEASE_REFS[@]}" -gt 0 || die "no release revisions found under $RELEASE_PREFIX"

    if test -n "$FORCED_REVISION"; then
        candidate="${RELEASE_PREFIX}_${FORCED_REVISION}"
        found=0
        for item in "${RELEASE_REFS[@]}"; do
            if test "$item" = "$candidate"; then
                found=1
                break
            fi
        done
        test "$found" -eq 1 || die "revision $FORCED_REVISION does not exist under $(sanitize_ref "$RELEASE_PREFIX")"

        actual=$(bash "$SCRIPT_DIR/remote_meta.sh" --version "$candidate" 2>/dev/null || true)
        test "$actual" = "$VERSION" || \
            die "$candidate reports kernel ${actual:-unknown}, expected $VERSION"
        BUILD_ID=$(bash "$SCRIPT_DIR/remote_meta.sh" --build-id "$candidate" 2>/dev/null || true)
        test -n "$BUILD_ID" || \
            die "$candidate has no published kernel_aarch64 CI artifact"
        RELEASE_REF=$candidate
        printf 'Using requested revision: %s\n' "$(sanitize_ref "$RELEASE_REF")" >&2
    else
        printf 'Auto-selecting the highest revision with a usable CI artifact...\n' >&2
        for ((i=${#RELEASE_REFS[@]}-1; i>=0; i--)); do
            candidate=${RELEASE_REFS[$i]}
            printf '  checking %-42s ... ' "$(sanitize_ref "$candidate")" >&2

            actual=$(bash "$SCRIPT_DIR/remote_meta.sh" --version "$candidate" 2>/dev/null || true)
            if test "$actual" != "$VERSION"; then
                printf 'kernel %s, skip\n' "${actual:-unknown}" >&2
                continue
            fi

            BUILD_ID=$(bash "$SCRIPT_DIR/remote_meta.sh" --build-id "$candidate" 2>/dev/null || true)
            if test -z "$BUILD_ID"; then
                printf 'no CI artifact, skip\n' >&2
                continue
            fi

            RELEASE_REF=$candidate
            printf 'selected (build %s)\n' "$BUILD_ID" >&2
            break
        done
    fi

    test -n "$RELEASE_REF" -a -n "$BUILD_ID" || \
        die "none of the monthly release revisions exposes a usable kernel_aarch64 CI artifact"
fi

REF=$RELEASE_REF
TAG_COMMIT=$(tag_commit_from_catalog "$REF" || true)
SOURCE_PAGE="https://android.googlesource.com/kernel/common/+/$REF"
mkdir -p "$STATE_ROOT"
{
    printf 'SELECTED_VERSION=%q\n' "$VERSION"
    printf 'SELECTED_REQUESTED_REF=%q\n' "$REQUESTED_REF"
    printf 'SELECTED_SERIES=%q\n' "$SERIES"
    printf 'SELECTED_REF=%q\n' "$REF"
    printf 'SELECTED_REF_SLUG=%q\n' "$(sanitize_ref "$REF")"
    printf 'SELECTED_TAG_COMMIT=%q\n' "$TAG_COMMIT"
    printf 'SELECTED_BUILD_ID=%q\n' "$BUILD_ID"
    printf 'SELECTED_CI_TARGET=%q\n' "$CI_TARGET"
    printf 'SELECTED_SOURCE_REMOTE=%q\n' "$KERNEL_REMOTE"
    printf 'SELECTED_SOURCE_PAGE=%q\n' "$SOURCE_PAGE"
    printf 'SELECTED_SOURCE_ARCHIVE=%q\n' ''
} > "$SELECTED_FILE"

printf '\nSelected matching GKI build:\n'
printf '  version       : %s\n' "$VERSION"
printf '  requested tag : %s\n' "$REQUESTED_REF"
printf '  release tag   : %s\n' "$REF"
printf '  source repo   : %s\n' "$KERNEL_REMOTE"
printf '  source cache  : %s\n' "$(kernel_source_dir)"
printf '  CI build      : %s\n' "$BUILD_ID"
printf '  Module.symvers: https://ci.android.com/builds/submitted/%s/%s/latest/raw/vmlinux.symvers\n' \
    "$BUILD_ID" "$CI_TARGET"
printf '  host policy   : independent (does not read uname/current phone kernel)\n'
