#!/usr/bin/env bash
# assert_level.sh -- the assert level, defines and memory cap of each target
# below reach exactly the commands they should, and a target that sets none
# of them has no `-D` and no memory cap in any command (so its action keys
# are the ones it had before the attributes existed). Reads the commands from
# `buck2 aquery`, once as configured and once with `-c komira.coverage=true`
# (a library's coverage build of each test), and the command a `mojo_test`
# gives `buck2 test` from `buck2 audit providers` (it is not an action, so
# aquery does not see it). Analysis only; nothing is built.
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
tests//functional/assert_level:lib_level_and_defines mojo_build_test --target-cpu, [^,]*, -D, ASSERT=none, -D, KOMIRA_PROBE_DEFINE=on, -D, KOMIRA_PROBE_SECOND=2, -I
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

# With -c komira.coverage=true: a library's coverage build of each test
# (mojo_build_cov_test) and its branch coverage bitcode (mojo_emit_cov_bc)
# get the level and the defines its test build gets. Beyond these rows, every
# library's bitcode has exactly the -D list (all of them, in order) of its
# coverage build (same_defines below).
COV_EXPECT='
tests//functional/assert_level:lib_none mojo_build_cov_test , -D, ASSERT=none,
tests//functional/assert_level:lib_defines mojo_build_cov_test --target-cpu, [^,]*, -D, KOMIRA_PROBE_DEFINE=on,
tests//functional/assert_level:lib_default mojo_build_cov_test !, -D,
tests//functional/assert_level:lib_none mojo_emit_cov_bc , -D, ASSERT=none,
tests//functional/assert_level:lib_defines mojo_emit_cov_bc --target-cpu, [^,]*, -D, KOMIRA_PROBE_DEFINE=on,
tests//functional/assert_level:lib_default mojo_emit_cov_bc !, -D,
tests//functional/assert_level:lib_level_and_defines mojo_build_cov_test --target-cpu, [^,]*, -D, ASSERT=none, -D, KOMIRA_PROBE_DEFINE=on, -D, KOMIRA_PROBE_SECOND=2, --debug-level,
tests//functional/assert_level:lib_level_and_defines mojo_emit_cov_bc --target-cpu, [^,]*, -D, ASSERT=none, -D, KOMIRA_PROBE_DEFINE=on, -D, KOMIRA_PROBE_SECOND=2, --debug-level,
'

# label want: the command a mojo_test gives `buck2 test` (its
# ExternalRunnerTestInfo, each artifact written as its short path), as
# EXPECT's `want`.
TEST_EXPECT='
tests//functional/assert_level:test_none ^busybox, "sh", test_deadline\.sh, busybox, "[0-9]+", "[0-9]+", "tests//functional/assert_level:test_none", "--", busybox, "sh", mem_cap\.sh, busybox, "4096", "tests//functional/assert_level:test_none", "--", busybox, "sh", gate_runner\.sh,
tests//negative/assert_level:test_default ^busybox, "sh", test_deadline\.sh, busybox, "[0-9]+", "[0-9]+", "tests//negative/assert_level:test_default", "--", busybox, "sh", gate_runner\.sh,
komira//tools/build/examples:test_hellopkg !mem_cap
'

bad=""
ok=0

# aquery_tsv <out> <expect> <query function> [buck2 options...]: one line per
# action of the expectation's targets, in <out>.tsv: label <TAB> category <TAB>
# command. <query function> `deps`: the actions of each target's default
# outputs and of their deps; `all_actions`: every action each target's own
# analysis declares, and no dep's. The coverage query is all_actions: with the
# switch on, a library's deps reach the coverage gate's tool, covcheck, a
# library with a README, whose examples' actions come from a dynamic action
# aquery cannot traverse (it fails, refusing to run the README's generate
# step), and the expectations name only the targets' own actions.
aquery_tsv() {
    local o=$1 e=$2 fn=$3 targets query t
    shift 3
    targets=$(printf '%s\n' "$e" | awk 'NF { print $1 }' | LC_ALL=C sort -u)
    query=""
    for t in $targets; do query="${query:+$query + }$fn('$t')"; done
    # A binary's [shared] library is built only for that sub-target.
    case "$e" in *bin_none*) query="$query + deps('tests//functional/assert_level:bin_none[shared]')" ;; esac
    if ! "$BUCK2" aquery "$query" "$@" --output-attribute cmd --output-attribute category > "$o" 2> "$o.err"; then
        echo "FAIL  assert level: aquery $* failed (see $o.err)"
        exit 1
    fi
    awk '
        /^  "\(target: `/ { split($0, a, "`"); split(a[2], b, " "); label = b[1]; cat = ""; cmd = "" }
        /^    "category": / { cat = $0; sub(/^    "category": "/, "", cat); sub(/",?$/, "", cat) }
        /^    "cmd": / { cmd = $0; sub(/^    "cmd": "/, "", cmd); sub(/",?$/, "", cmd) }
        /^  }/ { if (label != "") print label "\t" cat "\t" cmd; label = "" }
    ' "$o" > "$o.tsv"
}

# check <tsv> <expect> <what>: each line of <expect> against <tsv>.
check() {
    local tsv=$1 e=$2 what=$3 line label rest cat want neg n hits
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        label=${line%% *}
        rest=${line#* }
        cat=${rest%% *}
        want=${rest#* }
        neg=0
        case "$want" in "!"*) neg=1; want=${want#!} ;; esac
        n=$(awk -F '\t' -v l="$label" -v c="$cat" '$1 == l && $2 == c' "$tsv" | wc -l)
        if [ "$n" = 0 ]; then
            bad="$bad; $what$label has no $cat action"
            continue
        fi
        if [ "$neg" = 1 ]; then
            hits=$(awk -F '\t' -v l="$label" -v c="$cat" '$1 == l && $2 == c { print $3 }' "$tsv" | grep -cE -- "$want")
        else
            hits=$(awk -F '\t' -v l="$label" -v c="$cat" '$1 == l && $2 == c { print $3 }' "$tsv" | grep -cvE -- "$want")
        fi
        if [ "$hits" != 0 ]; then
            if [ "$neg" = 1 ]; then bad="$bad; $what$label $cat: $hits command(s) match '$want'"; else bad="$bad; $what$label $cat: $hits command(s) do not match '$want'"; fi
        else
            ok=$((ok + 1))
        fi
    done <<< "$e"
}

aquery_tsv "$out" "$EXPECT" deps
check "$out.tsv" "$EXPECT" ""
aquery_tsv "$out.cov" "$COV_EXPECT" all_actions -c komira.coverage=true
check "$out.cov.tsv" "$COV_EXPECT" "with komira.coverage=true: "

# same_defines <tsv>: for each library with a mojo_emit_cov_bc, the `-D`
# arguments of its bitcode commands, each in order, are those of its
# mojo_build_cov_test commands (one test each here, so one list each).
same_defines() {
    local diffs
    diffs=$(awk -F '\t' '
        $2 == "mojo_build_cov_test" || $2 == "mojo_emit_cov_bc" {
            n = split($3, a, ", "); d = ""
            for (i = 1; i < n; i++) if (a[i] == "-D") d = d " -D " a[i + 1]
            key = $1 SUBSEP $2
            if (!(key in list)) list[key] = "[" d "]"; else if (index(list[key], "[" d "]") == 0) list[key] = list[key] "[" d "]"
            if ($2 == "mojo_emit_cov_bc") bc[$1] = 1
        }
        END {
            for (l in bc) {
                b = list[l SUBSEP "mojo_emit_cov_bc"]; c = list[l SUBSEP "mojo_build_cov_test"]
                if (b != c) printf "%s mojo_emit_cov_bc -D %s, its mojo_build_cov_test %s; ", l, b, (c == "" ? "none" : c)
                else ok++
            }
            if (ok == 0) printf "no library has both a mojo_emit_cov_bc and a mojo_build_cov_test; "
        }' "$1")
    if [ -n "$diffs" ]; then
        bad="$bad; with komira.coverage=true: ${diffs%; }"
    else
        ok=$((ok + 1))
    fi
}
same_defines "$out.cov.tsv"

# The provider dump's ExternalRunnerTestInfo command, on one line, as the
# rows of an aquery tsv (category `test_command`).
: > "$out.test.tsv"
for t in $(printf '%s\n' "$TEST_EXPECT" | awk 'NF { print $1 }'); do
    if ! "$BUCK2" audit providers "$t" > "$out.providers" 2> "$out.providers.err"; then
        echo "FAIL  assert level: audit providers $t failed (see $out.providers.err)"
        exit 1
    fi
    awk -v l="$t" '
        /ExternalRunnerTestInfo\(/ { on = 1; next }
        on && /^ *command=/ { in_cmd = 1 }
        on && in_cmd && /^ *env=/ { print l "\ttest_command\t" c; exit }
        on && in_cmd { line = $0; sub(/^ */, "", line); c = c (c == "" ? "" : " ") line }
    ' "$out.providers" |
        sed -E 's/<build artifact ([^ ]*) bound to [^>]*>/\1/g; s/\tcommand=\[ cmd_args\( /\t/' >> "$out.test.tsv"
done
check "$out.test.tsv" "$(printf '%s\n' "$TEST_EXPECT" | awk 'NF { $1 = $1 " test_command"; print }')" "buck2 test command of "

if [ -n "$bad" ]; then
    echo "FAIL  assert level: ${bad#; }"
    exit 1
fi
echo "PASS  assert level: $ok expectations over the compile, gated-test, coverage-build (the bitcode's -D list that of the coverage binary) and buck2-test commands (-D ASSERT and defines where set, the memory cap at 4096 MiB by default at ASSERT=none and as set, none of either where unset)"
