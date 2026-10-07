#!/bin/sh
# coverage_measure.sh -- the measuring half of .github/workflows/coverage.yml
# (docs/ci.md, "coverage.yml"; tools/build/coverage/README.md, "The coverage
# workflow"): the line coverage of the mojo_library targets a pull request
# touches, as covcheck's report and the request bodies of the check run that
# the workflow's `post` job sends. It never fails on what it measures.
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
#  3. The libraries: `buck2 uquery "kind('^mojo_library_rule$', set(//<package>: ...))"`.
#  4. One `buck2 build -c komira.coverage=true --keep-going --build-report
#     <file> '<library>[coverage][tests]'...` of every library (the farm
#     builds them in parallel): each test's kcov report and the library's
#     gate (tools/build/mojo/README.md, "Coverage builds"). Each library's
#     verdict is its entry of the build report (as buck2 pretty-prints it):
#     SUCCESS is measured; FAIL with only errors of its OWN gate's action
#     (`mojo_cov_gate` owned by the library: an enforce finding, or a gate
#     error) is measured too, since every run built; any other FAIL, or no
#     entry, leaves it NOT MEASURED (coverage build failed): none of its
#     reports is used and the summary lists it. The reports are its entry's
#     `cov/tests/*.xml` paths. A dependency's failed run or gate does not
#     reach the library's runs (only a conda package waits for coverage), so
#     an error of another library's gate in the entry is not expected; it
#     would still leave the library not measured.
#  5. `covcheck report` over the reports of the libraries measured, in the
#     mode and against the target of <policy>, with the ratchet's rows of
#     the measured libraries' packages only (every other row would read as
#     a Regression: nothing of it was measured here). When there is no
#     report (no library touched, none built, none has a test, or the
#     libraries could not be listed) this script writes the summary and a
#     neutral check run itself, in covcheck's shape (000.json the POST,
#     001.json the PATCH).
#
# Outputs, under <out>/publish (what the workflow uploads): checkrun/ (the
# request bodies, sorted file order is send order), summary.md, result.json,
# annotations.json, libraries.txt (the libraries of step 3) and
# not_measured.txt (those whose coverage build failed). <out> also holds the
# inputs, the build log and the build report; it must be empty or absent.
#
# Exit: 0 when publish/ is written, whatever was measured or failed to build;
# 1 when an input or a tool is wrong (a malformed policy, git failing,
# covcheck refusing its inputs, a build report naming a file that is not on
# disk, buck2 printing something that is not a label); 2 bad usage.
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

# The policy: one COVERAGE_MODE line and one COVERAGE_TARGET_BP line.
MODE=$(sed -n 's/^COVERAGE_MODE = "\([a-z]*\)"$/\1/p' "$POLICY") || die "cannot read $POLICY"
case "$MODE" in census | neutral | enforce) ;; *) die "$POLICY has no single COVERAGE_MODE line naming census, neutral or enforce" ;; esac
TARGET=$(sed -n 's/^COVERAGE_TARGET_BP = \([0-9][0-9]*\)$/\1/p' "$POLICY")
case "$TARGET" in "" | *[!0-9]*) die "$POLICY has no single COVERAGE_TARGET_BP line" ;; esac

# 1. The change.
MB=$("$GIT" merge-base "$BASE" "$HEAD") || die "git merge-base $BASE $HEAD failed"
is_sha "$MB" || die "git merge-base answered '$MB', not a commit id"
"$GIT" diff --no-color --no-ext-diff --unified=0 -M --src-prefix=a/ --dst-prefix=b/ "$MB" "$HEAD" >"$OUT/diff.txt" ||
    die "git diff $MB $HEAD failed"
"$GIT" diff --no-color --no-ext-diff --name-only --no-renames -z "$MB" "$HEAD" >"$OUT/changed.z" ||
    die "git diff --name-only $MB $HEAD failed"
"$GIT" ls-files -z >"$OUT/repo-files" || die "git ls-files failed"
tr '\0' '\n' <"$OUT/changed.z" >"$OUT/changed.txt"
say "head $HEAD, merge base $MB: $(grep -c . "$OUT/changed.txt" || true) path(s) changed; policy $MODE, target $TARGET bp"

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

# 3. The libraries.
SELECT_FAILED=""
: >"$PUB/libraries.txt"
if [ -s "$OUT/packages.txt" ]; then
    pats=""
    while IFS= read -r d; do
        case "$d" in *[!A-Za-z0-9_./+-]*) die "package directory '$d' holds a character a target pattern cannot" ;; esac
        if [ "$d" = . ]; then pats="$pats //:"; else pats="$pats //$d:"; fi
    done <"$OUT/packages.txt"
    query="kind('^mojo_library_rule\$', set($pats ))"
    say "buck2 uquery \"$query\""
    rc=0
    "$BUCK2" uquery -c komira.coverage=true "$query" >"$OUT/libraries.raw" 2>"$OUT/logs/uquery.log" </dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then
        SELECT_FAILED="buck2 uquery exited $rc"
        say "$SELECT_FAILED; its last lines:"
        tail -n 20 "$OUT/logs/uquery.log"
    else
        while IFS= read -r l; do
            [ -n "$l" ] || continue
            echo "$l" | grep -qE '^[A-Za-z0-9_]*//[A-Za-z0-9_./+-]*:[A-Za-z0-9_.+-]+$' ||
                die "buck2 uquery printed '$l', which is not a target label"
            echo "$l" >>"$PUB/libraries.txt"
        done <"$OUT/libraries.raw"
    fi
fi

# 4. One coverage build of every library.
: >"$OUT/reports.txt"
: >"$OUT/measured.txt"
: >"$PUB/not_measured.txt"
if [ -s "$PUB/libraries.txt" ]; then
    br="$OUT/logs/build_report.json"
    set --
    while IFS= read -r lib; do set -- "$@" "${lib}[coverage][tests]"; done <"$PUB/libraries.txt"
    rc=0
    "$BUCK2" build -c komira.coverage=true --keep-going --build-report "$br" "$@" >"$OUT/logs/build.log" 2>&1 </dev/null || rc=$?
    say "buck2 build of $# coverage target(s) exited $rc"
    grep -E 'Commands:|BUILD (SUCCEEDED|FAILED)' "$OUT/logs/build.log" | sed 's/^/    /' || true
    if [ ! -f "$br" ]; then
        [ "$rc" -ne 0 ] || die "buck2 build exited 0 and wrote no build report"
        say "buck2 wrote no build report: no library is measured"
        : >"$OUT/verdicts.txt"
    else
        # "<label> ok|gate|failed" per entry of `results`, and
        # "<label> report <path>" per report path in it. An error object is a
        # line holding `{` alone (no other array of the entry holds objects);
        # one counts as the library's own gate when its action's category is
        # mojo_cov_gate and its owner is "<label> (<configuration>)".
        awk '
            /^  "results": \{$/ { inres = 1; next }
            inres && /^  \}/ { inres = 0; next }
            !inres { next }
            /^    "[^"]*": \{$/ {
                lab = $0; sub(/^    "/, "", lab); sub(/": \{$/, "", lab)
                st = ""; ne = 0; ng = 0; cat = ""; next
            }
            /^    \}/ {
                if (lab != "") {
                    v = "failed"
                    if (st == "SUCCESS") v = "ok"
                    else if (st == "FAIL" && ne > 0 && ne == ng) v = "gate"
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
                if (cat == "mojo_cov_gate" && index(o, lab " (") == 1) ng++
                next
            }
            /^ *"buck-out\/[^"]*\/cov\/tests\/[^"\/]*\.xml",?$/ {
                x = $0; sub(/^ *"/, "", x); sub(/",?$/, "", x); print lab " report " x
            }
        ' "$br" >"$OUT/verdicts.txt"
    fi
    while IFS= read -r lib; do
        v=$(awk -v l="$lib" '$1 == l && $2 != "report" { print $2; exit }' "$OUT/verdicts.txt")
        case "$v" in
            ok | gate) ;;
            *)
                echo "$lib" >>"$PUB/not_measured.txt"
                if [ -n "$v" ]; then why="its build failed"; else why="it is not in the build report"; fi
                say "$lib: NOT MEASURED (coverage build failed): $why"
                continue
                ;;
        esac
        [ "$v" = ok ] || say "$lib: its own coverage gate failed (an enforce finding or a gate error; the log below says which); its runs built, so it is measured"
        awk -v l="$lib" '$1 == l && $2 == "report" { print $3 }' "$OUT/verdicts.txt" | sort -u >"$OUT/logs/reports.one"
        while IFS= read -r x; do
            case "$x" in *=*) die "$lib: report path $x holds '=', which covcheck reads as PKGDIR=" ;; esac
            [ -f "$x" ] || die "$lib: the build report names $x, which is not on disk"
            echo "$x" >>"$OUT/reports.txt"
        done <"$OUT/logs/reports.one"
        echo "$lib" >>"$OUT/measured.txt"
        say "$lib: $(grep -c . "$OUT/logs/reports.one" || true) report(s)"
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
    printf 'These libraries the change touches did not build with `-c komira.coverage=true` (a test that fails at -O0 or under kcov, or a dependency that does), so their packages have no numbers here. The job log of `coverage / measure` has the end of each build.\n\n'
    while IFS= read -r l; do printf '%s\n' "- \`$l\`: not measured (coverage build failed)"; done <"$PUB/not_measured.txt"
}

N_LIBS=$(grep -c . "$PUB/libraries.txt" || true)
N_FAILED=$(grep -c . "$PUB/not_measured.txt" || true)
N_REPORTS=$(grep -c . "$OUT/reports.txt" || true)

# 5. The report.
if [ "$N_REPORTS" -gt 0 ]; then
    set -- report --repo-files "$OUT/repo-files" --diff "$OUT/diff.txt" --head-sha "$HEAD" \
        --source-root . --ratchet "$OUT/ratchet.tsv" --mode "$MODE" --target-bp "$TARGET" --name "$NAME" \
        --max-annotations "$MAXANN" --summary-out "$PUB/summary.md" --checkrun-dir "$PUB/checkrun" \
        --result-out "$PUB/result.json" --annotations-out "$PUB/annotations.json"
    while IFS= read -r x; do set -- "$@" --cobertura "$x"; done <"$OUT/reports.txt"
    rc=0
    "$COVCHECK" "$@" >"$OUT/logs/covcheck.log" 2>&1 || rc=$?
    cat "$OUT/logs/covcheck.log"
    [ "$rc" -eq 0 ] || die "covcheck report exited $rc"
    if [ "$N_FAILED" -gt 0 ]; then
        section=$(not_measured_section)
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
            say "the summary is at GitHub's limit: the not-measured list is in summary.md and this log only"
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
        if [ "$N_FAILED" -gt 0 ]; then not_measured_section; fi
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

say "$N_LIBS librar(y/ies) touched, $((N_LIBS - N_FAILED)) measured, $N_FAILED not measured (coverage build failed), $N_REPORTS report(s); check run bodies: $(ls "$PUB/checkrun" | tr '\n' ' ')"
