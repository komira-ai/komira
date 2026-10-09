#!/bin/sh
# coverage_measure.sh -- the measuring half of .github/workflows/coverage.yml
# (docs/ci.md, "coverage.yml"; tools/build/coverage/README.md, "The coverage
# workflow"): the line coverage of the mojo_library targets a pull request
# touches, and the branch coverage of those whose gate reads branch records,
# as covcheck's report and the request bodies of the check run that the
# workflow's `post` job sends. It never fails on what it measures.
#
# usage: coverage_measure.sh --base <sha> --head <sha> --covcheck <path> --out <dir>
#            [--buck2 <path>] [--git <path>] [--policy <file>] [--ratchet <file>]
#            [--buckconfig <file>] [--name <check run name>] [--max-annotations <n>]
#
# Run from the repository root with <head> checked out (the pull request's
# head commit, so the annotations land on the lines of its "Files changed"
# view). <base> is the pull request's base commit. Defaults: --buck2 ./buck2,
# --git git, --policy tools/build/coverage/policy.bzl, --ratchet
# tools/build/coverage/ratchet.tsv, --buckconfig .buckconfig, --name coverage,
# --max-annotations 1000.
#
#  1. The change: <merge base> = `git merge-base <base> <head>`; the diff
#     covcheck reads (`git diff --unified=0 -M` with explicit a/ b/ prefixes,
#     <merge base> to <head>), and the paths it names, old and new
#     (`--name-only --no-renames`).
#  2. The packages: each path's nearest directory holding a BUCK file. A path
#     under another cell's directory (the `[cells]` of <buckconfig>: the
#     tests cell, the toolchains cell) is left out: the tests cell's
#     libraries are fixtures, some failing by design.
#  3. The libraries, and which of them read branch records: `buck2 uquery
#     -c komira.coverage=true "kind('^mojo_library_rule$', set(//<package>: ...))"
#     --output-attribute '^coverage_branch_gate$'`. The attribute is the one
#     mojo_library sets from COVERAGE_BRANCH_GATE (tools/build/coverage/
#     policy.bzl) and the gate reads (tools/build/mojo/coverage.bzl), so this
#     list is the gate's own, not a second reading of the policy's dict.
#     Then which of them name mojo_test targets in `coverage_tests`
#     (`buck2 uquery -c komira.coverage=true "attrregexfilter(coverage_tests,
#     '.', <the same query>)"`): their runs are `<library>_cov_gate[tests]`.
#  4. One `buck2 build -c komira.coverage=true --keep-going --build-report
#     <file> '<library>[coverage][tests]'...` of every library, with
#     `'<library>[coverage][branch_info]'` after it for a library whose
#     coverage_branch_gate is true, and `'<library>_cov_gate[tests]'` for
#     one naming coverage_tests, whose entry must be SUCCESS too (else the
#     library is NOT MEASURED) and whose `cov/tests/*.xml` paths are its
#     reports as well (the farm builds them in parallel; the
#     gate already waits for those records, so they add no action): each
#     test's kcov report, the library's gate (tools/build/mojo/README.md,
#     "Coverage builds") and each test's branch records. Each library's
#     verdict is its entry of the build report (as buck2 pretty-prints it;
#     its two sub-targets share it): SUCCESS is measured; FAIL with only
#     errors of its OWN gate's action (`mojo_cov_gate` owned by the
#     library: an enforce finding, or a gate error) or of its OWN branch
#     coverage actions (the categories of BRANCH_CATEGORIES below, owned by
#     the library) is measured too, since every run built; any other FAIL,
#     or no entry, leaves it NOT MEASURED (coverage build failed): none of
#     its reports is used and the summary lists it. The reports are its
#     entry's `cov/tests/*.xml` paths. A dependency's failed run or gate
#     does not reach the library's runs (only a conda package waits for
#     coverage), so an error of another library's gate in the entry is not
#     expected; it would still leave the library not measured. A library
#     whose records are read and whose entry is SUCCESS gives its entry's
#     `cov/branch/*.info` paths, one per report of a test (its README's
#     report, `cov/tests/readme.xml`, has none: the README's run is line
#     coverage only, tools/build/mojo/coverage.bzl); a measured one whose branch
#     coverage actions or gate failed gives none and is listed as branch NOT
#     MEASURED: its records did not all build, or its gate, which reads the
#     same records with covcheck, failed (so `report` could refuse them too).
#  5. `covcheck report` over the reports of the libraries measured, and
#     their branch records (`--branch-lcov`), in the
#     mode and against the target of <policy>, each directory of its
#     COVERAGE_INFO_ONLY_DIRS (test-only packages, relative to the root
#     cell's root, which is the repository's) an `--info-package`, so what
#     covcheck finds in a package under one is information: no finding, no
#     failure conclusion, its annotations notices; with the ratchet's rows of
#     the measured libraries' packages only (every other row would read as
#     a Regression: nothing of it was measured here). When there is no
#     report (no library touched, none built, none has a test, or the
#     libraries could not be listed) this script writes the summary and a
#     neutral check run itself, in covcheck's shape (000.json the POST,
#     001.json the PATCH).
#
# Outputs, under <out>/publish (what the workflow uploads): checkrun/ (the
# request bodies, sorted file order is send order), summary.md, result.json,
# annotations.json, libraries.txt (the libraries of step 3),
# branch_libraries.txt (those of them whose gate reads branch records),
# coverage_tests_libraries.txt (those naming coverage_tests),
# not_measured.txt (those whose coverage build failed) and
# branch_not_measured.txt (those measured whose branch records are not read). <out> also holds the
# inputs, the build log and the build report; it must be empty or absent.
#
# Exit: 0 when publish/ is written, whatever was measured or failed to build;
# 1 when an input or a tool is wrong (a malformed policy, git failing,
# covcheck refusing its inputs, a build report naming a file that is not on
# disk, or a library whose records are read with a SUCCESS entry naming not
# one record per report of a test, buck2's query answer not a library and its
# attribute per entry, or naming something that is not a label); 2 bad usage.
set -eu
LC_ALL=C
export LC_ALL

say() { echo "coverage_measure: $*"; }
die() { echo "coverage_measure: $*" >&2; exit 1; }
usage() {
    echo "coverage_measure: $*" >&2
    echo "usage: coverage_measure.sh --base <sha> --head <sha> --covcheck <path> --out <dir> [--buck2 <path>] [--git <path>] [--policy <file>] [--ratchet <file>] [--buckconfig <file>] [--name <name>] [--max-annotations <n>]" >&2
    exit 2
}

BASE="" HEAD="" COVCHECK="" OUT=""
BUCK2=./buck2 GIT=git
POLICY=tools/build/coverage/policy.bzl RATCHET=tools/build/coverage/ratchet.tsv
BUCKCONFIG=.buckconfig NAME=coverage MAXANN=1000
while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || usage "$1 has no value"
    case "$1" in
        --base) BASE=$2 ;;
        --head) HEAD=$2 ;;
        --covcheck) COVCHECK=$2 ;;
        --out) OUT=$2 ;;
        --buck2) BUCK2=$2 ;;
        --git) GIT=$2 ;;
        --policy) POLICY=$2 ;;
        --ratchet) RATCHET=$2 ;;
        --buckconfig) BUCKCONFIG=$2 ;;
        --name) NAME=$2 ;;
        --max-annotations) MAXANN=$2 ;;
        *) usage "unknown argument $1" ;;
    esac
    shift 2
done

is_sha() {
    case "$1" in *[!0-9a-f]* | "") return 1 ;; esac
    [ "${#1}" -eq 40 ]
}
is_sha "$BASE" || usage "--base '$BASE' is not 40 lowercase hex digits"
is_sha "$HEAD" || usage "--head '$HEAD' is not 40 lowercase hex digits"
[ -n "$COVCHECK" ] || usage "--covcheck is required"
[ -n "$OUT" ] || usage "--out is required"
case "$MAXANN" in "" | *[!0-9]* | 0) usage "--max-annotations '$MAXANN' is not a number of 1 or more" ;; esac
case "$NAME" in "" | *[!A-Za-z0-9_.-]*) usage "--name '$NAME' is not a plain name" ;; esac

mkdir -p "$OUT"
[ -z "$(ls -A "$OUT")" ] || die "$OUT is not empty"
PUB="$OUT/publish"
mkdir -p "$PUB" "$OUT/logs"

# The policy: one COVERAGE_MODE line, one COVERAGE_TARGET_BP line and one
# COVERAGE_INFO_ONLY_DIRS line (a list of quoted directories).
MODE=$(sed -n 's/^COVERAGE_MODE = "\([a-z]*\)"$/\1/p' "$POLICY") || die "cannot read $POLICY"
case "$MODE" in census | neutral | enforce) ;; *) die "$POLICY has no single COVERAGE_MODE line naming census, neutral or enforce" ;; esac
TARGET=$(sed -n 's/^COVERAGE_TARGET_BP = \([0-9][0-9]*\)$/\1/p' "$POLICY")
case "$TARGET" in "" | *[!0-9]*) die "$POLICY has no single COVERAGE_TARGET_BP line" ;; esac
INFO_DIRS=$(sed -n 's/^COVERAGE_INFO_ONLY_DIRS = \[\(.*\)\]$/\1/p' "$POLICY")
NO_INFO="$POLICY has no single COVERAGE_INFO_ONLY_DIRS line listing double-quoted directories"
[ "$(grep -c '^COVERAGE_INFO_ONLY_DIRS = ' "$POLICY")" -eq 1 ] && grep -q '^COVERAGE_INFO_ONLY_DIRS = \[.*\]$' "$POLICY" ||
    die "$NO_INFO"
INFO_DIRS=$(printf '%s\n' "$INFO_DIRS" | tr ',' '\n' | sed 's/^ *//; s/ *$//')
for d in $INFO_DIRS; do
    case "$d" in '"'*'"') ;; *) die "$NO_INFO (item $d)" ;; esac
    d=${d#\"}
    d=${d%\"}
    case "/$d/" in
        // | *//* | */./* | */../* | *[!A-Za-z0-9_./+-]*) die "$POLICY: COVERAGE_INFO_ONLY_DIRS item '$d' is not a repository directory" ;;
    esac
done
INFO_DIRS=$(printf '%s\n' "$INFO_DIRS" | tr -d '"')

# 1. The change.
MB=$("$GIT" merge-base "$BASE" "$HEAD") || die "git merge-base $BASE $HEAD failed"
is_sha "$MB" || die "git merge-base answered '$MB', not a commit id"
"$GIT" diff --no-color --no-ext-diff --unified=0 -M --src-prefix=a/ --dst-prefix=b/ "$MB" "$HEAD" >"$OUT/diff.txt" ||
    die "git diff $MB $HEAD failed"
"$GIT" diff --no-color --no-ext-diff --name-only --no-renames -z "$MB" "$HEAD" >"$OUT/changed.z" ||
    die "git diff --name-only $MB $HEAD failed"
"$GIT" ls-files -z >"$OUT/repo-files" || die "git ls-files failed"
tr '\0' '\n' <"$OUT/changed.z" >"$OUT/changed.txt"
say "head $HEAD, merge base $MB: $(grep -c . "$OUT/changed.txt" || true) path(s) changed; policy $MODE, target $TARGET bp, test-only $(echo $INFO_DIRS)"

# 2. The packages. The directories of the other cells come from [cells].
awk '
    /^[ \t]*\[/ { s = ($0 ~ /^[ \t]*\[cells\][ \t]*$/); next }
    s && !/^[ \t]*[#;]/ && /=/ {
        v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]*$/, "", v)
        if (v != "." && v != "") print v
    }' "$BUCKCONFIG" >"$OUT/cell_dirs.txt"
: >"$OUT/packages.raw"
: >"$OUT/other_cells.txt"
while IFS= read -r p; do
    [ -n "$p" ] || continue
    other=""
    while IFS= read -r c; do
        case "$p" in "$c"/*) other=$c && break ;; esac
    done <"$OUT/cell_dirs.txt"
    if [ -n "$other" ]; then
        echo "$p" >>"$OUT/other_cells.txt"
        continue
    fi
    d=$(dirname "$p")
    while [ ! -f "$d/BUCK" ] && [ "$d" != . ]; do d=$(dirname "$d"); done
    if [ -f "$d/BUCK" ]; then echo "$d" >>"$OUT/packages.raw"; fi
done <"$OUT/changed.txt"
sort -u "$OUT/packages.raw" >"$OUT/packages.txt"
if [ -s "$OUT/other_cells.txt" ]; then
    say "left out, in another cell: $(tr '\n' ' ' <"$OUT/other_cells.txt")"
fi

# 3. The libraries, and whether each one's gate reads branch records.
SELECT_FAILED=""
: >"$PUB/libraries.txt"
: >"$PUB/branch_libraries.txt"
if [ -s "$OUT/packages.txt" ]; then
    pats=""
    while IFS= read -r d; do
        case "$d" in *[!A-Za-z0-9_./+-]*) die "package directory '$d' holds a character a target pattern cannot" ;; esac
        if [ "$d" = . ]; then pats="$pats //:"; else pats="$pats //$d:"; fi
    done <"$OUT/packages.txt"
    query="kind('^mojo_library_rule\$', set($pats ))"
    say "buck2 uquery \"$query\" --output-attribute '^coverage_branch_gate\$'"
    rc=0
    "$BUCK2" uquery -c komira.coverage=true "$query" --output-attribute '^coverage_branch_gate$' \
        >"$OUT/libraries.raw" 2>"$OUT/logs/uquery.log" </dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then
        SELECT_FAILED="buck2 uquery exited $rc"
        say "$SELECT_FAILED; its last lines:"
        tail -n 20 "$OUT/logs/uquery.log"
    else
        # buck2's JSON, pretty-printed: per library a line `  "<label>": {`
        # and then `    "coverage_branch_gate": true|false`. "lib <value>
        # <label>" per library; "bad <line>" for any other line, and for a
        # library with no value.
        awk '
            /^\{\}?$/ || /^\}$/ || /^  \},?$/ { next }
            lab == "" && /^  ".*": \{$/ { lab = $0; sub(/^  "/, "", lab); sub(/": \{$/, "", lab); next }
            lab != "" && /^    "coverage_branch_gate": (true|false)$/ {
                v = $0; sub(/^.*: /, "", v); print "lib " v " " lab; lab = ""; next
            }
            { if (lab != "") print "bad " lab; print "bad " $0; lab = "" }
            END { if (lab != "") print "bad " lab }
        ' "$OUT/libraries.raw" >"$OUT/libraries.tsv"
        while IFS= read -r a; do
            case "$a" in
                "lib true "* | "lib false "*) ;;
                *) die "buck2 uquery printed '${a#bad }', which is not a library with its coverage_branch_gate" ;;
            esac
            l=${a#lib * }
            echo "$l" | grep -qE '^[A-Za-z0-9_]*//[A-Za-z0-9_./+-]*:[A-Za-z0-9_.+-]+$' ||
                die "buck2 uquery printed '$l', which is not a target label"
            echo "$l" >>"$PUB/libraries.txt"
            case "$a" in "lib true "*) echo "$l" >>"$PUB/branch_libraries.txt" ;; esac
        done <"$OUT/libraries.tsv"
    fi
fi
# Which of them name mojo_test targets in `coverage_tests`: their runs are
# `<library>_cov_gate[tests]` (tools/build/mojo/coverage.bzl).
: >"$PUB/coverage_tests_libraries.txt"
if [ -s "$PUB/libraries.txt" ]; then
    rc=0
    "$BUCK2" uquery -c komira.coverage=true "attrregexfilter(coverage_tests, '.', $query)" \
        >"$OUT/coverage_tests.raw" 2>"$OUT/logs/uquery_tests.log" </dev/null || rc=$?
    [ "$rc" -eq 0 ] || die "buck2 uquery of coverage_tests exited $rc (see $OUT/logs/uquery_tests.log)"
    while IFS= read -r l; do
        [ -n "$l" ] || continue
        grep -qxF -- "$l" "$PUB/libraries.txt" ||
            die "buck2 uquery of coverage_tests printed '$l', which is not one of the libraries"
        echo "$l" >>"$PUB/coverage_tests_libraries.txt"
    done <"$OUT/coverage_tests.raw"
fi

# 4. One coverage build of every library, with the branch records of those
# whose gate reads them. BRANCH_CATEGORIES: the categories of the branch
# coverage actions (tools/build/mojo/coverage_branch.bzl; a case of
# //:coverage_ci_cases holds this list equal to that file's).
BRANCH_CATEGORIES="mojo_emit_cov_bc mojo_cov_pgo_link mojo_cov_branch_run mojo_cov_branch_annotate mojo_cov_branch_classify"
: >"$OUT/reports.txt"
: >"$OUT/branch_records.txt"
: >"$OUT/measured.txt"
: >"$PUB/not_measured.txt"
: >"$PUB/branch_not_measured.txt"
: >"$OUT/branch_not_measured.why"
reads_branch() { grep -qxF -- "$1" "$PUB/branch_libraries.txt"; }
names_tests() { grep -qxF -- "$1" "$PUB/coverage_tests_libraries.txt"; }
if [ -s "$PUB/libraries.txt" ]; then
    br="$OUT/logs/build_report.json"
    set --
    while IFS= read -r lib; do
        set -- "$@" "${lib}[coverage][tests]"
        if reads_branch "$lib"; then set -- "$@" "${lib}[coverage][branch_info]"; fi
        if names_tests "$lib"; then set -- "$@" "${lib}_cov_gate[tests]"; fi
    done <"$PUB/libraries.txt"
    rc=0
    "$BUCK2" build -c komira.coverage=true --keep-going --build-report "$br" "$@" >"$OUT/logs/build.log" 2>&1 </dev/null || rc=$?
    say "buck2 build of $# coverage target(s) exited $rc"
    grep -E 'Commands:|BUILD (SUCCEEDED|FAILED)' "$OUT/logs/build.log" | sed 's/^/    /' || true
    if [ ! -f "$br" ]; then
        [ "$rc" -ne 0 ] || die "buck2 build exited 0 and wrote no build report"
        say "buck2 wrote no build report: no library is measured"
        : >"$OUT/verdicts.txt"
    else
        # "<label> ok|gate|branch|failed" per entry of `results`,
        # "<label> report <path>" per report path in it and "<label> info
        # <path>" per branch record path. An error object is a line holding
        # `{` alone (no other array of the entry holds objects); one counts
        # as the library's own gate when its action's category is
        # mojo_cov_gate, and as its own branch coverage when the category is
        # one of BRANCH_CATEGORIES, and its owner is "<label> (<configuration>)".
        awk -v cats=" $BRANCH_CATEGORIES " '
            /^  "results": \{$/ { inres = 1; next }
            inres && /^  \}/ { inres = 0; next }
            !inres { next }
            /^    "[^"]*": \{$/ {
                lab = $0; sub(/^    "/, "", lab); sub(/": \{$/, "", lab)
                st = ""; ne = 0; ng = 0; nb = 0; cat = ""; next
            }
            /^    \}/ {
                if (lab != "") {
                    v = "failed"
                    if (st == "SUCCESS") v = "ok"
                    else if (st == "FAIL" && ne > 0 && ne == ng + nb) v = (nb > 0 ? "branch" : "gate")
                    print lab " " v
                }
                lab = ""; next
            }
            lab == "" { next }
            /^      "success": "/ { st = $0; sub(/^      "success": "/, "", st); sub(/",?$/, "", st); next }
            /^ *\{$/ { ne++; cat = ""; next }
            /^ *"category": "/ { cat = $0; sub(/^ *"category": "/, "", cat); sub(/",?$/, "", cat); next }
            /^ *"owner": "/ {
                o = $0; sub(/^ *"owner": "/, "", o)
                if (index(o, lab " (") == 1) {
                    if (cat == "mojo_cov_gate") ng++
                    else if (cat != "" && index(cats, " " cat " ") > 0) nb++
                }
                next
            }
            /^ *"buck-out\/[^"]*\/cov\/tests\/[^"\/]*\.xml",?$/ {
                x = $0; sub(/^ *"/, "", x); sub(/",?$/, "", x); print lab " report " x
            }
            /^ *"buck-out\/[^"]*\/cov\/branch\/[^"\/]*\.info",?$/ {
                x = $0; sub(/^ *"/, "", x); sub(/",?$/, "", x); print lab " info " x
            }
        ' "$br" >"$OUT/verdicts.txt"
    fi
    # paths <lib> report|info: the entry's paths of that kind, each checked.
    paths() {
        awk -v l="$1" -v k="$2" '$1 == l && $2 == k { print $3 }' "$OUT/verdicts.txt" | sort -u >"$OUT/logs/paths.one"
        while IFS= read -r x; do
            case "$x" in *=*) die "$1: $2 path $x holds '=', which covcheck reads as PKGDIR=" ;; esac
            [ -f "$x" ] || die "$1: the build report names $x, which is not on disk"
        done <"$OUT/logs/paths.one"
        cat "$OUT/logs/paths.one"
    }
    while IFS= read -r lib; do
        v=$(awk -v l="$lib" '$1 == l && $2 != "report" && $2 != "info" { print $2; exit }' "$OUT/verdicts.txt")
        case "$v" in
            ok | gate | branch) ;;
            *)
                echo "$lib" >>"$PUB/not_measured.txt"
                if [ -n "$v" ]; then why="its build failed"; else why="it is not in the build report"; fi
                say "$lib: NOT MEASURED (coverage build failed): $why"
                continue
                ;;
        esac
        if names_tests "$lib"; then
            # The runs of its coverage_tests: their target must have built.
            vt=$(awk -v l="${lib}_cov_gate" '$1 == l && $2 != "report" && $2 != "info" { print $2; exit }' "$OUT/verdicts.txt")
            if [ "$vt" != ok ]; then
                echo "$lib" >>"$PUB/not_measured.txt"
                say "$lib: NOT MEASURED (coverage build failed): the runs of its coverage_tests (${lib}_cov_gate) did not build"
                continue
            fi
        fi
        [ "$v" != gate ] || say "$lib: its own coverage gate failed (an enforce finding or a gate error; the log below says which); its runs built, so it is measured"
        [ "$v" != branch ] || say "$lib: its own branch coverage actions failed (the log below says which); its runs built, so it is measured"
        paths "$lib" report >"$OUT/logs/reports.one"
        cat "$OUT/logs/reports.one" >>"$OUT/reports.txt"
        if names_tests "$lib"; then paths "${lib}_cov_gate" report >>"$OUT/reports.txt"; fi
        echo "$lib" >>"$OUT/measured.txt"
        nr=$(grep -c . "$OUT/logs/reports.one" || true)
        say "$lib: $nr report(s)"
        reads_branch "$lib" || continue
        if [ "$v" != ok ]; then
            echo "$lib" >>"$PUB/branch_not_measured.txt"
            if [ "$v" = branch ]; then why="its branch records failed to build"; else why="its coverage gate, which reads the same records, failed"; fi
            echo "$lib $why" >>"$OUT/branch_not_measured.why"
            say "$lib: branch NOT MEASURED: $why"
            continue
        fi
        paths "$lib" info >"$OUT/logs/infos.one"
        ni=$(grep -c . "$OUT/logs/infos.one" || true)
        # The README's run (cov/tests/readme.xml) has no branch records.
        nt=$(grep -c -v '/cov/tests/readme\.xml$' "$OUT/logs/reports.one" || true)
        [ "$ni" -eq "$nt" ] || die "$lib: its gate reads branch records, and its build report entry names $ni branch record file(s) for $nt report(s) of its tests"
        cat "$OUT/logs/infos.one" >>"$OUT/branch_records.txt"
        say "$lib: $ni branch record file(s)"
    done <"$PUB/libraries.txt"
    if [ "$rc" -ne 0 ]; then
        say "the end of the build's output:"
        tail -n 60 "$OUT/logs/build.log"
    fi
fi

# The ratchet covcheck reads: its comment lines and the rows of the measured
# libraries' packages (a label's path: komira//src/x:x is src/x).
sed 's|^[A-Za-z0-9_]*//\([^:]*\):.*$|\1|' "$OUT/measured.txt" | sort -u >"$OUT/measured_packages.txt"
awk -F '\t' -v keepf="$OUT/measured_packages.txt" '
    BEGIN { while ((getline l < keepf) > 0) keep[l] = 1 }
    /^#/ || ($1 in keep)
' "$RATCHET" >"$OUT/ratchet.tsv" || die "cannot read $RATCHET"

# The text of a JSON string from stdin: lines joined with \n. The texts
# written here hold no quote or backslash (checked by json_safe).
json_lines() { awk 'BEGIN { ORS = "" } { if (NR > 1) print "\\n"; print }'; }
json_safe() {
    case "$1" in *'"'* | *'\'*) die "internal: a text for JSON holds a quote or backslash" ;; esac
}

# The section the summary gains for the libraries whose build failed.
not_measured_section() {
    printf '\n### Not measured (coverage build failed)\n\n'
    printf 'These libraries the change touches did not build with `-c komira.coverage=true` (a test that fails at -O0 or under kcov, or a dependency whose release tests fail), so their packages have no numbers here. The job log of `coverage / measure` has the end of each build.\n\n'
    while IFS= read -r l; do printf '%s\n' "- \`$l\`: not measured (coverage build failed)"; done <"$PUB/not_measured.txt"
}
# ... and the one for the libraries whose gate reads branch records and whose
# records this run does not read.
branch_section() {
    printf '\n### Not measured: branch\n\n'
    printf 'The coverage gates of these libraries read their tests'"'"' branch records (`COVERAGE_BRANCH_GATE`, tools/build/coverage/policy.bzl), and this run reads none of them, so their packages show branch coverage not measured here. Their line coverage is measured. The job log of `coverage / measure` has the end of each build.\n\n'
    while IFS=" " read -r l why; do printf '%s\n' "- \`$l\`: branch not measured ($why)"; done <"$OUT/branch_not_measured.why"
}
# Every section the summary gains.
sections() {
    if [ "$N_FAILED" -gt 0 ]; then not_measured_section; fi
    if [ "$N_NOBRANCH" -gt 0 ]; then branch_section; fi
}

N_LIBS=$(grep -c . "$PUB/libraries.txt" || true)
N_FAILED=$(grep -c . "$PUB/not_measured.txt" || true)
N_REPORTS=$(grep -c . "$OUT/reports.txt" || true)
N_NOBRANCH=$(grep -c . "$PUB/branch_not_measured.txt" || true)
N_RECORDS=$(grep -c . "$OUT/branch_records.txt" || true)

# 5. The report.
if [ "$N_REPORTS" -gt 0 ]; then
    set -- report --repo-files "$OUT/repo-files" --diff "$OUT/diff.txt" --head-sha "$HEAD" \
        --source-root . --ratchet "$OUT/ratchet.tsv" --mode "$MODE" --target-bp "$TARGET" --name "$NAME" \
        --max-annotations "$MAXANN" --summary-out "$PUB/summary.md" --checkrun-dir "$PUB/checkrun" \
        --result-out "$PUB/result.json" --annotations-out "$PUB/annotations.json"
    while IFS= read -r x; do set -- "$@" --cobertura "$x"; done <"$OUT/reports.txt"
    while IFS= read -r x; do set -- "$@" --branch-lcov "$x"; done <"$OUT/branch_records.txt"
    for d in $INFO_DIRS; do set -- "$@" --info-package "$d"; done
    rc=0
    "$COVCHECK" "$@" >"$OUT/logs/covcheck.log" 2>&1 || rc=$?
    cat "$OUT/logs/covcheck.log"
    [ "$rc" -eq 0 ] || die "covcheck report exited $rc"
    if [ "$N_FAILED" -gt 0 ] || [ "$N_NOBRANCH" -gt 0 ]; then
        section=$(sections)
        json_safe "$section"
        size=$(wc -c <"$PUB/summary.md")
        add=$(printf '%s\n' "$section" | wc -c)
        printf '%s\n' "$section" >>"$PUB/summary.md"
        if [ $((size + add)) -le 65535 ]; then
            # Into every body's summary, at its end: the first `","annotations":[`
            # of a body closes its summary (the strings before it cannot hold
            # an unescaped quote).
            ADD=$(printf '%s\n' "$section" | json_lines)
            export ADD
            for f in "$PUB"/checkrun/*.json; do
                awk '{
                    i = index($0, "\",\"annotations\":[")
                    if (NR > 1 || i == 0) exit 3
                    print substr($0, 1, i - 1) "\\n" ENVIRON["ADD"] substr($0, i)
                }' "$f" >"$f.new" || die "internal: $f is not one covcheck body line"
                mv "$f.new" "$f"
            done
        else
            say "the summary is at GitHub's limit: the not-measured lists are in summary.md and this log only"
        fi
    fi
else
    if [ -n "$SELECT_FAILED" ]; then
        title="coverage: not measured (the libraries could not be listed)"
        why="The libraries the change touches could not be listed ($SELECT_FAILED), so nothing was measured. The job log of \`coverage / measure\` has the end of the query's output."
    elif [ "$N_LIBS" -eq 0 ]; then
        title="coverage: no Mojo library touched"
        why="The change touches no mojo_library (outside the tests and toolchains cells), so there is nothing to measure."
    elif [ "$N_FAILED" -eq "$N_LIBS" ]; then
        title="coverage: not measured (coverage build failed)"
        why="No library the change touches built in coverage mode, so nothing was measured."
    else
        title="coverage: no report"
        why="The libraries the change touches that built in coverage mode have no test, so no report: nothing was measured."
    fi
    {
        printf '## %s\n\n%s\n\nMode: %s. This check is informational: it is not a required check.\n' "$title" "$why" "$MODE"
        if [ "$N_LIBS" -gt 0 ]; then
            printf '\nLibraries the change touches:\n\n'
            while IFS= read -r l; do printf '%s\n' "- \`$l\`"; done <"$PUB/libraries.txt"
        fi
        sections
    } >"$PUB/summary.md"
    text=$(cat "$PUB/summary.md")
    json_safe "$text$title"
    S=$(printf '%s\n' "$text" | json_lines)
    out="\"output\":{\"title\":\"$title\",\"summary\":\"$S\",\"annotations\":[]}"
    mkdir -p "$PUB/checkrun"
    printf '{"name":"%s","head_sha":"%s","status":"in_progress",%s}\n' "$NAME" "$HEAD" "$out" >"$PUB/checkrun/000.json"
    printf '{"status":"completed","conclusion":"neutral",%s}\n' "$out" >"$PUB/checkrun/001.json"
    printf '[]\n' >"$PUB/annotations.json"
    {
        printf '{"conclusion":"neutral","mode":"%s","measured":false,"libraries":%s,"not_measured":%s}\n' "$MODE" \
            "$(awk 'BEGIN { ORS = ""; print "[" } { if (NR > 1) print ","; print "\"" $0 "\"" } END { print "]" }' "$PUB/libraries.txt")" \
            "$(awk 'BEGIN { ORS = ""; print "[" } { if (NR > 1) print ","; print "\"" $0 "\"" } END { print "]" }' "$PUB/not_measured.txt")"
    } >"$PUB/result.json"
fi

say "$N_LIBS librar(y/ies) touched, $((N_LIBS - N_FAILED)) measured, $N_FAILED not measured (coverage build failed), $N_REPORTS report(s), $N_RECORDS branch record file(s), $N_NOBRANCH branch not measured; check run bodies: $(ls "$PUB/checkrun" | tr '\n' ' ')"
