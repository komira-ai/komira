#!/bin/sh
# no_mixed_closure: no target may depend on both a package being split away and
# a package that replaces it, because two copies of one type (two `Column`s,
# two sets of counters) would then meet in one binary. Two queries:
#
#   rdeps(//src/..., //src/komira_core:komira_core)
#       intersect rdeps(//src/..., set(<the derived packages that exist>))
#   rdeps(//src/..., //src/komira_core_ffi:komira_core_ffi)
#       intersect rdeps(//src/..., //src/komira_libc:komira_libc)
#
# Both must be empty. Run from the repository root:
#
#   tools/core_split/no_mixed_closure.sh             check the tree
#   tools/core_split/no_mixed_closure.sh --selftest  prove the check can fail:
#       the same query over tools/core_split/fixture, where `mixed` depends on
#       both sides, must find `mixed`, and must find nothing for a pair no
#       target spans.
set -eu

BUCK2="${BUCK2:-./buck2}"
MAP=tools/core_split/split_map.tsv

# mixed OLD NEW SCOPE: the targets of SCOPE that reach both OLD and NEW. It is a
# cquery, not a uquery: a uquery over //src/... fails on the first cxx_library
# (komira_core_posix names a toolchain target that only a configured query
# resolves). A query that fails is exit 3, never an empty answer: nothing was
# compared.
mixed() {
    err=$(mktemp)
    if ! out=$("$BUCK2" cquery "rdeps($3, $1) intersect rdeps($3, $2)" 2>"$err"); then
        echo "no_mixed_closure: the query failed, so nothing was compared:" >&2
        head -20 "$err" >&2
        rm -f "$err"
        exit 3
    fi
    rm -f "$err"
    printf '%s\n' "$out"
}

if [ "${1:-}" = "--selftest" ]; then
    scope="//tools/core_split/fixture/..."
    found=$(mixed //tools/core_split/fixture:old //tools/core_split/fixture:new "$scope")
    case "$found" in
    *fixture:mixed*) echo "no_mixed_closure selftest: RED as seeded, found $(echo "$found" | tr '\n' ' ')" ;;
    *)
        echo "no_mixed_closure selftest FAILED: the seeded target was not found (got: $found)"
        exit 1
        ;;
    esac
    found=$(mixed //tools/core_split/fixture:old_alone //tools/core_split/fixture:new "$scope")
    if [ -n "$found" ]; then
        echo "no_mixed_closure selftest FAILED: a pair no target spans reported $found"
        exit 1
    fi
    echo "no_mixed_closure selftest: GREEN for a pair no target spans"
    exit 0
fi

# The derived packages that exist in this tree: the destinations of the map's
# copy rows (the three precondition moves go to packages that already exist),
# less the ones whose directory has no BUCK file yet.
derived=""
for pkg in $(awk -F'\t' '/^#/ { next } !h { h = 1; next } $4 == "copy" { print $5 }' "$MAP" | sort -u); do
    [ "$pkg" = komira_libc ] && continue
    [ -f "src/$pkg/BUCK" ] && derived="$derived //src/$pkg:$pkg"
done

status=0
if [ -n "$derived" ]; then
    # shellcheck disable=SC2086 # the targets are words on purpose
    found=$(mixed //src/komira_core:komira_core "set($derived)" "//src/...")
    if [ -n "$found" ]; then
        echo "no_mixed_closure RED: these depend on komira_core and on a derived package:"
        echo "$found"
        status=1
    fi
else
    echo "no_mixed_closure: no derived package exists yet, so the first query has nothing to compare"
fi
if [ -f src/komira_libc/BUCK ]; then
    found=$(mixed //src/komira_core_ffi:komira_core_ffi //src/komira_libc:komira_libc "//src/...")
    if [ -n "$found" ]; then
        echo "no_mixed_closure RED: these depend on komira_core_ffi and on komira_libc:"
        echo "$found"
        status=1
    fi
fi
[ "$status" = 0 ] && echo "no_mixed_closure GREEN"
exit "$status"
