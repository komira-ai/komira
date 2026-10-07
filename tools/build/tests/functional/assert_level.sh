#!/usr/bin/env bash
# assert_level.sh -- the assert level, defines and memory cap of each target
# below reach exactly the commands they should, and a target that sets none
# of them has no `-D` and no memory cap in any command (so its action keys
# are the ones it had before the attributes existed). Reads the commands from
# `buck2 aquery` (analysis only; nothing is built).
#
# usage: tools/build/tests/functional/assert_level.sh [LOG_DIR]   (BUCK2 overrides the binary)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
BUCK2=${BUCK2:-$ROOT/buck2}
LOG=${1:-${TMPDIR:-/tmp}}
out="$LOG/assert_level.aquery.txt"

# label category want. `want` is an extended regular expression every
# command of that category of that target must match, or `!` and one that
# none may match. A listed target must have at least one such action.
EXPECT='
tests//functional/assert_level:lib_none mojo_build_test , -D, ASSERT=none,
tests//functional/assert_level:lib_none mojo_gated_test ^\[[^,]*/busybox, sh, [^,]*/mem_cap\.sh, [^,]*/busybox, 4096, tests//functional/assert_level:lib_none:tests/test_quiet_at_none\.mojo, --, [^,]*/busybox, sh, [^,]*/gate_runner\.sh,
tests//functional/assert_level:lib_none_uncapped mojo_build_test , -D, ASSERT=none,
tests//functional/assert_level:lib_none_uncapped mojo_gated_test !mem_cap
tests//functional/assert_level:lib_default mojo_build_test !, -D,
tests//functional/assert_level:lib_default mojo_gated_test !mem_cap
tests//functional/assert_level:lib_defines mojo_build_test --target-cpu, [^,]*, -D, KOMIRA_PROBE_DEFINE=on,
tests//functional/assert_level:lib_defines mojo_gated_test !mem_cap
tests//functional/assert_level:bin_none mojo_build , -D, ASSERT=none,
tests//functional/assert_level:bin_none mojo_build_shared , -D, ASSERT=none,
tests//functional/assert_level:test_none mojo_build_test , -D, ASSERT=none,
tests//functional/mem_cap:lib_under_cap mojo_gated_test ^\[[^,]*/busybox, sh, [^,]*/mem_cap\.sh, [^,]*/busybox, 1024,
tests//functional/mem_cap:lib_under_cap mojo_build_test !, -D,
komira//tools/build/examples/libgate_ok:libgate_ok mojo_build_test !, -D,
komira//tools/build/examples/libgate_ok:libgate_ok mojo_gated_test !mem_cap
komira//tools/build/examples:hello mojo_build !, -D,
komira//tools/build/examples:test_hellopkg mojo_build_test !, -D,
'

targets=$(printf '%s\n' "$EXPECT" | awk 'NF { print $1 }' | LC_ALL=C sort -u)
query=""
for t in $targets; do query="${query:+$query + }deps($t)"; done
# A binary's [shared] library is built only for that sub-target.
query="$query + deps('tests//functional/assert_level:bin_none[shared]')"
if ! "$BUCK2" aquery "$query" --output-attribute cmd --output-attribute category > "$out" 2> "$out.err"; then
    echo "FAIL  assert level: aquery failed (see $out.err)"
    exit 1
fi
# One line per action: label <TAB> category <TAB> command.
awk '
    /^  "\(target: `/ { split($0, a, "`"); split(a[2], b, " "); label = b[1]; cat = ""; cmd = "" }
    /^    "category": / { cat = $0; sub(/^    "category": "/, "", cat); sub(/",?$/, "", cat) }
    /^    "cmd": / { cmd = $0; sub(/^    "cmd": "/, "", cmd); sub(/",?$/, "", cmd) }
    /^  }/ { if (label != "") print label "\t" cat "\t" cmd; label = "" }
' "$out" > "$out.tsv"

bad=""
ok=0
while IFS= read -r line; do
    [ -n "$line" ] || continue
    label=${line%% *}
    rest=${line#* }
    cat=${rest%% *}
    want=${rest#* }
    neg=0
    case "$want" in "!"*) neg=1; want=${want#!} ;; esac
    n=$(awk -F '\t' -v l="$label" -v c="$cat" '$1 == l && $2 == c' "$out.tsv" | wc -l)
    if [ "$n" = 0 ]; then
        bad="$bad; $label has no $cat action"
        continue
    fi
    if [ "$neg" = 1 ]; then
        hits=$(awk -F '\t' -v l="$label" -v c="$cat" '$1 == l && $2 == c { print $3 }' "$out.tsv" | grep -cE -- "$want")
    else
        hits=$(awk -F '\t' -v l="$label" -v c="$cat" '$1 == l && $2 == c { print $3 }' "$out.tsv" | grep -cvE -- "$want")
    fi
    if [ "$hits" != 0 ]; then
        if [ "$neg" = 1 ]; then bad="$bad; $label $cat: $hits command(s) match '$want'"; else bad="$bad; $label $cat: $hits command(s) do not match '$want'"; fi
    else
        ok=$((ok + 1))
    fi
done <<< "$EXPECT"
if [ -n "$bad" ]; then
    echo "FAIL  assert level: ${bad#; }"
    exit 1
fi
echo "PASS  assert level: $ok expectations over the compile and gated-test commands (-D ASSERT and defines where set, the memory cap at 4096 MiB by default at ASSERT=none and as set, none of either where unset)"
