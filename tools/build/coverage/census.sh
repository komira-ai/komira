#!/bin/sh
# census.sh -- the coverage census of every library: one coverage build of
# each library's gate, its numbers as data (census.tsv, which census_files
# splits into each package's coverage_census.tsv), the ranked table rendered
# from it with each package's holds (the doc //:coverage_census builds).
#
# usage: census.sh run     --out <dir> [--cap <seconds>] [--attempts <n>] [--batch <n>] [--skip <file>]
#        census.sh collect --out <dir> [--skip <file>] [--source <commit>] [--note <text>]
#
# run and collect are run by hand at the top of a checkout (they call
# ./buck2, so the coverage build runs where the build runs). They are not build
# actions: the build actions of //:coverage_census (the doc and its check) are
# census_render (census_render.zig).
#
#   run      lists the libraries under src/ (`kind(mojo_library_rule,
#            //src/...)`, into <dir>/libraries.txt unless it exists) and
#            builds every one's gate result with -c komira.coverage=true and
#            --keep-going, each invocation under <cap> seconds (default 265)
#            with a build report <dir>/report.<n>.json; an invocation the
#            cap stops (exit 124) is run again, the cache keeping what
#            finished, up to <attempts> (default 40) times. With --batch N
#            the libraries are first built N at a time, each group to its end
#            the same way (fewer actions in flight when the cap stops one, so
#            less work is lost), and then all of them in one invocation, which
#            finds the groups' actions in the cache and writes the report
#            collect reads. A library with a `<name>_cov_gate` target
#            (one of the ledger COVERAGE_NO_GATE, or one naming mojo_test
#            targets in `coverage_tests`) has its gate there.
#            --skip names libraries not to build, one `<label><TAB><why>` per
#            line: one whose failing run outlasts the cap (a failed action is
#            not cached, so it runs again in every invocation and no
#            invocation finishes). collect records each as RUN_FAILED, `not
#            built in this census: <why>`.
#   collect  writes <dir>/census.tsv from the last report run wrote: per
#            library its status (OK with its gate's result.json; RUN_FAILED
#            when an action before its gate failed, GATE_FAILED when the
#            gate did, each with the failing actions and the first error
#            line of their output), the gate's line and branch numbers,
#            whether it is in COVERAGE_BRANCH_GATE (policy.bzl), the files
#            no test compiles (its UnmeasuredFile findings), and whether it
#            is published: `release` (its `<name>_conda` is a target of
#            release/artifacts.textproto), `conda` (it has a `<name>_conda`)
#            or `no`. --source names the commit measured (default: HEAD of
#            the checkout) and --note says anything else the census line
#            must (a fix applied to it, say). Then split the files into the
#            packages (census_files; census.md says how).
# census.tsv: comment lines start with '#'; then the line
# `census<TAB><date YYYY-MM-DD><TAB><source commit, 40 hex, or -><TAB><note or ->`; then one
# row per library, sorted by label in byte order, 12 fields separated by tabs:
#   library      the label (komira//src/<package>:<name>)
#   package      its directory (src/<package>)
#   kind         library, or test for a library under src/tests/ (shown as
#                information: test code is not held to the target)
#   status       OK, RUN_FAILED or GATE_FAILED
#   line_hit line_found      the gate's line numbers, `-` when not OK
#   branch_hit branch_found  the gate's branch numbers (0 0 when it read
#                branch records with no decision), `-` for a library not in
#                COVERAGE_BRANCH_GATE, whose gate reads none (or not OK)
#   branch_gate  yes when the library is in COVERAGE_BRANCH_GATE, else no
#   published    release, conda or no
#   unmeasured   the files no test compiles, comma-separated, or -
#   note         why it is not OK, or -
# then, when a gate left out generated sources (first line `# @generated`,
# covcheck/generated.mojo), one line each, sorted, after every row:
#   generated<TAB><repository path of the file>
# census_files split writes each into the census file of the package that holds
# the path, so a file that gains the marker is a diff of that file.
set -eu

usage() { echo "census.sh: $*" >&2; echo "usage: census.sh run|collect --out <dir> ..." >&2; exit 2; }
[ "$#" -ge 1 ] || usage "no command"
CMD=$1
shift
case "$CMD" in
run | collect) ;;
*) usage "unknown command $CMD" ;;
esac

# ---- run and collect: at the top of a checkout, with ./buck2 -------------

OUT="" CAP=265 ATTEMPTS=40 SKIP=/dev/null BATCH=0 SRC="" NOTE=-
while [ "$#" -gt 0 ]; do
    case "$1" in
    --out) OUT=$2 ;;
    --cap) CAP=$2 ;;
    --attempts) ATTEMPTS=$2 ;;
    --skip) SKIP=$2 ;;
    --batch) BATCH=$2 ;;
    --source) SRC=$2 ;;
    --note) NOTE=$2 ;;
    *) usage "unknown flag $1" ;;
    esac
    shift 2 || usage "$1 takes a value"
done
[ -n "$OUT" ] || usage "--out is required"
[ -x ./buck2 ] && [ -f tools/build/coverage/policy.bzl ] || usage "run it at the top of a komira checkout"
mkdir -p "$OUT"
BB=$(./buck2 build komira//tools/build/toolchains:busybox --show-full-simple-output 2>/dev/null | tail -1)
[ -x "$BB" ] || { echo "census.sh: cannot build the pinned busybox" >&2; exit 1; }
target_of() { # label -> the target whose output is its gate's result
    "$BB" grep -qxF -- "${1}_cov_gate" "$OUT/cov_gates.txt" && { echo "${1}_cov_gate"; return; }
    echo "$1[coverage][gate][result]"
}

if [ "$CMD" = run ]; then
    [ -s "$OUT/libraries.txt" ] || ./buck2 uquery 'kind(mojo_library_rule, //src/...)' > "$OUT/libraries.txt"
    ./buck2 uquery -c komira.coverage=true 'filter("_cov_gate$", //src/...)' > "$OUT/cov_gates.txt"
    : > "$OUT/targets.txt"
    while IFS= read -r l; do
        "$BB" cut -f1 "$SKIP" | "$BB" grep -qxF -- "$l" || target_of "$l" >> "$OUT/targets.txt"
    done < "$OUT/libraries.txt"
    build() { # targets file, report name -> 0 when an invocation finished
        n=0
        while [ "$n" -lt "$ATTEMPTS" ]; do
            rc=0
            # shellcheck disable=SC2046 # one target per word
            timeout "$CAP" ./buck2 build -c komira.coverage=true --keep-going --build-report "$OUT/$2.$n.json" \
                $(cat "$1") > "$OUT/$2.$n.out" 2> "$OUT/$2.$n.console" || rc=$?
            "$BB" grep -E 'Commands: |BUILD (SUCCEEDED|FAILED)' "$OUT/$2.$n.console" | tail -2 || true
            echo "census.sh: $2 attempt $n exit $rc" >&2
            [ "$rc" = 124 ] || { echo "$2.$n" > "$OUT/$2.last"; return 0; }
            n=$((n + 1))
        done
        echo "census.sh: $2: no attempt finished in $ATTEMPTS" >&2
        return 1
    }
    if [ "$BATCH" -gt 0 ]; then
        "$BB" rm -rf "$OUT/groups"
        "$BB" mkdir "$OUT/groups"
        "$BB" split -l "$BATCH" "$OUT/targets.txt" "$OUT/groups/group."
        for g in "$OUT"/groups/group.*; do
            build "$g" "${g##*/}" || exit 1
        done
    fi
    build "$OUT/targets.txt" report || exit 1
    "$BB" cp "$OUT/report.last" "$OUT/last"
    exit 0
fi

# collect
[ -s "$OUT/last" ] || { echo "census.sh: no finished run in $OUT" >&2; exit 1; }
REPORT=$OUT/$(cat "$OUT/last").json
./buck2 uquery '//src/...' > "$OUT/all_targets.txt"
[ -n "$SRC" ] || SRC=$(git rev-parse HEAD 2>/dev/null || echo -)
"$BB" awk -v cell=komira -v skipf="$SKIP" '
    # policy.bzl: COVERAGE_BRANCH_GATE; release/artifacts.textproto: the
    # conda packages released; all_targets.txt: every target under src/;
    # libraries.txt; then the build report (pretty-printed JSON).
    FILENAME ~ /policy\.bzl$/ { if (/^COVERAGE_BRANCH_GATE = \{/) on = 1; else if (on && /^\}/) on = 0; else if (on && match($0, /"komira\/\/[^"]+"/)) gate[substr($0, RSTART + 1, RLENGTH - 2)] = 1; next }
    FILENAME ~ /artifacts\.textproto$/ { if (match($0, /^ *targets: "\/\/[^"]+_conda"/)) { t = $0; sub(/^ *targets: "/, "", t); sub(/"$/, "", t); rel[cell t] = 1 }; next }
    FILENAME ~ /all_targets\.txt$/ { has[$0] = 1; next }
    FILENAME ~ /libraries\.txt$/ { libs[++nl] = $0; next }
    FILENAME == skipf { split($0, sk, "\t"); skip[sk[1]] = sk[2]; next }
    # The report: the section (two-space keys), the target (four-space keys
    # of "results"), its outputs, and each action error with its stderr id.
    /^  "[a-z_]+": / { sec = $0; sub(/^  "/, "", sec); sub(/".*/, "", sec); next }
    sec == "results" && /^    "[^"]+": \{$/ { tg = $0; sub(/^    "/, "", tg); sub(/": \{$/, "", tg); next }
    sec == "results" && /^      "success": / { ok[tg] = ($0 ~ /SUCCESS/); next }
    sec == "results" && /"buck-out\/[^"]*"/ { match($0, /"buck-out\/[^"]*"/); p = substr($0, RSTART + 1, RLENGTH - 2); if (!(tg in out) || p ~ /\/result\.json$/) out[tg] = p; next }
    sec == "results" && /"category": / { c = $0; sub(/.*"category": "/, "", c); sub(/".*/, "", c); next }
    sec == "results" && /"identifier": / { id = $0; sub(/.*"identifier": "/, "", id); sub(/".*/, "", id); if (index("; " errs[tg] "; ", "; " c " " id "; ") == 0) errs[tg] = errs[tg] (errs[tg] == "" ? "" : "; ") c " " id; if (c == "mojo_cov_gate") gfail[tg] = 1; next }
    sec == "results" && /"stderr_content": / { s = $0; sub(/.*"stderr_content": "/, "", s); sub(/".*/, "", s); if (!(tg in serr)) serr[tg] = s; next }
    sec == "strings" && /^    "[0-9]+": "/ { k = $0; sub(/^    "/, "", k); sub(/".*/, "", k); s = $0; sub(/^    "[0-9]+": "/, "", s); sub(/",?$/, "", s); str[k] = s; next }
    function firstline(s,   n, a, i, l) {
        n = split(s, a, /\\n/)
        for (i = 1; i <= n; i++) {
            l = a[i]
            if (l ~ /Unhandled exception caught during execution: |kcov: error: |^- \*\*Regression\*\*|timed out|[Tt]imeout|error: /) {
                sub(/.*Unhandled exception caught during execution: /, "", l); gsub(/\\"/, "\"", l); gsub(/\\t/, " ", l); gsub(/\|/, "/", l); gsub(/\\\\/, "\\", l)
                # A path in buck-out names the build, not the source: keep its repository part.
                gsub(/buck-out\/[^ ]*\/[0-9a-f][0-9a-f]*\//, "", l)
                return length(l) > 200 ? substr(l, 1, 197) "..." : l
            }
        }
        return ""
    }
    END {
        for (i = 1; i <= nl; i++) {
            l = libs[i]; t = l; if (!((t) in ok)) t = l "_cov_gate"
            pkg = l; sub(/^komira\/\//, "", pkg); sub(/:.*/, "", pkg)
            name = l; sub(/.*:/, "", name)
            kind = pkg ~ /^src\/tests\// ? "test" : "library"
            pub = (cell "//" pkg ":" name "_conda") in rel ? "release" : ((cell "//" pkg ":" name "_conda") in has ? "conda" : "no")
            bg = (l in gate) ? "yes" : "no"
            if (l in skip) { print l "\t" pkg "\t" kind "\tRUN_FAILED\t-\t" bg "\t" pub "\tnot built in this census: " skip[l]; continue }
            if (!(t in ok)) { print "census.sh: the report has no result for " l > "/dev/stderr"; bad = 1; continue }
            if (ok[t]) {
                f = out[t]; if (f !~ /\/result\.json$/) sub(/[^\/]*$/, "result.json", f)
                print l "\t" pkg "\t" kind "\tOK\t" f "\t" bg "\t" pub
            } else {
                why = errs[t] == "" ? "a dependency failed" : errs[t]
                fl = (t in serr) ? firstline(str[serr[t]]) : ""
                gsub(/\t/, " ", why)
                print l "\t" pkg "\t" kind "\t" (t in gfail ? "GATE_FAILED" : "RUN_FAILED") "\t-\t" bg "\t" pub "\t" why (fl == "" ? "" : ": " fl)
            }
        }
        exit bad
    }
' tools/build/coverage/policy.bzl release/artifacts.textproto "$OUT/all_targets.txt" "$OUT/libraries.txt" "$SKIP" "$REPORT" > "$OUT/collected.tsv"
{
    echo "# The coverage census of every library, for census_files split to write into each package (census.md)."
    printf 'census\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%d)" "$SRC" "$NOTE"
    while IFS="$(printf '\t')" read -r l pkg kind st f bg pub note; do
        if [ "$st" = OK ]; then
            "$BB" awk -v l="$l" -v pkg="$pkg" -v kind="$kind" -v bg="$bg" -v pub="$pub" '
                function n(k,   v) { if (!match(P, "\"" k "\":[0-9]+")) return "-"; v = substr(P, RSTART, RLENGTH); sub(/.*:/, "", v); return v }
                {
                    if (!match($0, /"package":\{[^}]*\}/)) { print "census.sh: no package in " FILENAME > "/dev/stderr"; exit 1 }
                    P = substr($0, RSTART, RLENGTH)
                    u = ""; s = $0
                    while (match(s, /\{"kind":"UnmeasuredFile",[^}]*\}/)) {
                        f = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
                        if (match(f, /"path":"[^"]*"/)) u = u (u == "" ? "" : ",") substr(f, RSTART + 8, RLENGTH - 9)
                    }
                    bh = n("branch_hit"); bf = n("branch_found")
                    if (bf == "0" && bg == "no") { bh = "-"; bf = "-" }
                    print l "\t" pkg "\t" kind "\tOK\t" n("line_hit") "\t" n("line_found") "\t" bh "\t" bf "\t" bg "\t" pub "\t" (u == "" ? "-" : u) "\t-"
                }' "$f"
        else
            printf '%s\t%s\t%s\t%s\t-\t-\t-\t-\t%s\t%s\t-\t%s\n' "$l" "$pkg" "$kind" "$st" "$bg" "$pub" "$note"
        fi
    done < "$OUT/collected.tsv" | LC_ALL=C "$BB" sort -t "$(printf '\t')" -k1,1
} > "$OUT/census.tsv"
# After the rows, one `generated<TAB><path>` line per generated source the
# gates left out (a gate result's "generated_paths"), sorted, each once:
# census_files generated reads the JSON (census_files.zig).
set --
while IFS="$(printf '\t')" read -r _ _ _ st f _; do
    if [ "$st" = OK ]; then set -- "$@" "$PWD/$f"; fi
done < "$OUT/collected.tsv"
case $OUT in /*) ABS_OUT=$OUT ;; *) ABS_OUT=$PWD/$OUT ;; esac
./buck2 run //tools/build/coverage:census_files -- generated "$ABS_OUT/generated.tsv" "$@"
cat "$OUT/generated.tsv" >> "$OUT/census.tsv"
echo "census.sh: wrote $OUT/census.tsv ($("$BB" grep -c -v '^#' "$OUT/census.tsv") lines)" >&2
