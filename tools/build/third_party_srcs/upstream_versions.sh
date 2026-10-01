#!/bin/sh
# Reports, for each pinned GitHub download in this repository's BUCK files,
# the pinned version and the newest one upstream, so that a maintainer knows
# when to bump a pin. It gates nothing: it always exits 0 (2 on a usage
# error), and a lookup that fails is reported as "unknown".
#
#   tools/build/third_party_srcs/upstream_versions.sh [BUCK ...]
#
# With no argument it reads every BUCK file git tracks. A pin is a
# `url = "..."` line naming one of
#   https://github.com/<owner>/<repo>/archive/refs/tags/<tag>.tar.gz
#   https://github.com/<owner>/<repo>/releases/download/<tag>/<file>
#   https://github.com/<owner>/<repo>/archive/<commit>.tar.gz
# A tag is compared with the highest upstream tag of the same shape (a
# leading "v" or not, then dot-separated numbers; pre-releases are skipped);
# a commit with the head of the default branch. Any other URL is listed as
# not checked. Needs git and network access.
set -u

case "${1:-}" in
    -h | --help)
        sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    -*)
        echo "upstream_versions.sh: unknown option $1" >&2
        exit 2
        ;;
esac

if [ "$#" -eq 0 ]; then
    top=$(git rev-parse --show-toplevel) || exit 2
    cd "$top" || exit 2
    # Word splitting is wanted: BUCK paths hold no whitespace.
    # shellcheck disable=SC2046
    set -- $(git ls-files -- 'BUCK' '*/BUCK')
fi

# The highest tag of the pinned tag's shape, from `git ls-remote` output.
latest_tag() {
    pinned="$1"
    case "$pinned" in
        v*) prefix=v ;;
        *) prefix= ;;
    esac
    sed -n 's|^[0-9a-f]*[[:space:]]*refs/tags/||p' |
        grep -E "^${prefix}[0-9]+(\.[0-9]+)*\$" |
        sed "s|^${prefix}||" |
        sort -t. -k1,1n -k2,2n -k3,3n -k4,4n |
        tail -n 1 |
        sed "s|^|${prefix}|"
}

report() {
    printf '%-40s %-44s %s\n' "$1" "$2" "$3"
}

report "UPSTREAM" "PINNED" "LATEST"
grep -ho 'url = "[^"]*"' "$@" | sed 's/^url = "//; s/"$//' | sort -u |
    while read -r url; do
        repo=$(printf '%s\n' "$url" | sed -n 's|^https://github.com/\([^/]*/[^/]*\)/.*|\1|p')
        tag=$(printf '%s\n' "$url" | sed -n \
            -e 's|^https://github.com/[^/]*/[^/]*/archive/refs/tags/\(.*\)\.tar\.gz$|\1|p' \
            -e 's|^https://github.com/[^/]*/[^/]*/releases/download/\([^/]*\)/.*|\1|p')
        commit=$(printf '%s\n' "$url" | sed -n 's|^https://github.com/[^/]*/[^/]*/archive/\([0-9a-f]\{40\}\)\.tar\.gz$|\1|p')
        if [ -z "$repo" ] || { [ -z "$tag" ] && [ -z "$commit" ]; }; then
            report "-" "$url" "not checked"
            continue
        fi
        if [ -n "$tag" ]; then
            latest=$(git ls-remote --tags --refs "https://github.com/$repo" 2>/dev/null | latest_tag "$tag")
            pinned="$tag"
        else
            latest=$(git ls-remote "https://github.com/$repo" HEAD 2>/dev/null | cut -f1)
            pinned="$commit"
        fi
        if [ -z "$latest" ]; then
            report "$repo" "$pinned" "unknown"
        elif [ "$latest" = "$pinned" ]; then
            report "$repo" "$pinned" "$latest (current)"
        else
            report "$repo" "$pinned" "$latest (newer upstream)"
        fi
    done
exit 0
