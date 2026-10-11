#!/usr/bin/env bash
# coverage_keys.sh -- the coverage switch moves no release action of a
# library, its package's join included; of its conda package, only the
# joins, which wait for the coverage runs and the gate (tests 41 and 46).
# For each target below, reads its actions from `buck2 aquery` (analysis
# only) with `-c komira.coverage=false`, `=true` and unset, and requires:
#
#   - the target resolves the same execution platform (cquery
#     buck.execution_platform), whose properties go into every remote action;
#   - every action of the target with the switch off exists with it on, with
#     the same command line, the same inputs (the actions that make them,
#     taken from the action graph, one level down) and the same execution
#     attributes (executor preference and configuration, cache upload,
#     weight, dep files: "exec" below). That includes the package's join
#     (mojo_gate_join): it waits for the library's tests and nothing of
#     coverage, so the package every dependent compiles against is the same
#     action. The one exception is a conda package's (`conda` below): the
#     inputs of its joins (conda_join, conda_release_join) are, with it on,
#     those of it off and coverage actions, exactly one coverage run per
#     test of its library (and one of its README's examples, for a library
#     with a README) and one gate (what ships waits for them), and no
#     branch coverage action (the gate reads those, so what ships waits for
#     them through the gate);
#   - a library with no test and no README (a count of 0 below) has no join
#     either way (its package is the compiler's output);
#   - with it off, no coverage action (category mojo_build_cov_test,
#     mojo_cov_run, mojo_cov_gate, mojo_emit_cov_bc, mojo_cov_pgo_link,
#     mojo_cov_branch_run, mojo_cov_branch_annotate or
#     mojo_cov_branch_classify, or an output under cov/);
#   - with it on, every new action is a coverage action, and a library has
#     one mojo_build_cov_test and one mojo_cov_run more and one
#     mojo_cov_readme_source when it has a README (its examples' run, with
#     no branch coverage action), a mojo_test one mojo_build_cov_test and
#     nothing else (its runs are its libraries'), and a library
#     one mojo_build_cov_test, one mojo_cov_run, one mojo_emit_cov_bc, one
#     mojo_cov_pgo_link, one mojo_cov_branch_run, one mojo_cov_branch_annotate
#     and one mojo_cov_branch_classify per test (the count in the table) and
#     one mojo_cov_gate, a conda package none; the gate's inputs hold each
#     test's mojo_cov_run, and each test's mojo_cov_branch_classify for a
#     library whose gate reads its branch records ("reads" in the table: a
#     fixture of the tests cell, or komira_retry, a library of
#     COVERAGE_BRANCH_GATE in tools/build/coverage/policy.bzl) and none for
#     one whose gate does not ("unread": komira_rowcell, not in that list);
#   - with it unset (`-c komira.coverage=`, which clears a global value), every
#     fact is the one of `=false`: the default is off;
#   - on darwin-arm64 with it on, no library has the `coverage_debug`, the
#     `coverage_run`, the `coverage_branch` or the `coverage_gate` attribute,
#     and no mojo_test the `coverage_debug` attribute (cquery): another
#     platform builds as with coverage off.
#
# The inputs of a library's mojo_gate_join are read only for a library with no
# README: a README's marker comes from a dynamic action, which aquery cannot
# traverse ("readme" in the table). Its command line is compared either way.
#
# The actions a README's dynamic action declares (its build and run) are
# compared by building each README target and each target marked `build`
# or `conda` with the switch off in a fresh daemon (`buck2 kill` first: the
# daemon of this checkout only), then on in the same daemon, and reading what
# each build ran (`buck2 log what-ran`; cache hits included) with its digest.
# The actions the second build ran under a digest the first did not have
# must be exactly, for each conda package, one mojo_build_cov_test and one
# mojo_cov_run per test of its library (its README's included, with its
# mojo_cov_readme_source), if the library's gate reads its
# branch records ("reads" in the table) each test's branch coverage actions
# (mojo_emit_cov_bc, mojo_cov_pgo_link, mojo_cov_branch_run,
# mojo_cov_branch_annotate and mojo_cov_branch_classify: the gate reads the
# last), the library's one mojo_cov_gate and the package's conda_join (what
# ships waits for them; its
# conda_release_join is not built: the release check needs a stamp), and
# nothing else: no release action of a library, its join included, runs
# again, and no branch coverage action of a library whose gate does not
# read them ("unread") runs at all. Exactly, so the check fails both when a release action moves and
# when what ships stops waiting for coverage (no coverage action would run).
# A fresh daemon is what makes the first list complete: a daemon that had
# built either state before lists only the actions it recomputes. covuser
# depends on covlib: its compile and test not running again proves covlib's
# package (the join's output) has the same bytes with the switch on, so a
# dependent keeps its cache hits.
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

# label, its number of test_srcs (of a conda package: its library's; of a
# mojo_test: 1, its coverage binary), readme (it has a README, so it is also
# built), build (built), conda (a conda package `<library>_conda`, also
# built), test (a mojo_test), or no, whether its gate (of a conda package:
# its library's) reads its tests' branch records (reads) or not (unread),
# and the number of its README's coverage runs (1 for a library with a
# README: its examples, or a program that runs nothing, run like a test,
# with no branch coverage action; 0 otherwise).
TARGETS="
tests//functional/coverage:covlib 2 no reads 0
tests//functional/coverage:covbare 0 no reads 0
tests//functional/coverage:covuser 1 build reads 0
komira//src/komira_retry:komira_retry 6 readme reads 1
komira//src/komira_retry:komira_retry_conda 6 conda reads 1
komira//src/komira_rowcell:komira_rowcell 1 readme unread 1
komira//tools/build/examples:test_hellopkg 1 test unread 0
"

fail() {
    echo "FAIL  coverage keys: $*"
    exit 1
}

labels=$(printf '%s\n' "$TARGETS" | awk 'NF == 5 { print $1 }')
libs=$(printf '%s\n' "$TARGETS" | awk 'NF == 5 && $3 != "conda" && $3 != "test" { print $1 }')
tests=$(printf '%s\n' "$TARGETS" | awk 'NF == 5 && $3 == "test" { print $1 }')
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
    while read -r t _ readme _; do
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
# on, no library has a coverage attribute (the select in coverage.bzl), so
# it declares no coverage action. A darwin-arm64 target configures only with
# a macOS execution platform registered (a library's README tool is an exec
# dep), which a checkout without `[komira_re] darwin_arm64_properties` has
# not, so the query registers placeholder macOS properties and hosts, as
# tools/build/tests/functional/darwin/check.sh does: analysis only, nothing
# runs on them.
DARWIN=komira//tools/build/platforms:darwin-arm64
DARWIN_PLACEHOLDER=(-c komira_re.darwin_arm64_properties=pool=unreachable-check-only -c komira_re.darwin_macos_hosts=0.0-check)
nt=$(printf '%s\n' "$libs" | grep -c .)
# shellcheck disable=SC2086 # one label per word
"$BUCK2" cquery "set($(printf '%s ' $libs))" --target-platforms "$DARWIN" "${DARWIN_PLACEHOLDER[@]}" -c komira.coverage=true -a '^coverage_(debug|run|branch|gate)$' --json > "$LOG/coverage_keys_darwin.json" 2> "$LOG/coverage_keys_darwin.err" ||
    fail "cquery on $DARWIN failed (see $LOG/coverage_keys_darwin.err)"
inspect_tool json "$LOG/coverage_keys_darwin.json" > "$LOG/coverage_keys_darwin.tsv" ||
    fail "inspect cannot read $LOG/coverage_keys_darwin.json"
for attr in coverage_debug coverage_run coverage_branch coverage_gate; do
    nd=$(awk -F '\t' -v A="$attr" '$2 == A && $3 == "null"' "$LOG/coverage_keys_darwin.tsv" | wc -l)
    [ "$nd" -eq "$nt" ] ||
        fail "on $DARWIN with komira.coverage=true, $nd of $nt targets have $attr null: $(awk -F '\t' -v A="$attr" '$2 == A && $3 != "null" { print $1 " = " $3 }' "$LOG/coverage_keys_darwin.tsv" | head -n 3 | paste -sd ';' -)"
done
# A mojo_test's one coverage attribute, its coverage binary's link directory.
ntt=$(printf '%s\n' "$tests" | grep -c .)
# shellcheck disable=SC2086 # one label per word
"$BUCK2" cquery "set($(printf '%s ' $tests))" --target-platforms "$DARWIN" -c komira.coverage=true -a '^coverage_debug$' --json > "$LOG/coverage_keys_darwin_tests.json" 2>> "$LOG/coverage_keys_darwin.err" ||
    fail "cquery of the mojo_test targets on $DARWIN failed (see $LOG/coverage_keys_darwin.err)"
inspect_tool json "$LOG/coverage_keys_darwin_tests.json" > "$LOG/coverage_keys_darwin_tests.tsv" ||
    fail "inspect cannot read $LOG/coverage_keys_darwin_tests.json"
ndt=$(awk -F '\t' '$2 == "coverage_debug" && $3 == "null"' "$LOG/coverage_keys_darwin_tests.tsv" | wc -l)
[ "$ndt" -eq "$ntt" ] && [ "$ntt" -gt 0 ] ||
    fail "on $DARWIN with komira.coverage=true, $ndt of $ntt mojo_test targets have coverage_debug null"
nd=$((nd + ndt))

# A README's actions are declared by a dynamic action, which aquery cannot
# traverse, so they are compared by building (cache hits): each target with a
# README or marked `build` or `conda` is built with the switch off, then on,
# in one daemon, and `buck2 log what-ran` gives each action a build ran (a
# cache hit included) with its digest. An action whose key did not move is
# not run again, so the actions the second build runs under a new digest
# are exactly those that wait for coverage or are coverage: per conda
# package, its library's builds, runs, gate and, if the gate reads them, the
# branch coverage actions, and its conda_join. A README
# action whose command line moves with the switch runs again under another
# digest, and so does a compile of covuser if covlib's package changed
# bytes; a conda package that stops waiting for coverage runs none of them.
rl=$(printf '%s\n' "$TARGETS" | awk 'NF == 5 && ($3 == "readme" || $3 == "build" || $3 == "conda") { print $1 }')
"$BUCK2" kill > "$LOG/coverage_keys_kill.log" 2>&1 ||
    fail "buck2 kill before the komira.coverage=false build failed (see $LOG/coverage_keys_kill.log)"
for c in false true; do
    # shellcheck disable=SC2086 # one label per word
    "$BUCK2" build $rl -c "komira.coverage=$c" > "$LOG/coverage_keys_build_$c.log" 2>&1 ||
        fail "building $(echo $rl) with komira.coverage=$c failed (see $LOG/coverage_keys_build_$c.log)"
    "$BUCK2" log what-ran --format json > "$LOG/coverage_keys_ran_$c.json" 2>> "$LOG/coverage_keys_build_$c.log" ||
        fail "buck2 log what-ran after the komira.coverage=$c build failed (see $LOG/coverage_keys_build_$c.log)"
    inspect_tool json-lines "$LOG/coverage_keys_ran_$c.json" > "$LOG/coverage_keys_ran_$c.lines" ||
        fail "inspect cannot read $LOG/coverage_keys_ran_$c.json"
    # `<identity> TAB <digest>` of each action of a listed target (a conda
    # package's library included: its coverage actions are the library's).
    awk -F '\t' -v LABELS="$rl" '
        BEGIN { split(LABELS, ls, "\n"); for (i in ls) if (ls[i] != "") { mine[ls[i]] = 1; l = ls[i]; if (sub(/_conda$/, "", l)) mine[l] = 1 } }
        $2 == "identity" { id[$1] = $3 }
        $2 == "reproducer" && $3 == "details" && $4 == "digest" { dg[$1] = $5 }
        END { for (n in id) { l = id[n]; sub(/ .*/, "", l); if (l in mine) print id[n] "\t" dg[n] } }' "$LOG/coverage_keys_ran_$c.lines" |
        LC_ALL=C sort > "$LOG/coverage_keys_ran_$c.tsv" ||
        fail "cannot list the actions the komira.coverage=$c build ran (from $LOG/coverage_keys_ran_$c.lines)"
done
LC_ALL=C comm -13 "$LOG/coverage_keys_ran_false.tsv" "$LOG/coverage_keys_ran_true.tsv" > "$LOG/coverage_keys_moved.tsv" ||
    fail "cannot compare $LOG/coverage_keys_ran_false.tsv and _true.tsv"
# An identity is `<label> (<configuration>) (<category>[ <identifier>])`.
# The moved actions, as `<label> <category>` counts, must be exactly the
# expected ones.
moved=$(awk -F '\t' -v TARGETS="$TARGETS" '
    BEGIN {
        nb = split("mojo_emit_cov_bc mojo_cov_pgo_link mojo_cov_branch_run mojo_cov_branch_annotate mojo_cov_branch_classify", bc, " ")
        m = split(TARGETS, ls, "\n")
        for (i = 1; i <= m; i++) {
            if (split(ls[i], f, " ") != 5 || f[3] != "conda") continue
            l = f[1]; sub(/_conda$/, "", l)
            want[l " mojo_build_cov_test"] += f[2] + f[5]; want[l " mojo_cov_run"] += f[2] + f[5]
            if (f[5] > 0) want[l " mojo_cov_readme_source"] += f[5]
            want[l " mojo_cov_gate"] += 1; want[f[1] " conda_join"] += 1
            # The gate reads the branch record of each test, made by this chain.
            if (f[4] == "reads") for (j = 1; j <= nb; j++) want[l " " bc[j]] += f[2]
        }
    }
    {
        l = $1; sub(/ .*/, "", l)
        c = $1; sub(/.*\(/, "", c); sub(/[ )].*/, "", c)
        got[l " " c]++
    }
    END {
        for (k in got) if (got[k] != want[k] + 0) print k ": ran " got[k] " under a new digest, expected " (want[k] + 0)
        for (k in want) if (!(k in got)) print k ": ran 0 under a new digest, expected " want[k]
    }' "$LOG/coverage_keys_moved.tsv" | LC_ALL=C sort) ||
    fail "cannot count the actions that ran again (from $LOG/coverage_keys_moved.tsv)"
[ -z "$moved" ] ||
    fail "with -c komira.coverage=true, building $(echo $rl) after it off: $(printf '%s\n' "$moved" | head -n 5 | paste -sd ';' -) (see $LOG/coverage_keys_ran_false.tsv and _true.tsv)"
nr=$(grep -c . "$LOG/coverage_keys_ran_true.tsv")
nm=$(grep -c . "$LOG/coverage_keys_moved.tsv")

awk -F '\t' -v TARGETS="$TARGETS" -v ND="$nd" -v NRAN="$nr" -v NMOVED="$nm" '
    function cov(k,    p) { split(k, p, "|"); return p[2] == "mojo_build_cov_test" || p[2] == "mojo_cov_run" || p[2] == "mojo_cov_gate" || p[2] == "mojo_cov_readme_source" || p[2] in branchcat || index(p[3], "cov/") == 1 }
    function tgt(k) { return substr(k, 1, index(k, "|") - 1) }
    # shipjoin(k): k is a join of a conda package (what ships).
    function shipjoin(k) { return kind[tgt(k)] == "conda" && (index(k, "|conda_join|") || index(k, "|conda_release_join|")) }
    # joined(k): the inputs of conda join k with the switch on are those
    # with it off and coverage actions: one coverage run per test of its
    # library and one gate, and no branch coverage action.
    function joined(k,    f, a, b, n, m, i, j, seen, extra, q, nrun, ngate) {
        f = k "\tin"
        if (!(f in off) || !(f in on)) { bad = bad "; " k ": its inputs were not read with coverage " ((f in off) ? "on" : "off"); return 0 }
        n = split(off[f], a, / \+ /); m = split(on[f], b, / \+ /)
        for (j = 1; j <= m; j++) seen[b[j]] = 1
        for (i = 1; i <= n; i++) if (!(a[i] in seen)) bad = bad "; " k ": input " a[i] " is gone with coverage on"
        delete seen
        for (i = 1; i <= n; i++) seen[a[i]] = 1
        extra = 0; nrun = 0; ngate = 0
        for (j = 1; j <= m; j++) if (!(b[j] in seen)) {
            if (!cov(b[j])) { bad = bad "; " k ": input " b[j] " is new with coverage on and is not a coverage action"; continue }
            extra++
            split(b[j], q, "|")
            if (q[2] == "mojo_cov_run") nrun++
            else if (q[2] == "mojo_cov_gate") ngate++
            else if (q[2] in branchcat) bad = bad "; " k ": input " b[j] " is a branch coverage action, which only the gate waits for"
        }
        if (nrun != ntests[tgt(k)] + nreadme[tgt(k)] || ngate != 1 || extra != nrun + ngate) bad = bad "; " k ": with coverage on its inputs gained " nrun " coverage run(s), " ngate " gate(s) and " (extra - nrun - ngate) " other coverage action(s), expected " (ntests[tgt(k)] + nreadme[tgt(k)]) ", 1 and 0 (what ships waits for the runs, the README run included, and the gate)"
        return 1
    }
    # gate_in(k): the inputs of gate k, with the switch on, hold one
    # mojo_cov_run per test of its target and, if its gate reads them, one
    # mojo_cov_branch_classify per test (none otherwise), each an action of
    # that target.
    function gate_in(k,    b, m, j, q, nrun, ncls, want) {
        m = split(on[k "\tin"], b, / \+ /)
        nrun = 0; ncls = 0
        for (j = 1; j <= m; j++) {
            split(b[j], q, "|")
            if (q[1] != tgt(k)) continue
            if (q[2] == "mojo_cov_run") nrun++
            else if (q[2] == "mojo_cov_branch_classify") ncls++
        }
        want = reads[tgt(k)] == "reads" ? ntests[tgt(k)] : 0
        if (nrun != ntests[tgt(k)] + nreadme[tgt(k)] || ncls != want) bad = bad "; " k ": its inputs hold " nrun " coverage run(s) and " ncls " branch record action(s), expected " (ntests[tgt(k)] + nreadme[tgt(k)]) " and " want " (" reads[tgt(k)] ")"
        gins += ncls
    }
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
    BEGIN {
        branchcat["mojo_emit_cov_bc"] = 1; branchcat["mojo_cov_pgo_link"] = 1; branchcat["mojo_cov_branch_run"] = 1
        branchcat["mojo_cov_branch_annotate"] = 1; branchcat["mojo_cov_branch_classify"] = 1
    }
    END {
        bad = ""
        m = split(TARGETS, ls, "\n")
        for (i = 1; i <= m; i++) if (split(ls[i], f, " ") == 5) { ntests[f[1]] = f[2]; kind[f[1]] = f[3]; reads[f[1]] = f[4]; nreadme[f[1]] = f[5] }
        for (k in offk) {
            if (k ~ /\|target$/) { plats += same(k, "platform"); continue }
            if (cov(k)) bad = bad "; " k " exists with coverage off"
            else if (!(k in onk)) bad = bad "; " k " is gone with coverage on"
            else if (shipjoin(k)) { rel++; cmds += same(k, "cmd"); joins += joined(k); execs += same(k, "exec"); nship[tgt(k)]++ }
            else {
                rel++; cmds += same(k, "cmd"); ins += same(k, "in"); execs += same(k, "exec")
                if (index(k, "|mojo_gate_join|")) pkgjoins++
            }
        }
        for (k in onk) {
            if (k in offk) continue
            if (k ~ /\|target$/) { bad = bad "; " k " has an execution platform only with coverage on"; continue }
            if (!cov(k)) bad = bad "; " k " is new with coverage on and is not a coverage action" (index(k, "|mojo_gate_join|") ? " (a package join: nothing of a library may wait for coverage)" : "")
            else if (index(k, "|mojo_build_cov_test|")) builds[tgt(k)]++
            else if (index(k, "|mojo_cov_run|")) runs[tgt(k)]++
            else if (index(k, "|mojo_cov_gate|")) { gates[tgt(k)]++; gate_in(k) }
            else if (index(k, "|mojo_cov_readme_source|")) readmes[tgt(k)]++
            else if (split(k, q, "|") >= 2 && q[2] in branchcat) branch[tgt(k), q[2]]++
            else other++
        }
        for (i = 1; i <= m; i++) {
            if (split(ls[i], f, " ") != 5) continue
            nt++
            # A mojo_test has its coverage binary alone: its runs and gate
            # are those of each library naming it (<name>_cov_gate).
            want = f[3] == "conda" ? 0 : f[2]
            wr = f[3] == "conda" ? 0 : f[5]
            wrun = f[3] == "test" ? 0 : want + wr
            if (builds[f[1]] + 0 != want + wr) bad = bad "; " f[1] " has " (builds[f[1]] + 0) " mojo_build_cov_test action(s) with coverage on, expected " (want + wr)
            if (runs[f[1]] + 0 != wrun) bad = bad "; " f[1] " has " (runs[f[1]] + 0) " mojo_cov_run action(s) with coverage on, expected " wrun
            if (readmes[f[1]] + 0 != wr) bad = bad "; " f[1] " has " (readmes[f[1]] + 0) " mojo_cov_readme_source action(s) with coverage on, expected " wr
            if (gates[f[1]] + 0 != (f[3] == "conda" || f[3] == "test" ? 0 : 1)) bad = bad "; " f[1] " has " (gates[f[1]] + 0) " mojo_cov_gate action(s) with coverage on, expected " (f[3] == "conda" || f[3] == "test" ? 0 : 1)
            if (f[3] == "test") want = 0
            for (c in branchcat) {
                if (branch[f[1], c] + 0 != want) bad = bad "; " f[1] " has " (branch[f[1], c] + 0) " " c " action(s) with coverage on, expected " want
                nbr += branch[f[1], c]
            }
            if (f[3] == "conda" && nship[f[1]] + 0 != 2) bad = bad "; " f[1] ": " (nship[f[1]] + 0) " of its conda_join and conda_release_join were read, expected 2"
            if (f[3] == "conda") nc++
            if (f[2] == 0 && f[3] != "readme" && f[3] != "conda" && ((f[1] "|mojo_gate_join|") in offk || (f[1] "|mojo_gate_join|") in onk)) bad = bad "; " f[1] " (no test, no README) has a join: its package must be the compiler output"
            nb += builds[f[1]]
            nrd += readmes[f[1]]
            nr += runs[f[1]]
            ng += gates[f[1]]
        }
        if (plats != nt) bad = bad "; the execution platform of " plats " of " nt " targets was compared"
        if (joins != 2 * nc) bad = bad "; " joins " conda join(s) compared, expected " (2 * nc)
        if (bad != "") { print "FAIL  coverage keys: " substr(bad, 3); exit 1 }
        print "PASS  coverage keys: with -c komira.coverage=true, the " plats " targets keep their execution platform, and the " rel " release actions (" (pkgjoins + 0) " of them package joins) are all there, " cmds " command lines, " ins " input sets and " execs " sets of execution attributes unchanged, but " joins " conda join(s) whose inputs gained one coverage run per test and the gate; the " nb " mojo_build_cov_test, " nr " mojo_cov_run, " ng " mojo_cov_gate, " (nrd + 0) " mojo_cov_readme_source (a README run each), " (nbr + 0) " branch coverage (mojo_emit_cov_bc, mojo_cov_pgo_link, mojo_cov_branch_run, mojo_cov_branch_annotate, mojo_cov_branch_classify, one each per test, none a join input, the " (gins + 0) " mojo_cov_branch_classify inputs of the gates that read them and none of those that do not) and " other " other coverage actions exist only with it; unset is false; on darwin-arm64 none of the " ND " targets has a coverage attribute; a build with it on after one with it off ran " NRAN " action(s) of the built targets, " NMOVED " of them under a new digest, exactly the coverage builds, runs, branch actions (of a gate that reads them) and gate and the conda join"
    }' "$LOG/coverage_keys_false.facts" "$LOG/coverage_keys_true.facts"
