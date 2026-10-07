#!/usr/bin/env bash
# coverage_keys.sh -- the coverage switch moves no release action (test 41).
# For each target below, reads its actions from `buck2 aquery` (analysis
# only) with `-c komira.coverage=false`, `=true` and unset, and requires:
#
#   - the target resolves the same execution platform (cquery
#     buck.execution_platform), whose properties go into every remote action;
#   - every action of the target with the switch off exists with it on, with
#     the same command line, the same inputs (the actions that make them,
#     taken from the action graph, one level down) and the same execution
#     attributes (executor preference and configuration, cache upload,
#     weight, dep files: "exec" below);
#   - with it off, no coverage action (category mojo_build_cov_test or
#     mojo_cov_run, or an output under cov/);
#   - with it on, every new action is a coverage action, and there is one
#     mojo_build_cov_test and one mojo_cov_run per test (the count in the
#     table);
#   - with it unset (`-c komira.coverage=`, which clears a global value), every
#     fact is the one of `=false`: the default is off;
#   - on darwin-arm64 with it on, no target has the `coverage_debug` or the
#     `coverage_run` attribute (cquery): another platform builds as with
#     coverage off.
#
# The inputs of a library's mojo_gate_join are read only for a library with no
# README: a README's marker comes from a dynamic action, which aquery cannot
# traverse ("readme" in the table). Its command line is compared either way.
#
# The actions a README's dynamic action declares (its build and run) are
# compared by building each README target with the switch off, then on, and
# requiring every action the second build runs to have run in the first with
# the same digest (`buck2 log what-ran`; cache hits, nothing else is run).
#
# What this cannot see, although the remote action key holds it: an action's
# environment (aquery prints no env; a planted `env =` on a release action
# passes this test), and a source file that is an input but neither on the
# command line nor read through another action (a `hidden` source). The
# rules give none of the compared actions an `env` or a hidden source file.
#
# usage: tools/build/tests/functional/coverage_keys.sh [LOG_DIR]   (from the repo root; BUCK2 overrides the binary)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
BUCK2=${BUCK2:-$ROOT/buck2}
# shellcheck source=tools/build/tests/tool_lib.sh
. "$ROOT/tools/build/tests/tool_lib.sh"
LOG=${1:-${TMPDIR:-/tmp}}

# label, its number of test_srcs, whether it has a README.
TARGETS="
tests//functional/coverage:covlib 2 no
komira//src/komira_retry:komira_retry 6 readme
"

fail() {
    echo "FAIL  coverage keys: $*"
    exit 1
}

labels=$(printf '%s\n' "$TARGETS" | awk 'NF == 3 { print $1 }')
# The execution attributes of an action that aquery prints, compared as one
# fact. Also the aquery -a regular expression, where '.' matches any byte;
# no other attribute name matches it.
EXEC_ATTRS='executor_preference|buck.executor_configuration|allow_cache_upload|allow_dep_file_cache_upload|weight|dep_files|always_print_stderr|no_outputs_cleanup'
# unset: `-c komira.coverage=` clears any value a global buckconfig sets, so
# the macro reads its default.
for c in false true unset; do
    v=$c
    [ "$c" = unset ] && v=""
    q="" dq=""
    while read -r t _ readme; do
        [ -n "$t" ] || continue
        q="$q + all_actions($t)"
        if [ "$readme" = readme ]; then
            dq="$dq + deps(all_actions($t) - attrfilter(category, mojo_gate_join, all_actions($t)), 1)"
        else
            dq="$dq + deps(all_actions($t), 1)"
        fi
    done <<< "$TARGETS"
    out="$LOG/coverage_keys_$c"
    # shellcheck disable=SC2086 # one label per word
    if ! "$BUCK2" cquery "set($(printf '%s ' $labels))" -c "komira.coverage=$v" -a '^buck\.execution_platform$' --json > "$out.platforms.json" 2> "$out.err" ||
        ! "$BUCK2" aquery "${q# + }" -c "komira.coverage=$v" -a "^(category|identifier|cmd|$EXEC_ATTRS)\$" --json > "$out.actions.json" 2>> "$out.err" ||
        ! "$BUCK2" aquery "${dq# + }" -c "komira.coverage=$v" -a '^(category|identifier)$' --json > "$out.nodes.json" 2>> "$out.err" ||
        ! "$BUCK2" aquery "${dq# + }" -c "komira.coverage=$v" --dot > "$out.dot" 2>> "$out.err"; then
        fail "aquery with komira.coverage=$c failed (see $out.err)"
    fi
    for f in platforms actions nodes; do
        inspect_tool json "$out.$f.json" > "$out.$f.tsv" || fail "inspect cannot read $out.$f.json (see $out.$f.tsv)"
    done
    # One fact per line: `<key> TAB cmd|in TAB <value>`, where the key of an
    # action of a listed target is `<label>|<category>|<identifier>` (unique
    # within a target, and the same whatever other actions the target
    # declares), and of any other action its aquery name.
    awk -F '\t' -v LABELS="$labels" -v EXEC_ATTRS="$EXEC_ATTRS" '
        function label(n) { return match(n, /target: `[^ `]+/) ? substr(n, RSTART + 9, RLENGTH - 9) : "" }
        function key(n,    l) {
            l = label(n)
            return (l in mine) ? l "|" cat[n] "|" ident[n] : n
        }
        BEGIN {
            split(LABELS, ls, "\n"); for (i in ls) if (ls[i] != "") mine[ls[i]] = 1
            nx = split(EXEC_ATTRS, xs, "|"); for (i = 1; i <= nx; i++) isx[xs[i]] = 1
        }
        # A target: `<label> (<configuration>) TAB buck.execution_platform TAB <platform>`.
        FILENAME ~ /platforms\.tsv$/ {
            l = $1; sub(/ .*/, "", l)
            if ($2 == "buck.execution_platform") print l "|target\tplatform\t" $3
            next
        }
        FILENAME ~ /actions\.tsv$/ || FILENAME ~ /nodes\.tsv$/ {
            if ($2 == "category") cat[$1] = $3
            else if ($2 == "identifier") ident[$1] = $3
            else if ($2 == "cmd") cmd[$1] = $3
            else if ($2 in isx) x[$1, $2] = $3
            if (FILENAME ~ /actions\.tsv$/) act[$1] = 1
            next
        }
        # The dot graph: `"<action>" -> "<input action>";`
        {
            n = split($0, p, "\"")
            if (n >= 5 && p[3] ~ /->/) edges[p[2]] = edges[p[2]] "\n" p[4]
        }
        END {
            for (a in act) {
                if (!(label(a) in mine)) continue
                k = key(a)
                print k "\tcmd\t" cmd[a]
                e = ""
                for (i = 1; i <= nx; i++) e = e xs[i] "=" x[a, xs[i]] "; "
                print k "\texec\t" e
                if (!(a in edges)) continue
                m = split(substr(edges[a], 2), ch, "\n")
                for (i = 1; i <= m; i++) ch[i] = key(ch[i])
                for (i = 2; i <= m; i++) for (j = i; j > 1 && ch[j - 1] > ch[j]; j--) { t = ch[j]; ch[j] = ch[j - 1]; ch[j - 1] = t }
                s = ""
                for (i = 1; i <= m; i++) s = s (i > 1 ? " + " : "") ch[i]
                print k "\tin\t" s
            }
        }' "$out.platforms.tsv" "$out.actions.tsv" "$out.nodes.tsv" "$out.dot" | LC_ALL=C sort > "$out.facts" ||
        fail "cannot read the action graph of komira.coverage=$c"
done

# The default is off: with the value unset, every fact is the one of =false.
cmp -s "$LOG/coverage_keys_false.facts" "$LOG/coverage_keys_unset.facts" ||
    fail "with komira.coverage unset (the default), $(diff "$LOG/coverage_keys_false.facts" "$LOG/coverage_keys_unset.facts" | grep -c '^[<>]') fact line(s) differ from komira.coverage=false (see $LOG/coverage_keys_false.facts and _unset.facts)"

# Another platform behaves as coverage off: on darwin-arm64, with the switch
# on, no target has a coverage attribute (the select in coverage.bzl), so
# its library declares no coverage action.
DARWIN=komira//tools/build/platforms:darwin-arm64
nt=$(printf '%s\n' "$labels" | grep -c .)
# shellcheck disable=SC2086 # one label per word
"$BUCK2" cquery "set($(printf '%s ' $labels))" --target-platforms "$DARWIN" -c komira.coverage=true -a '^coverage_(debug|run)$' --json > "$LOG/coverage_keys_darwin.json" 2> "$LOG/coverage_keys_darwin.err" ||
    fail "cquery on $DARWIN failed (see $LOG/coverage_keys_darwin.err)"
inspect_tool json "$LOG/coverage_keys_darwin.json" > "$LOG/coverage_keys_darwin.tsv" ||
    fail "inspect cannot read $LOG/coverage_keys_darwin.json"
for attr in coverage_debug coverage_run; do
    nd=$(awk -F '\t' -v A="$attr" '$2 == A && $3 == "null"' "$LOG/coverage_keys_darwin.tsv" | wc -l)
    [ "$nd" -eq "$nt" ] ||
        fail "on $DARWIN with komira.coverage=true, $nd of $nt targets have $attr null: $(awk -F '\t' -v A="$attr" '$2 == A && $3 != "null" { print $1 " = " $3 }' "$LOG/coverage_keys_darwin.tsv" | head -n 3 | paste -sd ';' -)"
done

# A README's actions are declared by a dynamic action, which aquery cannot
# traverse, so they are compared by building (cache hits): each target with a
# README is built with the switch off, then on, in one daemon, and
# `buck2 log what-ran` gives each action a build ran (a cache hit included)
# with its digest. An action whose key did not move is not run again, so
# every action of those targets that the second build runs must have run in
# the first with the same digest; a README action whose command line moves
# with the switch runs again under another digest.
rl=$(printf '%s\n' "$TARGETS" | awk 'NF == 3 && $3 == "readme" { print $1 }')
for c in false true; do
    # shellcheck disable=SC2086 # one label per word
    "$BUCK2" build $rl -c "komira.coverage=$c" > "$LOG/coverage_keys_build_$c.log" 2>&1 ||
        fail "building $(echo $rl) with komira.coverage=$c failed (see $LOG/coverage_keys_build_$c.log)"
    "$BUCK2" log what-ran --format json > "$LOG/coverage_keys_ran_$c.json" 2>> "$LOG/coverage_keys_build_$c.log" ||
        fail "buck2 log what-ran after the komira.coverage=$c build failed (see $LOG/coverage_keys_build_$c.log)"
    inspect_tool json-lines "$LOG/coverage_keys_ran_$c.json" > "$LOG/coverage_keys_ran_$c.lines" ||
        fail "inspect cannot read $LOG/coverage_keys_ran_$c.json"
    # `<identity> TAB <digest>` of each action of a listed target.
    awk -F '\t' -v LABELS="$rl" '
        BEGIN { split(LABELS, ls, "\n"); for (i in ls) if (ls[i] != "") mine[ls[i]] = 1 }
        $2 == "identity" { id[$1] = $3 }
        $2 == "reproducer" && $3 == "details" && $4 == "digest" { dg[$1] = $5 }
        END { for (n in id) { l = id[n]; sub(/ .*/, "", l); if (l in mine) print id[n] "\t" dg[n] } }' "$LOG/coverage_keys_ran_$c.lines" |
        LC_ALL=C sort > "$LOG/coverage_keys_ran_$c.tsv" ||
        fail "cannot list the actions the komira.coverage=$c build ran (from $LOG/coverage_keys_ran_$c.lines)"
done
moved=$(LC_ALL=C comm -13 "$LOG/coverage_keys_ran_false.tsv" "$LOG/coverage_keys_ran_true.tsv") ||
    fail "cannot compare $LOG/coverage_keys_ran_false.tsv and _true.tsv"
[ -z "$moved" ] ||
    fail "with -c komira.coverage=true, building $(echo $rl) ran again, under a digest the build with it off did not have: $(printf '%s\n' "$moved" | cut -f 1 | sed 's/.*) (//; s/)$//' | head -n 5 | paste -sd ';' -) (see $LOG/coverage_keys_ran_false.tsv and _true.tsv)"
nr=$(grep -c . "$LOG/coverage_keys_ran_true.tsv")

awk -F '\t' -v TARGETS="$TARGETS" -v ND="$nd" -v NRAN="$nr" '
    function cov(k,    p) { split(k, p, "|"); return p[2] == "mojo_build_cov_test" || p[2] == "mojo_cov_run" || index(p[3], "cov/") == 1 }
    function tgt(k) { return substr(k, 1, index(k, "|") - 1) }
    # same(k, t): whether fact t (cmd or in) of release action k is the same
    # with the switch off and on, absence included.
    function same(k, t,    f) {
        f = k "\t" t
        if ((f in off) != (f in on)) { bad = bad "; " k ": its " t " fact exists only with coverage " ((f in off) ? "off" : "on"); return 0 }
        if (!(f in off)) return 0
        if (off[f] != on[f]) { bad = bad "; " k ": " (t == "cmd" ? "command line" : t == "in" ? "inputs" : t == "exec" ? "execution attributes" : "execution platform") " differ (off: " off[f] " | on: " on[f] ")"; return 0 }
        return off[f] != ""
    }
    FILENAME ~ /_false\.facts$/ { off[$1 "\t" $2] = $3; offk[$1] = 1; next }
    { on[$1 "\t" $2] = $3; onk[$1] = 1 }
    END {
        bad = ""
        for (k in offk) {
            if (k ~ /\|target$/) { plats += same(k, "platform"); continue }
            if (cov(k)) bad = bad "; " k " exists with coverage off"
            else if (!(k in onk)) bad = bad "; " k " is gone with coverage on"
            else { rel++; cmds += same(k, "cmd"); ins += same(k, "in"); execs += same(k, "exec") }
        }
        for (k in onk) {
            if (k in offk) continue
            if (k ~ /\|target$/) { bad = bad "; " k " has an execution platform only with coverage on"; continue }
            if (!cov(k)) bad = bad "; " k " is new with coverage on and is not a coverage action"
            else if (index(k, "|mojo_build_cov_test|")) builds[tgt(k)]++
            else if (index(k, "|mojo_cov_run|")) runs[tgt(k)]++
            else other++
        }
        m = split(TARGETS, ls, "\n")
        for (i = 1; i <= m; i++) {
            if (split(ls[i], f, " ") != 3) continue
            nt++
            if (builds[f[1]] + 0 != f[2]) bad = bad "; " f[1] " has " (builds[f[1]] + 0) " mojo_build_cov_test action(s) with coverage on, expected " f[2]
            if (runs[f[1]] + 0 != f[2]) bad = bad "; " f[1] " has " (runs[f[1]] + 0) " mojo_cov_run action(s) with coverage on, expected " f[2]
            nb += builds[f[1]]
            nr += runs[f[1]]
        }
        if (plats != nt) bad = bad "; the execution platform of " plats " of " nt " targets was compared"
        if (bad != "") { print "FAIL  coverage keys: " substr(bad, 3); exit 1 }
        print "PASS  coverage keys: with -c komira.coverage=true, the " plats " targets keep their execution platform, and the " rel " release actions are all there, " cmds " command lines, " ins " input sets and " execs " sets of execution attributes unchanged; the " nb " mojo_build_cov_test, " nr " mojo_cov_run and " other " other coverage actions exist only with it; unset is false; on darwin-arm64 none of the " ND " targets has a coverage attribute; a build with it on after one with it off ran " NRAN " action(s) of the README targets again, each under the digest it had"
    }' "$LOG/coverage_keys_false.facts" "$LOG/coverage_keys_true.facts"
