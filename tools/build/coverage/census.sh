#!/bin/sh
# census.sh -- the coverage census of every library: one coverage build of
# each library's gate, its numbers as data (census.tsv), the ranked table
# rendered from it (docs/coverage_census.md) and the floors of ratchet.tsv
# raised to it. census.md says how.
#
# usage: census.sh run     --out <dir> [--cap <seconds>] [--attempts <n>] [--batch <n>] [--skip <file>]
#        census.sh collect --out <dir> [--skip <file>] [--source <commit>] [--note <text>]
#        census.sh render  <busybox> <census.tsv> <ratchet.tsv> <doc out> <ratchet out>
#        census.sh check   <busybox> <census.tsv> <ratchet.tsv> <doc> <result.json>
#
# run and collect are run by hand at the top of a checkout (they call
# ./buck2, so the coverage build runs where the build runs); render and
# check use only the busybox given, and check is the build action of
# //:coverage_census.
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
#            must (a fix applied to it, say). Then copy <dir>/census.tsv over census.tsv here and
#            run render (census.md says how).
#   render   writes the doc and the ratchet from census.tsv and the current
#            ratchet.tsv. A library row of census.tsv is a library under
#            src/ but not under src/tests/ (`kind` library); its package's
#            floors are the lowest of its libraries' numbers (line 0 when one
#            of them was not measured or has no line; no branch floor when one
#            has no branch number, since its gate would find the floor
#            unmeasured), never below the current floor: a floor is raised to what
#            was measured and never lowered (lowering one is a hand edit of
#            ratchet.tsv, which check accepts only where census.tsv measured
#            no more than the new floor). A row of the current ratchet whose
#            package the census has no library row for is dropped. Each
#            floor raised, row dropped and package under its floor is said
#            on stderr. Its comment lines are kept.
#   check    renders into scratch and compares: <doc> and <ratchet.tsv> must
#            be exactly what render writes from <census.tsv> and
#            <ratchet.tsv> (so every floor is at least what the census
#            measured, the doc shows today's floors, and nobody edited the
#            doc by hand). Writes the validation result; exits 0 unless its
#            usage is wrong.
#
# census.tsv: comment lines start with '#'; then the line
# `census<TAB><date YYYY-MM-DD><TAB><source commit, 40 hex, or -><TAB><note or ->`; then one
# row per library, sorted by label in byte order, 12 fields separated by tabs:
#   library      the label (komira//src/<package>:<name>)
#   package      its directory (src/<package>), the ratchet's package
#   kind         library, or test for a library under src/tests/ (shown as
#                information, no floor: test code is not the target)
#   status       OK, RUN_FAILED or GATE_FAILED
#   line_hit line_found      the gate's line numbers, `-` when not OK
#   branch_hit branch_found  the gate's branch numbers (0 0 when it read
#                branch records with no decision), `-` for a library not in
#                COVERAGE_BRANCH_GATE, whose gate reads none (or not OK)
#   branch_gate  yes when the library is in COVERAGE_BRANCH_GATE, else no
#   published    release, conda or no
#   unmeasured   the files no test compiles, comma-separated, or -
#   note         why it is not OK, or -
set -eu

usage() { echo "census.sh: $*" >&2; echo "usage: census.sh run|collect --out <dir> ... | render|check <busybox> ..." >&2; exit 2; }
[ "$#" -ge 1 ] || usage "no command"
CMD=$1
shift

# ---- render and check: the busybox is given -----------------------------

render() { # busybox census ratchet doc_out ratchet_out
    BB=$1 CENSUS=$2 RATCHET=$3 DOC=$4 ROUT=$5
    T=$DOC.rows
    # Pass 1: validate census.tsv, compute the floors, write the rows each
    # section of the doc sorts (key<TAB>row) and the new ratchet rows.
    "$BB" awk -F '\t' -v rat="$RATCHET" -v rout="$ROUT" -v tmp="$T" '
        function die(m) { print "census.sh: error: " m > "/dev/stderr"; bad = 1; exit 1 }
        function num(v, what) { if (v !~ /^(0|[1-9][0-9]*)$/) die(FILENAME ":" FNR ": " what " is not a count: " v); return v + 0 }
        function bp(h, f) { return f == 0 ? -1 : int(h * 10000 / f) }
        BEGIN {
            while ((getline l < rat) > 0) {
                if (l ~ /^#/) { com[++ncom] = l; continue }
                n = split(l, r, "\t")
                if (n != 3 && n != 4) die(rat ": a row has 3 fields, or 4 (a pinned row and its reason): " l)
                if (n == 4 && r[4] == "") die(rat ": the pinned row of " r[1] " has an empty reason")
                old[r[1]] = r[2]; oldb[r[1]] = r[3]; oldn++
                if (n == 4) pin[r[1]] = r[4]
            }
        }
        /^#/ { next }
        !head {
            if (NF != 4 || $1 != "census" || $2 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ || $3 !~ /^([0-9a-f]{40}|-)$/ || $4 == "")
                die(FILENAME ":" FNR ": the first line is census<TAB><date><TAB><commit or -><TAB><note or ->")
            head = 1; print "H\t" $2 "\t" $3 "\t" $4 > tmp; next
        }
        {
            if (NF != 12) die(FILENAME ":" FNR ": a row has 12 fields, not " NF)
            if ($1 !~ /^komira\/\/src\/[^:]+:[A-Za-z0-9_]+$/) die(FILENAME ":" FNR ": not a library label under src/: " $1)
            if (prev != "" && !(prev < $1)) die(FILENAME ":" FNR ": rows are not sorted by label: " $1 " after " prev)
            prev = $1
            pkg = $1; sub(/^komira\/\//, "", pkg); sub(/:.*/, "", pkg)
            if ($2 != pkg) die(FILENAME ":" FNR ": package " $2 " is not the label'"'"'s " pkg)
            if ($3 != (pkg ~ /^src\/tests\// ? "test" : "library")) die(FILENAME ":" FNR ": kind " $3 " is wrong for " pkg)
            if ($4 !~ /^(OK|RUN_FAILED|GATE_FAILED)$/) die(FILENAME ":" FNR ": status " $4)
            if ($9 !~ /^(yes|no)$/ || $10 !~ /^(release|conda|no)$/) die(FILENAME ":" FNR ": branch_gate or published")
            if ($11 == "" || $12 == "") die(FILENAME ":" FNR ": an empty field")
            lb = -1; bb = -1; lh = lf = bh = bf = 0
            if ($4 == "OK") {
                lh = num($5, "line_hit"); lf = num($6, "line_found"); if (lh > lf) die(FILENAME ":" FNR ": line_hit > line_found")
                lb = bp(lh, lf)
                if ($7 != "-" || $8 != "-") { bh = num($7, "branch_hit"); bf = num($8, "branch_found"); if (bh > bf) die(FILENAME ":" FNR ": branch_hit > branch_found"); bb = bp(bh, bf) }
                if ($12 != "-") die(FILENAME ":" FNR ": an OK row has no note")
            } else if ($5 != "-" || $6 != "-" || $7 != "-" || $8 != "-" || $12 == "-") die(FILENAME ":" FNR ": a row that is not OK has no numbers and a note")
            nu = $11 == "-" ? 0 : split($11, u, ",")
            if ($3 == "test") { print "T\t" $1 "\t" $0 > tmp; next }
            # The package floors: the lowest library; line 0 when one is not
            # measured. A library with no executable line (0/0: its sources
            # are all generated) has nothing to cover and sets nothing; its
            # gate finds no unmeasured floor (covcheck, ratchet.mojo).
            if (!(pkg in seen)) { seen[pkg] = 1; pl[pkg] = 10001; pb[pkg] = 10001; pbm[pkg] = 0; pkgs[++np] = pkg }
            empty = $4 == "OK" && lf == 0
            if (empty) { } else if (lb < 0) pl[pkg] = 0; else if (lb < pl[pkg]) pl[pkg] = lb
            # A branch floor only when every library of the package has a
            # branch number: the gate of one without would find the floor
            # unmeasured (a Regression).
            if (empty) { } else if ($4 != "OK" || bb < 0) pbm[pkg] = -1
            else if (pbm[pkg] >= 0) { pbm[pkg] = 1; if (bb < pb[pkg]) pb[pkg] = bb }
            row[NR] = $0; rpkg[NR] = pkg; rlb[NR] = lb; rbb[NR] = bb; rows[++nr] = NR
        }
        END {
            if (bad) exit 1
            if (!head) die(FILENAME ": no census line")
            for (i = 1; i <= ncom; i++) print com[i] > rout
            for (i = 1; i <= np; i++) {
                p = pkgs[i]
                m = pl[p] == 10001 ? 0 : pl[p]; mb = pbm[p] == 1 ? pb[p] : -1
                if (p in pin) {
                    # A pinned row is kept as written: never raised, never lowered.
                    fl[p] = old[p] + 0; flb[p] = oldb[p] == "-" ? -1 : oldb[p] + 0
                    print "R\t" p "\t" p "\t" old[p] "\t" oldb[p] "\t" pin[p] > tmp
                    print "P\t" p "\t" p "\t" old[p] "\t" oldb[p] "\t" pin[p] "\t" m "\t" (mb < 0 ? "-" : mb) > tmp
                    done[p] = 1
                    continue
                }
                f = m; if (p in old) { if (old[p] + 0 > m) f = old[p] + 0; else if (old[p] + 0 < m) print "census.sh: note: raised " p " line " old[p] " -> " m > "/dev/stderr" }
                fb = mb
                if (p in old && oldb[p] != "-") { if (oldb[p] + 0 > mb) fb = oldb[p] + 0; else if (oldb[p] + 0 < mb) print "census.sh: note: raised " p " branch " oldb[p] " -> " mb > "/dev/stderr" }
                fl[p] = f; flb[p] = fb
                print "R\t" p "\t" p "\t" f "\t" (fb < 0 ? "-" : fb) "\t" > tmp
                done[p] = 1
            }
            for (p in old) if (!(p in done)) print "census.sh: note: dropped the row of " p " (no library of the census)" > "/dev/stderr"
            for (k = 1; k <= nr; k++) {
                i = rows[k]; $0 = row[i]; p = rpkg[i]
                below = (rlb[i] >= 0 && rlb[i] < fl[p]) || (rbb[i] >= 0 && rbb[i] < flb[p])
                if (below) print "census.sh: note: " $1 " is under its floor" > "/dev/stderr"
                pn = (p in pin) ? 1 : 0
                if ($4 == "OK") print "L\t" sprintf("%05d", rlb[i] < 0 ? 10001 : rlb[i]) " " $1 "\t" $0 "\t" fl[p] "\t" (flb[p] < 0 ? "-" : flb[p]) "\t" below "\t" pn > tmp
                else print "F\t" $1 "\t" $0 "\t" fl[p] "\t" (flb[p] < 0 ? "-" : flb[p]) "\t0\t" pn > tmp
            }
        }
    ' "$CENSUS" || return 1
    LC_ALL=C "$BB" sort -t "$(printf '\t')" -k1,1 -k2,2 "$T" > "$T.sorted"
    {
        "$BB" awk -F '\t' '$1 == "R" { print $3 "\t" $4 "\t" $5 ($6 == "" ? "" : "\t" $6) }' "$T.sorted"
    } >> "$ROUT"
    # Pass 2: the doc, from the sorted rows.
    "$BB" awk -F '\t' '
        function pct(b) { return sprintf("%d.%02d%%", int(b / 100), b % 100) }
        function bp(h, f) { return int(h * 10000 / f) }
        function frac(h, f) { return f == 0 ? "n/a" : pct(bp(h, f)) " (" h "/" f ")" }
        function short(l) { sub(/^komira\/\//, "", l); return l }
        function floors(l, b) { return pct(l) " / " (b == "-" ? "-" : pct(b)) }
        function branch(gate, h, f) { return h == "-" ? (gate == "yes" ? "no record" : "not gated") : frac(h, f) }
        function nfiles(u) { return u == "-" ? 0 : split(u, xx, ",") }
        $1 == "H" { date = $2; src = $3; cnote = $4; next }
        $1 == "L" {
            # $3.. is the census row (12 fields), then floor line, floor branch, below.
            n++; lib[n] = $3; st[n] = $6; lh[n] = $7; lf[n] = $8; bh[n] = $9; bf[n] = $10; bg[n] = $11; pub[n] = $12; un[n] = $13
            fl[n] = $15; fb[n] = $16; below[n] = $17; pinned[n] = $18
            th += $7; tf += $8; if ($9 != "-") { tbh += $9; tbf += $10; nb++ }
            if ($8 > 0) { b = bp($7, $8); m++; v[m] = b; if (b == 10000) full++; else if (b >= 9000) hi++; else if (b >= 5000) mid++; else lo++ } else na++
            if (nfiles($13) > 0) { nul++; nuf += nfiles($13) }
            np[$12]++; if ($17 == 1) nbelow++
            next
        }
        $1 == "F" { k++; flib[k] = $3; fst[k] = $6; fpub[k] = $12; fnote[k] = $14; ffl[k] = $15; ffb[k] = $16; fpin[k] = $18; np[$12]++; next }
        $1 == "P" { q++; ppkg[q] = $3; pfl[q] = $4; pfb[q] = $5; pwhy[q] = $6; pml[q] = $7; pmb[q] = $8; next }
        $1 == "T" { t++; trow[t] = $0; next }
        END {
            print "# Coverage census"
            print ""
            print "Generated: `tools/build/coverage/census.sh render` writes this file from"
            print "[census.tsv](../tools/build/coverage/census.tsv), the numbers of one coverage"
            print "build of every library under `src/`, and from the floors of"
            print "[ratchet.tsv](../tools/build/coverage/ratchet.tsv), which it raises to them."
            print "The build holds this file, census.tsv and ratchet.tsv to each other"
            print "(`//:coverage_census`), so edit none of them by hand except to lower a floor;"
            print "[The census](../tools/build/coverage/census.md) says how to refresh"
            print "them and what a floor does: a library measured under its package'"'"'s floor"
            print "fails its coverage gate in every mode, so its conda package is not built."
            print ""
            # The commit stays in census.tsv: a commit id in this prose would
            # be a finding of the public boundary lint.
            print "Census of " date (cnote == "-" ? "" : " (" cnote ")") ", built with"
            print "`-c komira.coverage=true`: line coverage from kcov over every test of the"
            print "library, branch coverage from the branch records of the libraries in"
            print "`COVERAGE_BRANCH_GATE` (tools/build/coverage/policy.bzl); the others show"
            print "*not gated*. The libraries under `src/tests/` are test code, outside the"
            print "target: they are listed for information at the end, with no floor."
            print ""
            print "## Summary"
            print ""
            print "| | |"
            print "|---|---:|"
            print "| Libraries (under `src/`, not `src/tests/`) | " (n + k) " |"
            print "| Measured | " n " |"
            print "| Not measured (a run or the gate failed; floor 0) | " k " |"
            print "| Line coverage, all measured libraries | " frac(th, tf) " |"
            # The median: the lower middle of the measured percentages.
            for (i = 2; i <= m; i++) { x = v[i]; for (j = i - 1; j >= 1 && v[j] > x; j--) v[j + 1] = v[j]; v[j + 1] = x }
            print "| Median line coverage (lower middle) | " (m ? pct(v[int((m + 1) / 2)]) : "n/a") " |"
            print "| At 100% / 90% to 100% / 50% to 90% / under 50% / no line | " full + 0 " / " hi + 0 " / " mid + 0 " / " lo + 0 " / " na + 0 " |"
            print "| Branch coverage of the libraries with branch records (" nb + 0 ") | " frac(tbh, tbf) " |"
            print "| Libraries with files no test compiles | " nul + 0 " (" nuf + 0 " files) |"
            print "| Published: in the release / a conda package only / neither | " np["release"] + 0 " / " np["conda"] + 0 " / " np["no"] + 0 " |"
            print "| Measured under their floor | " nbelow + 0 " |"
            print ""
            print "## Ranked by line coverage"
            print ""
            print "Lowest first. *Uncovered* counts executable lines no test ran, the lines of"
            print "files no test compiles included; *Floor* is the package'"'"'s (ratchet.tsv), line /"
            print "branch, `-` for none, *pinned* when set by hand ([Pinned floors](#pinned-floors));"
            print "**under floor** marks a library measured under it."
            print ""
            print "| # | Library | Line | Uncovered | Branch | Files no test compiles | Published | Floor |"
            print "|---:|---|---:|---:|---|---:|---|---|"
            for (i = 1; i <= n; i++)
                print "| " i " | `" short(lib[i]) "` | " frac(lh[i], lf[i]) " | " lf[i] - lh[i] " | " branch(bg[i], bh[i], bf[i]) " | " nfiles(un[i]) " | " pub[i] " | " floors(fl[i], fb[i]) (pinned[i] ? " pinned" : "") (below[i] ? " **under floor**" : "") " |"
            print ""
            print "## Not measured"
            print ""
            if (k == 0) print "None."
            else {
                print "| Library | Status | Why | Published | Floor |"
                print "|---|---|---|---|---|"
                for (i = 1; i <= k; i++) print "| `" short(flib[i]) "` | " fst[i] " | " fnote[i] " | " fpub[i] " | " floors(ffl[i], ffb[i]) (fpin[i] ? " pinned" : "") " |"
            }
            print ""
            print "## Pinned floors"
            print ""
            print "A pinned row of ratchet.tsv holds a floor set by hand, with its reason;"
            print "render keeps it as written, whatever the census measured (*measured* is"
            print "the package floor the census would give it)."
            print ""
            if (q == 0) print "None."
            else {
                print "| Package | Floor | Measured | Why |"
                print "|---|---|---|---|"
                for (i = 1; i <= q; i++) print "| `" ppkg[i] "` | " floors(pfl[i], pfb[i]) " | " floors(pml[i], pmb[i]) " | " pwhy[i] " |"
            }
            print ""
            print "## Files no test compiles"
            print ""
            print "Sources of a library that no test binary of it includes: each counts all its"
            print "executable lines uncovered (covcheck'"'"'s UnmeasuredFile)."
            print ""
            if (nul == 0) print "None."
            for (i = 1; i <= n; i++) if (un[i] != "-") { c = split(un[i], f, ","); s = ""; for (j = 1; j <= c; j++) s = s (j > 1 ? ", " : "") "`" f[j] "`"; print "- `" short(lib[i]) "`: " s }
            print ""
            print "## Test packages (information)"
            print ""
            print "Libraries under `src/tests/`: conformance suites, end-to-end tests and test"
            print "helpers. They are not held to the target and have no floor."
            print ""
            print "| Library | Line | Uncovered | Branch | Files no test compiles | Status |"
            print "|---|---:|---:|---|---:|---|"
            for (i = 1; i <= t; i++) {
                split(trow[i], r, "\t")
                if (r[6] == "OK") print "| `" short(r[3]) "` | " frac(r[7], r[8]) " | " r[8] - r[7] " | " branch(r[11], r[9], r[10]) " | " nfiles(r[13]) " | OK |"
                else print "| `" short(r[3]) "` | - | - | - | - | " r[6] ": " r[14] " |"
            }
        }
    ' "$T.sorted" > "$DOC"
    "$BB" rm -f "$T" "$T.sorted"
}

case "$CMD" in
render)
    [ "$#" -eq 5 ] || usage "render takes 5 arguments"
    render "$@"
    exit $?
    ;;
check)
    [ "$#" -eq 5 ] || usage "check takes 5 arguments"
    BB=$1 RESULT=$5
    S=${BUCK_SCRATCH_PATH:-.}/census_check
    "$BB" mkdir -p "$S"
    msg=""
    if ! render "$BB" "$2" "$3" "$S/doc.md" "$S/ratchet.tsv" 2> "$S/err"; then
        msg="census.tsv or ratchet.tsv is not one census.sh renders: $("$BB" grep '^census.sh: error' "$S/err" | "$BB" head -5)"
    elif ! "$BB" cmp -s "$S/ratchet.tsv" "$3"; then
        msg="ratchet.tsv is not what census.sh render writes from census.tsv and it (a floor under what census.tsv measured, a row of no library of the census, or a package with none): $("$BB" diff "$3" "$S/ratchet.tsv" | "$BB" grep '^[-+][^-+]' | "$BB" head -10)"
    elif ! "$BB" cmp -s "$S/doc.md" "$4"; then
        msg="docs/coverage_census.md is not what census.sh render writes from census.tsv and ratchet.tsv (run it; tools/build/coverage/census.md): $("$BB" diff "$4" "$S/doc.md" | "$BB" grep '^[-+][^-+]' | "$BB" head -10)"
    fi
    if [ -n "$msg" ]; then
        esc=$(printf '%s' "$msg" | "$BB" tr -d '\000-\010\013-\037' | "$BB" awk '{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); printf "%s\\n", $0 }')
        printf '{"version": 1, "data": {"status": "failure", "message": "coverage_census: %s"}}\n' "$esc" > "$RESULT"
    else
        printf '{"version": 1, "data": {"status": "success", "message": "coverage_census: the doc and the floors are census.sh'"'"'s"}}\n' > "$RESULT"
    fi
    exit 0
    ;;
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
    echo "# The coverage census: the data docs/coverage_census.md is rendered from (census.sh; census.md)."
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
echo "census.sh: wrote $OUT/census.tsv ($("$BB" grep -c -v '^#' "$OUT/census.tsv") lines)" >&2
