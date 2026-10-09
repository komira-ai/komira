#!/usr/bin/env bash
# coverage_shared_lib.sh -- the coverage switch moves no release action of a
# shared library (mojo_shared_lib; test 43). For each target below, reads its
# actions from `buck2 aquery` (analysis only) with `-c komira.coverage=false`
# and `=true`, and requires:
#
#   - every action with the switch off exists with it on, with the same
#     command line;
#   - the published file's join (mojo_shared_lib_join) waits for the same
#     actions (its direct inputs, as category and identifier): the release
#     gate's runs and the library, and no coverage action;
#   - every action that exists only with the switch on is a coverage action
#     (of the categories below, or with an output under cov/), and there
#     are exactly one mojo_build_cov_shared_lib (the library at -O0 with line
#     tables), and per driver (the count below) one mojo_build_cov_driver
#     and one mojo_cov_run, and one mojo_cov_gate.
#
# What this cannot see: an action's environment and a hidden source input
# (aquery prints neither), as for coverage_keys.sh.
#
# usage: tools/build/tests/functional/coverage_shared_lib.sh [LOG_DIR]   (from the repo root; BUCK2 overrides the binary)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
BUCK2=${BUCK2:-$ROOT/buck2}
# shellcheck source=tools/build/tests/tool_lib.sh
. "$ROOT/tools/build/tests/tool_lib.sh"
LOG=${1:-${TMPDIR:-/tmp}}

# label, its number of gate_srcs drivers
TARGETS="
komira//tools/build/examples/shared_lib:spike 1
komira//tools/build/examples/shared_lib:plain_exact 1
"

fail() {
    echo "FAIL  coverage shared lib: $*"
    exit 1
}

for c in false true; do
    out="$LOG/coverage_shared_lib_$c"
    q="" jq=""
    while read -r t _; do
        [ -n "$t" ] || continue
        q="$q + all_actions($t)"
        jq="$jq + deps(attrfilter(category, mojo_shared_lib_join, all_actions($t)), 1)"
    done <<< "$TARGETS"
    if ! "$BUCK2" aquery "${q# + }" -c "komira.coverage=$c" -a '^(category|identifier|cmd)$' --json > "$out.actions.json" 2> "$out.err" ||
        ! "$BUCK2" aquery "${jq# + }" -c "komira.coverage=$c" -a '^(category|identifier)$' --json > "$out.join.json" 2>> "$out.err"; then
        fail "aquery with komira.coverage=$c failed (see $out.err)"
    fi
    for f in actions join; do
        inspect_tool json "$out.$f.json" > "$out.$f.tsv" || fail "inspect cannot read $out.$f.json"
    done
    # `<label>|<category>|<identifier> TAB cmd|join TAB <value>`: each
    # action's command line, and each direct input of a join (the join
    # itself included, as deps() gives it).
    awk -F '\t' '
        function label(n) { return match(n, /target: `[^ `]+/) ? substr(n, RSTART + 9, RLENGTH - 9) : "" }
        FILENAME ~ /actions\.tsv$/ {
            if ($2 == "category") cat[$1] = $3
            else if ($2 == "identifier") ident[$1] = $3
            else if ($2 == "cmd") cmd[$1] = $3
            act[$1] = 1
            next
        }
        {
            if ($2 == "category") jcat[$1] = $3
            else if ($2 == "identifier") jid[$1] = $3
            jn[$1] = 1
        }
        END {
            for (a in act) print label(a) "|" cat[a] "|" ident[a] "\tcmd\t" cmd[a]
            for (a in jn) print label(a) "|" jcat[a] "|" jid[a] "\tjoin\t-"
        }' "$out.actions.tsv" "$out.join.tsv" | LC_ALL=C sort > "$out.facts" ||
        fail "cannot read the actions of komira.coverage=$c"
done

awk -F '\t' -v TARGETS="$TARGETS" '
    # A coverage action: of a coverage category, or with an output under cov/
    # (its staging and writes; the identifier is the output path).
    function cov(c, id) { return c == "mojo_build_cov_shared_lib" || c == "mojo_build_cov_driver" || c == "mojo_cov_run" || c == "mojo_cov_gate" || index(id, "cov/") == 1 }
    FILENAME ~ /_false\.facts$/ { off[$1 "\t" $2] = $3; next }
    { on[$1 "\t" $2] = $3 }
    END {
        bad = ""
        m = split(TARGETS, ls, "\n")
        for (i = 1; i <= m; i++) if (split(ls[i], f, " ") == 2) drivers[f[1]] = f[2]
        for (k in off) {
            split(k, t, "\t"); split(t[1], p, "|")
            if (cov(p[2], p[3])) bad = bad "; " k " exists with coverage off"
            else if (!(k in on)) bad = bad "; " k " is gone with coverage on"
            else if (off[k] != on[k]) bad = bad "; " k " differs (off: " off[k] " | on: " on[k] ")"
            else if (t[2] == "cmd") cmds++
            else joins++
        }
        for (k in on) {
            if (k in off) continue
            split(k, t, "\t"); split(t[1], p, "|")
            if (t[2] == "join") bad = bad "; " k " is an input of the published file only with coverage on"
            else if (!cov(p[2], p[3])) bad = bad "; " k " is new with coverage on and is not a coverage action"
            else { n[p[1], p[2]]++; new++ }
        }
        for (l in drivers) {
            nt++
            if (n[l, "mojo_build_cov_shared_lib"] + 0 != 1) bad = bad "; " l " has " (n[l, "mojo_build_cov_shared_lib"] + 0) " mojo_build_cov_shared_lib, expected 1"
            if (n[l, "mojo_build_cov_driver"] + 0 != drivers[l]) bad = bad "; " l " has " (n[l, "mojo_build_cov_driver"] + 0) " mojo_build_cov_driver, expected " drivers[l]
            if (n[l, "mojo_cov_run"] + 0 != drivers[l]) bad = bad "; " l " has " (n[l, "mojo_cov_run"] + 0) " mojo_cov_run, expected " drivers[l]
            if (n[l, "mojo_cov_gate"] + 0 != 1) bad = bad "; " l " has " (n[l, "mojo_cov_gate"] + 0) " mojo_cov_gate, expected 1"
        }
        if (joins < 2 * nt) bad = bad "; only " (joins + 0) " join inputs were read for " nt " targets"
        if (bad != "") { print "FAIL  coverage shared lib: " substr(bad, 3); exit 1 }
        print "PASS  coverage shared lib: with -c komira.coverage=true, the " cmds " release actions of the " nt " shared libraries keep their command lines, their published files the same " joins " inputs, and the " new " new actions are their coverage builds, runs and gates"
    }' "$LOG/coverage_shared_lib_false.facts" "$LOG/coverage_shared_lib_true.facts"
