#!/bin/sh
# coverage_ci_cases.sh -- the cases of the coverage workflow's two scripts,
# run as a build action by the root BUCK's `coverage_ci_cases`
# (tools/build/coverage/defs.bzl):
#   sh coverage_ci_cases.sh <busybox> <result.json> <dir> <covcheck dir>
# <dir> holds .github/workflows/coverage.yml, .github/ci/coverage_measure.sh,
# .github/ci/tests/build_report_gate_failed.json and
# build_report_branch_failed.json, and the real
# tools/build/coverage/policy.bzl, ratchet.tsv and
# tools/build/mojo/coverage_branch.bzl; <covcheck dir> the real covcheck
# with its lib/.
#
# The poster (P cases) is the two shell functions coverage.yml's `post` job
# defines between its `# post_checkrun:` and `# complete_checkrun:` markers,
# as written there. They run against a stand-in `gh` that records each call
# (method, path, body file, body md5; `-` for a body on stdin, which it
# keeps) and answers a POST with an id, over request bodies the REAL
# covcheck wrote for 0, 1, 51 and 120 annotations. The W cases hold the
# workflow's text where the functions cannot: the calls, the artifact name.
# The measure script (M cases) runs in a fixture repository against
# stand-ins for git and buck2 that answer from tables and record their
# arguments, with the real covcheck behind a wrapper that records its argv.
# buck2's stand-in writes build reports in buck2's own shape;
# build_report_gate_failed.json is one buck2 wrote (its trace id, project
# root and message strings left out): `tests//negative/coverage:covlow`
# (enforce) failing in its gate alone, beside its census twin; and so is
# build_report_branch_failed.json: `tests//negative/coverage:branchretor`'s
# `[coverage][tests]` and `[coverage][branch_info]` in one build, its runs
# built and its classifier refusing its branch records (a recorded report:
# that target, whose `return a or b` the classifier refused then, has since
# been deleted; the cases read the report, not the target).
# Exits 1 on the first wrong result, naming it; writes the validation
# result and exits 0 when every case holds.
set -eu
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail
set -o pipefail

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
BB=$(abs "$1")
RESULT=$(abs "$2")
D=$(abs "$3")
CC=$(abs "$4")

case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.coverage_ci_cases" ;;
    /*) T="$BUCK_SCRATCH_PATH/coverage_ci_cases" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/coverage_ci_cases" ;;
esac
"$BB" mkdir -p "$T/bin" "$T/stub"
"$BB" --install -s "$T/bin"
PATH="$T/stub:$T/bin"
export PATH LC_ALL=C
W="$T/work"
mkdir -p "$W"

N=0
red() {
    echo "coverage_ci_cases RED: $*" >&2
    for f in "$W/out" "$W/err" "$W/gh_calls" "$W/want_calls" "$W/buck2_calls" "$W/covcheck_argv"; do
        if [ -f "$f" ]; then
            echo "--- ${f##*/}:" >&2
            cat "$f" >&2
        fi
    done
    exit 1
}
pass() { N=$((N + 1)); }
run() {
    set +e
    "$@" >"$W/out" 2>"$W/err"
    RC=$?
    set -e
}
md5() { md5sum <"$1" | cut -d' ' -f1; }

# ---------------------------------------------------------------- stand-ins
# gh: `gh api --method M PATH --input F [--jq .id | --silent]`. Records
# "M PATH <body file name> <md5>" in $W/gh_calls (F `-`: the body is stdin,
# kept as $W/gh_stdin); fails the k-th call of a method when $W/gh_fail holds
# "M k"; answers a POST's `--jq .id` with 4242.
cat >"$T/stub/gh" <<EOF
#!$BB sh
m="" p="" in="" jq=""
[ "\$1" = api ] || { echo "gh stand-in: not 'gh api'" >&2; exit 9; }
shift
while [ \$# -gt 0 ]; do
    case "\$1" in
        --method) m=\$2; shift 2 ;;
        --input) in=\$2; shift 2 ;;
        --jq) jq=\$2; shift 2 ;;
        --silent) shift ;;
        -*) echo "gh stand-in: unknown flag \$1" >&2; exit 9 ;;
        *) p=\$1; shift ;;
    esac
done
k=\$(grep -c "^\$m " "$W/gh_calls" 2>/dev/null || true)
k=\$((k + 1))
if [ "\$in" = - ]; then
    cat >"$W/gh_stdin"
    in="$W/gh_stdin"
    echo "\$m \$p - \$(md5sum <"\$in" | cut -d' ' -f1)" >>"$W/gh_calls"
else
    echo "\$m \$p \${in##*/} \$(md5sum <"\$in" | cut -d' ' -f1)" >>"$W/gh_calls"
fi
if [ -f "$W/gh_fail" ] && [ "\$(cat "$W/gh_fail")" = "\$m \$k" ]; then
    echo "gh: HTTP 422 (stand-in failure of \$m \$k)" >&2
    exit 1
fi
if [ "\$m" = POST ] && [ "\$jq" = .id ]; then echo 4242; fi
exit 0
EOF
chmod +x "$T/stub/gh"

# --------------------------------------------------------------- the poster
WF="$D/.github/workflows/coverage.yml"
# extract <name>: the lines between coverage.yml's `# <name>: begin` and
# `# <name>: end`, de-indented by the begin marker's indent; must define
# <name>() once.
extract() {
    awk -v n="$1" '
        $0 ~ ("# " n ": begin$") { on = 1; match($0, /^ */); ind = RLENGTH; next }
        $0 ~ ("# " n ": end$") { on = 0 }
        on { print substr($0, ind + 1) }
    ' "$WF" >"$T/$1.sh"
    [ "$(grep -c "^$1() {\$" "$T/$1.sh")" -eq 1 ] ||
        red "P0: coverage.yml holds no $1 function between its markers"
}
extract post_checkrun
extract complete_checkrun
# shellcheck disable=SC1090,SC1091 # the functions, as the workflow writes them
. "$T/post_checkrun.sh"
# shellcheck disable=SC1090,SC1091
. "$T/complete_checkrun.sh"
pass

# W1. The calls the workflow makes, which the cases cannot run: the poster
# for the head commit under the name the measure script gives covcheck,
# with the id file the completing step reads; and the artifact `measure`
# uploads under the name `post` downloads, the same in every attempt (a
# re-run of `post` alone finds the first attempt's), replaced when
# `measure` runs again.
wf_once() { # <case> <fixed string>
    [ "$(grep -cF -- "$2" "$WF")" -eq 1 ] || red "$1: coverage.yml does not hold this line once: $2"
}
wf_once W1 'post_checkrun --dir "$RUNNER_TEMP/coverage/checkrun" --head-sha "$HEAD_SHA" --repo "$GITHUB_REPOSITORY" --name coverage --pause 1 --id-file "$RUNNER_TEMP/checkrun_id"'
wf_once W1 'complete_checkrun --repo "$GITHUB_REPOSITORY" --id-file "$RUNNER_TEMP/checkrun_id" --conclusion "$conclusion"'
[ "$(grep -cF 'HEAD_SHA: ${{ github.event.pull_request.head.sha }}' "$WF")" -eq 2 ] ||
    red "W1: HEAD_SHA is not the head commit in both jobs"
grep -q '^BUCKCONFIG=.buckconfig NAME=coverage ' "$D/.github/ci/coverage_measure.sh" ||
    red "W1: coverage_measure.sh's default check run name is not the poster's (coverage)"
[ "$(grep -cxF '          name: coverage-${{ github.event.pull_request.head.sha }}' "$WF")" -eq 2 ] ||
    red "W1: the artifact is not uploaded and downloaded under one name with no attempt in it"
grep -qxF '          overwrite: true' "$WF" || red "W1: a second upload of the artifact (re-run of measure) would fail"
! grep -q 'run_attempt' "$WF" || red "W1: an artifact name holds the run attempt"
pass

# H. A head commit cut before coverage measurement existed has no
# .github/ci/coverage_measure.sh (nor covcheck's BUCK): on `pull_request`
# the workflow file is the merge commit's, so it runs, but the steps reading
# the head's tree would fail (exit 127) and turn the check red. The
# `head_measured` function between coverage.yml's markers decides, from the
# head's tree, whether the head can be measured; every later step of
# `measure` and the whole `post` job are skipped when it cannot.
extract head_measured
# shellcheck disable=SC1090,SC1091
. "$T/head_measured.sh"
pass
measured() { # <case> <dir> <want: yes|no>
    : >"$W/gh_output"
    run head_measured --dir "$2" --output "$W/gh_output"
    [ "$RC" -eq 0 ] || red "$1: head_measured exited $RC"
    [ "$(cat "$W/gh_output")" = "measured=$3" ] || red "$1: the output is not measured=$3: $(cat "$W/gh_output")"
    if [ "$3" = no ]; then
        grep -q '^::notice title=coverage not measured::.*merge main' "$W/out" ||
            red "$1: no notice telling the author to merge main"
    else
        [ ! -s "$W/out" ] || red "$1: a notice for a head that can be measured"
    fi
    pass
}
mkdir -p "$W/h_old" "$W/h_half/.github/ci" "$W/h_new/.github/ci" "$W/h_new/tools/build/coverage"
measured H1 "$W/h_old" no
: >"$W/h_half/.github/ci/coverage_measure.sh"
measured H2 "$W/h_half" no
# The commonest old head: covcheck's BUCK (much older) without the script.
mkdir -p "$W/h_buck/tools/build/coverage"
: >"$W/h_buck/tools/build/coverage/BUCK"
measured H5 "$W/h_buck" no
: >"$W/h_new/.github/ci/coverage_measure.sh"
: >"$W/h_new/tools/build/coverage/BUCK"
measured H3 "$W/h_new" yes
run head_measured --dir "$W/h_new"
[ "$RC" -eq 2 ] || red "H4: head_measured without --output exited $RC, not 2"
pass

# W2. The wiring the function cannot show: it runs on the head's checkout
# with the step output file, `measure` exports its answer, `post` runs only
# on yes, and in `measure` the order is the checkout, then the check (step
# id `head`), then every other step skipped on no (all but the summary,
# which says why nothing was measured).
wf_once W2 'head_measured --dir . --output "$GITHUB_OUTPUT"'
wf_once W2 '        id: head'
wf_once W2 "measured: \${{ steps.head.outputs.measured }}"
wf_once W2 "    if: github.event.pull_request.head.repo.full_name == github.repository && needs.measure.outputs.measured == 'yes'"
wrong=$(awk '
    /^  measure:$/ { on = 1; next }
    /^  [a-z]/ { on = 0 }
    !on { next }
    function close_step() {
        if (kind == "checkout") { if (seen) print "the checkout comes after the head check"; checked = 1 }
        else if (kind == "head") { if (!checked) print "the head check comes before the checkout" }
        else if (kind == "step" && name != "the summary" && !(gated && seen_before)) print name
    }
    /^      - / { close_step(); kind = "step"; seen_before = seen; name = $0; sub(/^      - (name: )?/, "", name); gated = 0 }
    /^      - uses: actions\/checkout@/ { kind = "checkout" }
    /^        id: head$/ { kind = "head"; seen = 1 }
    /^        name: / { name = substr($0, 15) }
    index($0, "steps.head.outputs.measured == '\''yes'\''") { gated = 1 }
    END { close_step(); if (!seen) print "no step with id head" }
' "$WF")
[ -z "$wrong" ] || red "W2: measure's steps are not checkout, head check, then gated steps: $wrong"
pass

HEAD_SHA=0123456789abcdef0123456789abcdef01234567
REPO=example-owner/example-repo

# want_calls <dir>: the calls a correct run makes for <dir>'s bodies.
want_calls() {
    : >"$W/want_calls"
    for f in "$1"/*.json; do
        b=${f##*/}
        if [ "$b" = 000.json ]; then
            echo "POST repos/$REPO/check-runs $b $(md5 "$f")" >>"$W/want_calls"
        else
            echo "PATCH repos/$REPO/check-runs/4242 $b $(md5 "$f")" >>"$W/want_calls"
        fi
    done
}
post() {
    : >"$W/gh_calls"
    rm -f "$W/checkrun_id"
    run post_checkrun --dir "$1" --head-sha "$HEAD_SHA" --repo "$REPO" --name coverage --pause 0 --id-file "$W/checkrun_id"
}
# finish <conclusion>: the workflow's step after a failed or cancelled
# post, appending to the calls of the post before it.
finish() {
    rm -f "$W/gh_stdin"
    run complete_checkrun --repo "$REPO" --id-file "$W/checkrun_id" --conclusion "$1"
}

# Bodies from the real covcheck: one package `p`, one 240-line file whose odd
# lines are uncovered and even lines covered (120 runs, so 120 `Line not
# covered` annotations), or all covered (none).
R="$W/r"
mkdir -p "$R/p"
: >"$R/p/BUCK"
i=1
while [ "$i" -le 240 ]; do
    echo "    x = $i" >>"$R/p/a.mojo"
    i=$((i + 1))
done
printf 'p/BUCK\0p/a.mojo\0' >"$R/files"
printf '# no floors\n' >"$R/ratchet.tsv"
printf 'diff --git a/p/a.mojo b/p/a.mojo\nindex 1111111..2222222 100644\n--- a/p/a.mojo\n+++ b/p/a.mojo\n@@ -1 +1 @@\n-    x = 0\n+    x = 1\n' >"$R/diff.txt"
cobertura() { # <out> <hits of odd lines> <hits of even lines>
    {
        printf '<?xml version="1.0" ?>\n<coverage>\n<packages>\n<package name="">\n<classes>\n'
        printf '<class name="a_mojo" filename="p/a.mojo">\n<lines>\n'
        i=1
        while [ "$i" -le 240 ]; do
            if [ $((i % 2)) -eq 1 ]; then h=$2; else h=$3; fi
            printf '<line number="%s" hits="%s"/>\n' "$i" "$h"
            i=$((i + 1))
        done
        printf '</lines>\n</class>\n</classes>\n</package>\n</packages>\n</coverage>\n'
    } >"$1"
}
cobertura "$R/half.xml" 0 1
cobertura "$R/all.xml" 1 1
bodies() { # <name> <report> <max annotations> <annotations wanted> <bodies wanted>
    o="$W/b_$1"
    (cd "$R" && "$CC/covcheck" report --repo-files files --diff diff.txt --head-sha "$HEAD_SHA" \
        --source-root . --ratchet ratchet.tsv --mode census --cobertura "$2" --max-annotations "$3" \
        --summary-out "$o.md" --checkrun-dir "$o" --result-out "$o.json") >"$W/out" 2>"$W/err" ||
        red "P setup $1: covcheck report failed"
    got=$(cat "$o"/*.json | { grep -o '"annotation_level"' || true; } | wc -l)
    [ "$got" -eq "$4" ] || red "P setup $1: covcheck wrote $got annotations, not $4"
    got=$(ls "$o" | wc -l)
    [ "$got" -eq "$5" ] || red "P setup $1: covcheck wrote $got bodies, not $5"
}
bodies 0 all.xml 1000 0 2
bodies 1 half.xml 1 1 2
bodies 51 half.xml 51 51 2
bodies 120 half.xml 1000 120 3
pass

# P1-P4. 0, 1, 51 and 120 annotations: exactly one POST (000.json, to
# check-runs) and then one PATCH per later body, in file order, each body
# sent as written.
for k in 0 1 51 120; do
    post "$W/b_$k"
    [ "$RC" -eq 0 ] || red "P $k annotations: the poster exited $RC"
    want_calls "$W/b_$k"
    cmp -s "$W/gh_calls" "$W/want_calls" || red "P $k annotations: the calls are not 1 POST then the PATCHes in file order"
    grep -q "\"head_sha\":\"$HEAD_SHA\"" "$W/b_$k/000.json" || red "P $k annotations: 000.json has no head_sha $HEAD_SHA"
    pass
done
# P12. After a post that completed its run, the completing step sends nothing.
finish neutral
[ "$RC" -eq 0 ] || red "P12: completing after a whole post exited $RC"
cmp -s "$W/gh_calls" "$W/want_calls" || red "P12: completing after a whole post sent a request"
pass

# P5. A failed POST: the poster fails and sends no PATCH.
echo "POST 1" >"$W/gh_fail"
post "$W/b_120"
[ "$RC" -eq 1 ] || red "P5: a failed POST, and the poster exited $RC"
[ "$(cat "$W/gh_calls")" = "POST repos/$REPO/check-runs 000.json $(md5 "$W/b_120/000.json")" ] ||
    red "P5: a failed POST, and the poster went on"
finish neutral
[ "$RC" -eq 0 ] && [ "$(grep -c . "$W/gh_calls")" -eq 1 ] || red "P5: a failed POST (no run), and the completing step sent a request or exited $RC"
pass

# P6. A failed PATCH: the poster fails there and sends nothing after it.
echo "PATCH 1" >"$W/gh_fail"
post "$W/b_120"
[ "$RC" -eq 1 ] || red "P6: a failed PATCH, and the poster exited $RC"
want_calls "$W/b_120"
head -n 2 "$W/want_calls" >"$W/want2"
cmp -s "$W/gh_calls" "$W/want2" || red "P6: a failed PATCH, and the calls were not the POST and that PATCH alone"
pass
# P13. ... and the completing step (the job failed) completes the run, which
# would otherwise stay in progress on the head commit: one PATCH of the
# created run, neutral, after the poster's calls; a second one sends nothing.
finish neutral
[ "$RC" -eq 0 ] || red "P13: completing a run left in progress exited $RC"
[ "$(sed -n 3p "$W/gh_calls" | cut -d' ' -f1-3)" = "PATCH repos/$REPO/check-runs/4242 -" ] && [ "$(grep -c . "$W/gh_calls")" -eq 3 ] ||
    red "P13: a run left in progress, and the completing step did not send one PATCH of it"
grep -q '^{"status":"completed","conclusion":"neutral","output":{"title":"coverage: posting failed","summary":"' "$W/gh_stdin" ||
    red "P13: the completing PATCH does not complete the run as neutral"
finish neutral
[ "$RC" -eq 0 ] && [ "$(grep -c . "$W/gh_calls")" -eq 3 ] || red "P13: a second completing step sent a request"
pass
# P14. A cancelled job: the run is completed as cancelled.
post "$W/b_120"
finish cancelled
grep -q '^{"status":"completed","conclusion":"cancelled","output":{"title":"coverage: cancelled","summary":"' "$W/gh_stdin" ||
    red "P14: a cancelled post, and the run is not completed as cancelled"
pass
# P15. A failing completing PATCH fails the step; a conclusion other than
# neutral or cancelled is bad usage.
post "$W/b_120"
echo "PATCH 2" >"$W/gh_fail"
finish neutral
[ "$RC" -eq 1 ] || red "P15: a failed completing PATCH, and the step exited $RC"
rm "$W/gh_fail"
finish success
[ "$RC" -eq 2 ] || red "P15: --conclusion success, and the step exited $RC, not 2"
pass

# P7-P11. Refused before any request: another head commit, a gap in the
# numbering, a file that is not a body, a POST alone, a last body that does
# not complete the run.
refused() { # <case> <dir> <words in the message>
    post "$2"
    [ "$RC" -eq 1 ] || red "$1: the poster exited $RC, not 1"
    [ ! -s "$W/gh_calls" ] || red "$1: the poster sent a request"
    grep -q "$3" "$W/err" || red "$1: the message does not say '$3'"
    pass
}
cp -r "$W/b_120" "$W/x_sha"
sed -i "s/$HEAD_SHA/1111111111111111111111111111111111111111/" "$W/x_sha/000.json"
refused P7 "$W/x_sha" "000.json does not start"
cp -r "$W/b_120" "$W/x_gap"
rm "$W/x_gap/001.json"
refused P8 "$W/x_gap" "is not body 1"
cp -r "$W/b_120" "$W/x_extra"
: >"$W/x_extra/notes.txt"
refused P9 "$W/x_extra" "is not body 3"
mkdir "$W/x_one"
cp "$W/b_120/000.json" "$W/x_one/"
refused P10 "$W/x_one" "1 bodies"
cp -r "$W/b_120" "$W/x_open"
cp "$W/b_120/001.json" "$W/x_open/002.json"
refused P11 "$W/x_open" "002.json does not start"

# ---------------------------------------------------------- the measure script
MEASURE="$D/.github/ci/coverage_measure.sh"
BASE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MB_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# git: merge-base, the two diffs and ls-files, from $W/git_*.
cat >"$T/stub/git" <<EOF
#!$BB sh
echo "\$*" >>"$W/git_calls"
case "\$1" in
    merge-base) [ "\$2 \$3" = "$BASE_SHA $HEAD_SHA" ] || exit 7; echo $MB_SHA ;;
    diff)
        for a in "\$@"; do last2=\$last1; last1=\$a; done
        [ "\$last2 \$last1" = "$MB_SHA $HEAD_SHA" ] || exit 7
        case " \$* " in
            *" --name-only "*) tr '\n' '\0' <"$W/git_names" ;;
            *) cat "$W/git_diff" ;;
        esac ;;
    ls-files) tr '\n' '\0' <"$W/git_files" ;;
    *) exit 9 ;;
esac
EOF
# buck2: uquery answers each label of $W/uquery_out with its
# coverage_branch_gate (true for a label of $W/branch_gate) in buck2's JSON
# (`--output-attribute`), or $W/uquery_raw as it is; exit 3 when
# $W/uquery_fail exists. build takes every target in one call
# (`<label>[coverage][tests]`, `<label>[coverage][branch_info]`) and writes
# the build report as buck2 pretty-prints it (the fields the script reads,
# in buck2's nesting and indent; one entry per label, its sub-targets'
# outputs under `coverage|branch_info` and `coverage|tests`): per label, a
# row "<label> SUCCESS|FAIL <errors> <path>..." of $W/build_table, <errors>
# `-` or `,`-separated `<category>@<owner>` (`self` the target itself;
# `none` an error that is no action's); the `.xml` paths and the gate's
# result.json are `coverage|tests`, the `.info` paths `coverage|branch_info`
# when that sub-target is asked for, and every row lists only what built,
# as buck2 does for a failed target. Exit 3 when a target fails. With
# $W/build_report_copy, the report is that file, as it is.
cat >"$T/stub/buck2" <<EOF
#!$BB sh
echo "\$*" >>"$W/buck2_calls"
case "\$1" in
    uquery)
        [ ! -f "$W/uquery_fail" ] || { echo "uquery: a BUCK file failed to load" >&2; exit 3; }
        case "\$*" in *attrregexfilter*) if [ -f "$W/cov_tests_out" ]; then cat "$W/cov_tests_out"; fi; exit 0 ;; esac
        if [ -f "$W/uquery_raw" ]; then cat "$W/uquery_raw"; exit 0; fi
        printf '{\n'
        n=0
        while IFS= read -r l; do
            [ "\$n" -eq 0 ] || printf '  },\n'
            n=\$((n + 1))
            v=false
            if [ -f "$W/branch_gate" ] && grep -qxF -- "\$l" "$W/branch_gate"; then v=true; fi
            printf '  "%s": {\n    "coverage_branch_gate": %s\n' "\$l" "\$v"
        done <"$W/uquery_out"
        [ "\$n" -eq 0 ] || printf '  }\n'
        printf '}\n' ;;
    build)
        shift
        br="" libs="" bi=" "
        while [ \$# -gt 0 ]; do
            case "\$1" in
                --build-report) br=\$2; shift 2 ;;
                -c) shift 2 ;;
                -*) shift ;;
                *"[coverage][tests]" | *"[coverage][branch_info]" | *"_cov_gate[tests]")
                    lib=\${1%%\[*}
                    case " \$libs " in *" \$lib "*) ;; *) libs="\$libs \$lib" ;; esac
                    case "\$1" in *branch_info]) bi="\$bi\$lib " ;; esac
                    shift ;;
                *) echo "buck2 stand-in: target \$1 is not a coverage sub-target" >&2; exit 9 ;;
            esac
        done
        echo "Commands: 3 (cached: 3, remote: 0, local: 0)"
        if [ -f "$W/build_report_copy" ]; then
            cp "$W/build_report_copy" "\$br"
            echo "BUILD FAILED"
            exit 3
        fi
        P="komira//tools/build/platforms:linux-x86_64#0123"
        rc=0 n=0
        # outs <indent>: the entry's outputs object, at <indent>.
        outs() {
            printf '%s"outputs": {\n' "\$1"
            if [ -n "\$is" ]; then
                printf '%s  "coverage|branch_info": [\n' "\$1"
                k=0
                for x in \$is; do
                    [ "\$k" -eq 0 ] || printf ',\n'
                    k=\$((k + 1))
                    printf '%s    "%s"' "\$1" "\$x"
                done
                printf '\n%s  ],\n' "\$1"
            fi
            printf '%s  "coverage|tests": [\n' "\$1"
            for x in \$xs; do printf '%s    "%s",\n' "\$1" "\$x"; done
            printf '%s    "buck-out/v2/art/komira/0123/%s/cov/gate/result.json"\n%s  ]\n%s},\n' "\$1" "\${lib#*//}" "\$1" "\$1"
        }
        {
            printf '{\n  "trace_id": "0",\n  "success": true,\n  "results": {\n'
            for lib in \$libs; do
                row=\$(grep "^\$lib " "$W/build_table") || { echo "no row for \$lib" >&2; exit 9; }
                set -- \$row
                st=\$2 errs=\$3
                shift 3
                xs="" is=""
                for x in "\$@"; do
                    case "\$x" in
                        *.info) case "\$bi" in *" \$lib "*) is="\$is \$x" ;; esac ;;
                        *) xs="\$xs \$x" ;;
                    esac
                done
                [ "\$st" = SUCCESS ] || rc=3
                [ "\$n" -eq 0 ] || printf '    },\n'
                n=\$((n + 1))
                printf '    "%s": {\n      "success": "%s",\n' "\$lib" "\$st"
                outs "      "
                printf '      "other_outputs": {},\n      "configured_graph_size": null,\n      "configured": {\n        "%s": {\n          "errors": [' "\$P"
                if [ "\$errs" = - ]; then printf '],\n'; else
                    printf '\n'
                    m=0
                    for e in \$(echo "\$errs" | tr , ' '); do
                        [ "\$m" -eq 0 ] || printf '            },\n'
                        m=\$((m + 1))
                        printf '            {\n              "message_content": "1",\n'
                        if [ "\$e" != none ]; then
                            o=\${e#*@}
                            [ "\$o" != self ] || o=\$lib
                            printf '              "action_error": {\n                "name": {\n                  "category": "%s",\n                  "identifier": ""\n                },\n' "\${e%%@*}"
                            printf '                "key": {\n                  "owner": "%s (%s)"\n                },\n                "error_diagnostics": null\n              },\n' "\$o" "\$P"
                        fi
                        printf '              "error_tags": [\n                "ANY_ACTION_EXECUTION"\n              ],\n              "error_category": "USER"\n'
                    done
                    printf '            }\n          ],\n'
                fi
                printf '          "success": "%s",\n' "\$st"
                outs "          "
                printf '          "other_outputs": {},\n          "configured_graph_size": null\n        }\n      },\n      "errors": []\n'
            done
            [ "\$n" -eq 0 ] || printf '    }\n'
            printf '  },\n  "failures": {},\n  "project_root": "/repo",\n  "truncated": false,\n  "strings": {}\n}\n'
        } >"\$br"
        if [ "\$rc" -eq 0 ]; then echo "BUILD SUCCEEDED"; else echo "BUILD FAILED"; fi
        exit "\$rc" ;;
    *) exit 9 ;;
esac
EOF
# covcheck: records its argv, then is the real one.
cat >"$T/stub/covcheck" <<EOF
#!$BB sh
printf '%s\n' "\$@" >"$W/covcheck_argv"
exec "$CC/covcheck" "\$@"
EOF
chmod +x "$T/stub/git" "$T/stub/buck2" "$T/stub/covcheck"

# The fixture repository: packages src/alpha (with a test), src/beta and
# src/gamma, a root BUCK, the tests and toolchains cells' directories.
M="$W/m"
mkdir -p "$M/src/alpha/sub" "$M/src/alpha/tests" "$M/src/beta" "$M/src/gamma" "$M/src/delta" "$M/docs" \
    "$M/tools/build/tests/functional/x" "$M/tools/build/cells/toolchains" "$M/tools/build/coverage"
printf '[cells]\n  komira = .\n  # a comment = not a cell\n  tests = tools/build/tests\n  toolchains = tools/build/cells/toolchains\n\n[buildfile]\n  name = BUCK\n' >"$M/.buckconfig"
for b in BUCK src/alpha/BUCK src/beta/BUCK src/gamma/BUCK src/delta/BUCK tools/build/tests/functional/x/BUCK tools/build/cells/toolchains/BUCK; do
    : >"$M/$b"
done
printf 'def f():\n    x = 1\n    y = 2\n    return x + y\n' >"$M/src/alpha/alpha.mojo"
printf '    pass\n' >"$M/src/alpha/sub/deep.mojo"
printf 'def test_f():\n    f()\n' >"$M/src/alpha/tests/test_a.mojo"
printf 'def g():\n    return 1\n' >"$M/src/beta/beta.mojo"
printf 'notes\n' >"$M/docs/notes.md"
printf 'x\n' >"$M/tools/build/tests/functional/x/x.mojo"
cp "$D/tools/build/coverage/policy.bzl" "$D/tools/build/coverage/ratchet.tsv" "$M/tools/build/coverage/"
(cd "$M" && find . -type f ! -name '.buckconfig' | sed 's|^\./||' | sort) >"$W/git_files"
echo .buckconfig >>"$W/git_files"
XA="buck-out/v2/art/komira/0123/src/alpha/__alpha__/cov/tests/test_a.xml"
XB="buck-out/v2/art/komira/0123/src/beta/__beta__/cov/tests/test_b.xml"
mkdir -p "$M/${XA%/*}" "$M/${XB%/*}"
printf '<?xml version="1.0" ?>\n<coverage>\n<packages>\n<package name="">\n<classes>\n<class name="alpha_mojo" filename="src/alpha/alpha.mojo">\n<lines>\n<line number="2" hits="1"/>\n<line number="3" hits="0"/>\n<line number="4" hits="1"/>\n</lines>\n</class>\n</classes>\n</package>\n</packages>\n</coverage>\n' >"$M/$XA"
sed 's|src/alpha/alpha.mojo|src/beta/beta.mojo|' "$M/$XA" >"$M/$XB"
printf 'diff --git a/src/alpha/alpha.mojo b/src/alpha/alpha.mojo\nindex 1111111..2222222 100644\n--- a/src/alpha/alpha.mojo\n+++ b/src/alpha/alpha.mojo\n@@ -3 +3 @@\n-    y = 0\n+    y = 2\n' >"$W/git_diff"
printf 'komira//src/alpha:alpha\nkomira//src/beta:beta\nkomira//src/gamma:gamma\n' >"$W/uquery_out"
# Changed: a nested file (alpha's package), a deleted file (gone.mojo,
# gamma's), docs/ (the root package), and files of the two other cells.
printf 'src/alpha/sub/deep.mojo\nsrc/alpha/alpha.mojo\nsrc/beta/beta.mojo\nsrc/gamma/gone.mojo\ndocs/notes.md\ntools/build/tests/functional/x/x.mojo\ntools/build/cells/toolchains/BUCK\n' >"$W/git_names"
QUERY="kind('^mojo_library_rule\$', set( //: //src/alpha: //src/beta: //src/gamma: ))"

measure() { # <case>: a fresh out dir, fresh call records
    O="$W/o_$1"
    : >"$W/buck2_calls"
    : >"$W/git_calls"
    rm -f "$W/covcheck_argv"
    set +e
    (cd "$M" && sh "$MEASURE" --base "$BASE_SHA" --head "$HEAD_SHA" --covcheck "$T/stub/covcheck" --out "$O" \
        --buck2 "$T/stub/buck2" --git "$T/stub/git") >"$W/out" 2>"$W/err"
    RC=$?
    set -e
}

# M1. alpha builds with one report; beta's coverage build fails in a run of
# its own (its build report still names a report); gamma builds and has no
# test. Exit 0; the query is over exactly the packages of the changed files
# outside the other cells; the libraries are built in ONE call (the farm
# runs them in parallel), with the switch and --keep-going; covcheck reads
# alpha's report alone, in the policy's mode and target; beta is NOT
# MEASURED in the summary and in every body's summary; no library reads
# branch records, so none is built or passed; and the poster accepts the
# bodies.
printf 'komira//src/alpha:alpha SUCCESS - %s\nkomira//src/beta:beta FAIL mojo_cov_run@self %s\nkomira//src/gamma:gamma SUCCESS -\n' "$XA" "$XB" >"$W/build_table"
measure M1
[ "$RC" -eq 0 ] || red "M1: a failed coverage build, and the script exited $RC (it must exit 0)"
{
    echo "uquery -c komira.coverage=true $QUERY --output-attribute ^coverage_branch_gate\$"
    echo "uquery -c komira.coverage=true attrregexfilter(coverage_tests, '.', $QUERY)"
    echo "build -c komira.coverage=true --keep-going --build-report $O/logs/build_report.json komira//src/alpha:alpha[coverage][tests] komira//src/beta:beta[coverage][tests] komira//src/gamma:gamma[coverage][tests]"
} >"$W/want_buck2"
cmp -s "$W/buck2_calls" "$W/want_buck2" || { diff "$W/want_buck2" "$W/buck2_calls" >&2 || true; red "M1: buck2 was not asked the expected query and builds"; }
pass
[ "$(grep -c -- '^--cobertura$' "$W/covcheck_argv")" -eq 1 ] && grep -qx "$XA" "$W/covcheck_argv" ||
    red "M1: covcheck did not read alpha's report alone"
! grep -q "beta/__beta__" "$W/covcheck_argv" || red "M1: covcheck read the report of beta, whose coverage build failed"
! grep -q -x -- --branch-lcov "$W/covcheck_argv" || red "M1: covcheck was given branch records, and no library reads them"
mode=$(sed -n 's/^COVERAGE_MODE = "\([a-z]*\)"$/\1/p' "$D/tools/build/coverage/policy.bzl")
bp=$(sed -n 's/^COVERAGE_TARGET_BP = \([0-9]*\)$/\1/p' "$D/tools/build/coverage/policy.bzl")
[ -n "$mode" ] && [ -n "$bp" ] || red "M1: the real policy.bzl has no COVERAGE_MODE or COVERAGE_TARGET_BP line"
grep -A1 -x -- --mode "$W/covcheck_argv" | grep -qx "$mode" || red "M1: covcheck's mode is not the policy's ($mode)"
grep -A1 -x -- --target-bp "$W/covcheck_argv" | grep -qx "$bp" || red "M1: covcheck's target is not the policy's ($bp)"
grep -A1 -x -- --head-sha "$W/covcheck_argv" | grep -qx "$HEAD_SHA" || red "M1: covcheck's head is not the head commit"
pass
[ "$(cat "$O/publish/not_measured.txt")" = "komira//src/beta:beta" ] || red "M1: not_measured.txt is not beta alone"
grep -qF -- '- `komira//src/beta:beta`: not measured (coverage build failed)' "$O/publish/summary.md" ||
    red "M1: the summary does not list beta as not measured"
for f in "$O"/publish/checkrun/*.json; do
    grep -qF '\n- `komira//src/beta:beta`: not measured (coverage build failed)' "$f" ||
        red "M1: ${f##*/}'s summary does not list beta as not measured"
done
grep -q "NOT MEASURED (coverage build failed)" "$W/out" || red "M1: the log does not say beta is not measured"
pass
post "$O/publish/checkrun"
[ "$RC" -eq 0 ] || red "M1: the poster refused the measured bodies"
want_calls "$O/publish/checkrun"
cmp -s "$W/gh_calls" "$W/want_calls" || red "M1: the measured bodies were not posted in order"
pass

# M2. Every coverage build fails: no report, so the script's own neutral
# run (POST in progress, PATCH completed), every library listed; exit 0.
printf 'komira//src/alpha:alpha FAIL mojo_cov_run@self\nkomira//src/beta:beta FAIL mojo_build_cov_test@self\nkomira//src/gamma:gamma FAIL none\n' >"$W/build_table"
measure M2
[ "$RC" -eq 0 ] || red "M2: no library built, and the script exited $RC"
[ ! -f "$W/covcheck_argv" ] || red "M2: covcheck ran with no report"
[ "$(grep -c . "$O/publish/not_measured.txt")" -eq 3 ] || red "M2: not_measured.txt does not list the 3 libraries"
grep -q '"conclusion":"neutral"' "$O/publish/checkrun/001.json" || red "M2: the run does not conclude neutral"
grep -q '"title":"coverage: not measured (coverage build failed)"' "$O/publish/checkrun/000.json" || red "M2: the title does not say not measured"
grep -qF 'komira//src/gamma:gamma`: not measured (coverage build failed)' "$O/publish/summary.md" || red "M2: the summary does not list gamma"
post "$O/publish/checkrun"
[ "$RC" -eq 0 ] || red "M2: the poster refused the script's own bodies"
[ "$(grep -c '^PATCH' "$W/gh_calls")" -eq 1 ] || red "M2: the script's own run is not a POST and one PATCH"
pass

# M3. The query fails (a BUCK file that does not load): not measured, said
# why, nothing built; exit 0.
: >"$W/uquery_fail"
measure M3
rm "$W/uquery_fail"
[ "$RC" -eq 0 ] || red "M3: the query failed, and the script exited $RC"
! grep -q '^build' "$W/buck2_calls" || red "M3: the query failed, and something was built"
grep -q "could not be listed (buck2 uquery exited 3)" "$O/publish/summary.md" || red "M3: the summary does not say the query failed"
pass

# M4. Only files of the other cells changed: no package, no query, the run
# says no library is touched; exit 0.
printf 'tools/build/tests/functional/x/x.mojo\ntools/build/cells/toolchains/BUCK\n' >"$W/git_names"
measure M4
[ "$RC" -eq 0 ] || red "M4: exited $RC"
[ ! -s "$W/buck2_calls" ] || red "M4: buck2 was asked something for files of other cells"
grep -q '"title":"coverage: no Mojo library touched"' "$O/publish/checkrun/000.json" || red "M4: the title does not say no library is touched"
pass

# M5-M8. Wrong inputs fail (exit 1): a policy with no mode, a query answer
# that is not a label, a build report naming a report not on disk; and a
# head that is not a commit id is bad usage (exit 2).
printf 'src/alpha/alpha.mojo\n' >"$W/git_names"
printf 'komira//src/alpha:alpha SUCCESS - %s\n' "$XA" >"$W/build_table"
cp "$M/tools/build/coverage/policy.bzl" "$W/policy.keep"
sed -i 's/^COVERAGE_MODE = /COVERAGE_MODE_X = /' "$M/tools/build/coverage/policy.bzl"
measure M5
cp "$W/policy.keep" "$M/tools/build/coverage/policy.bzl"
[ "$RC" -eq 1 ] && grep -q "no single COVERAGE_MODE" "$W/err" || red "M5: a policy with no mode, and the script exited $RC"
pass
printf 'komira//src/alpha:alpha\nBuild ID: 1\n' >"$W/uquery_out"
measure M6
printf 'komira//src/alpha:alpha\n' >"$W/uquery_out"
[ "$RC" -eq 1 ] && grep -q "which is not a target label" "$W/err" || red "M6: a query line that is no label, and the script exited $RC"
pass
printf 'komira//src/alpha:alpha SUCCESS - buck-out/v2/art/komira/0123/src/alpha/__alpha__/cov/tests/gone.xml\n' >"$W/build_table"
measure M7
[ "$RC" -eq 1 ] && grep -q "which is not on disk" "$W/err" || red "M7: a report not on disk, and the script exited $RC"
pass
(cd "$M" && sh "$MEASURE" --base "$BASE_SHA" --head HEAD --covcheck x --out "$W/o_M8") >"$W/out" 2>"$W/err" && RC=0 || RC=$?
[ "$RC" -eq 2 ] || red "M8: --head HEAD, and the script exited $RC, not 2"
pass

# M9. A failed build is read per library from the build report. alpha
# failed in its OWN gate alone (an enforce finding: its runs built), so it
# is measured, its report read; beta failed in another library's gate (not
# its own: no library waits for a gate today, but the classifier counts only
# the library's own) and gamma in an error that is no action's: both not
# measured.
printf 'src/alpha/alpha.mojo\nsrc/beta/beta.mojo\nsrc/gamma/g.mojo\n' >"$W/git_names"
printf 'komira//src/alpha:alpha\nkomira//src/beta:beta\nkomira//src/gamma:gamma\n' >"$W/uquery_out"
printf 'komira//src/alpha:alpha FAIL mojo_cov_gate@self %s\nkomira//src/beta:beta FAIL mojo_cov_gate@komira//src/alpha:alpha\nkomira//src/gamma:gamma FAIL none\n' "$XA" >"$W/build_table"
measure M9
[ "$RC" -eq 0 ] || red "M9: exited $RC"
[ "$(cat "$O/publish/not_measured.txt")" = "$(printf 'komira//src/beta:beta\nkomira//src/gamma:gamma')" ] ||
    red "M9: not_measured.txt is not beta and gamma (a library whose own gate alone failed is measured)"
[ "$(grep -c -- '^--cobertura$' "$W/covcheck_argv")" -eq 1 ] && grep -qx "$XA" "$W/covcheck_argv" ||
    red "M9: covcheck did not read alpha's report (its own gate alone failed)"
grep -q "komira//src/alpha:alpha: its own coverage gate failed" "$W/out" || red "M9: the log does not say alpha's gate failed"
pass

# M10. A build report buck2 wrote (build_report_gate_failed.json): covlow's
# gate failed alone, covlow_census built; both are measured, from the
# report paths buck2 listed.
cp "$D/.github/ci/tests/build_report_gate_failed.json" "$W/build_report_copy"
printf 'tests//negative/coverage:covlow\ntests//negative/coverage:covlow_census\n' >"$W/uquery_out"
grep -o '"buck-out/[^"]*/cov/tests/[^"]*\.xml"' "$W/build_report_copy" | tr -d '"' | sort -u >"$W/real_xml"
[ "$(grep -c . "$W/real_xml")" -eq 2 ] || red "M10: the fixture does not name 2 reports"
while IFS= read -r x; do mkdir -p "$M/${x%/*}" && cp "$M/$XA" "$M/$x"; done <"$W/real_xml"
measure M10
rm "$W/build_report_copy"
[ "$RC" -eq 0 ] || red "M10: exited $RC"
[ ! -s "$O/publish/not_measured.txt" ] || red "M10: a library of buck2's report is not measured"
[ "$(grep -c -- '^--cobertura$' "$W/covcheck_argv")" -eq 2 ] || red "M10: covcheck did not read the 2 reports of buck2's report"
pass

# M11. The ratchet covcheck reads holds the rows of the measured packages
# only (and every comment line): a row of a package this run did not
# measure (beta, whose build failed; delta, not touched) would read as a
# Regression in every check run.
printf 'src/alpha/alpha.mojo\nsrc/beta/beta.mojo\n' >"$W/git_names"
printf 'komira//src/alpha:alpha\nkomira//src/beta:beta\n' >"$W/uquery_out"
printf 'komira//src/alpha:alpha SUCCESS - %s\nkomira//src/beta:beta FAIL mojo_cov_run@self\n' "$XA" >"$W/build_table"
printf '# floors\nsrc/alpha\t6000\t-\nsrc/beta\t5000\t-\nsrc/delta\t5000\t-\n' >"$M/rows.tsv"
O="$W/o_M11"
: >"$W/buck2_calls"
(cd "$M" && sh "$MEASURE" --base "$BASE_SHA" --head "$HEAD_SHA" --covcheck "$T/stub/covcheck" --out "$O" \
    --buck2 "$T/stub/buck2" --git "$T/stub/git" --ratchet rows.tsv) >"$W/out" 2>"$W/err" && RC=0 || RC=$?
[ "$RC" -eq 0 ] || red "M11: exited $RC"
rt=$(grep -A1 -x -- --ratchet "$W/covcheck_argv" | tail -n 1)
[ "$(cd "$M" && cat "$rt")" = "$(printf '# floors\nsrc/alpha\t6000\t-')" ] ||
    red "M11: covcheck's ratchet is not the comment and alpha's row alone"
! grep -q '"package":"src/\(delta\|beta\)"' "$O/publish/result.json" || red "M11: the result has a finding for a package this run did not measure"
pass

# The branch records (B cases): a library whose gate reads its tests'
# branch records (its coverage_branch_gate, in the query's answer: alpha,
# from $W/branch_gate) has its `[coverage][branch_info]` built in the same
# call, and its `.info` paths are covcheck's --branch-lcov; any other has
# neither. IA is alpha's record of its one test: an `if` at line 3 taken
# one way of two.
IA="buck-out/v2/art/komira/0123/src/alpha/__alpha__/cov/branch/test_a.info"
mkdir -p "$M/${IA%/*}"
printf 'SF:src/alpha/alpha.mojo\nBRDA:3,5:br:0/1,0,1\nBRDA:3,5:br:0/1,1,0\nend_of_record\n' >"$M/$IA"
printf 'komira//src/alpha:alpha\n' >"$W/branch_gate"
printf 'src/alpha/alpha.mojo\nsrc/beta/beta.mojo\n' >"$W/git_names"
printf 'komira//src/alpha:alpha\nkomira//src/beta:beta\n' >"$W/uquery_out"
QUERY2="kind('^mojo_library_rule\$', set( //src/alpha: //src/beta: ))"

# B1. alpha (listed) and beta (not) both build. ONE build call: alpha's
# tests and branch records, beta's tests alone; covcheck reads alpha's
# record (and no other) beside both reports, so alpha's branch row is the
# record's 50.00% (1/2) where beta's is not measured; the lists say which
# libraries read branch records and that none of them went unread. Exit 0.
# Red when the script ignores the attribute (no [branch_info], no
# --branch-lcov) or builds the records and does not pass them.
printf 'komira//src/alpha:alpha SUCCESS - %s %s\nkomira//src/beta:beta SUCCESS - %s\n' "$XA" "$IA" "$XB" >"$W/build_table"
measure B1
[ "$RC" -eq 0 ] || red "B1: exited $RC"
{
    echo "uquery -c komira.coverage=true $QUERY2 --output-attribute ^coverage_branch_gate\$"
    echo "uquery -c komira.coverage=true attrregexfilter(coverage_tests, '.', $QUERY2)"
    echo "build -c komira.coverage=true --keep-going --build-report $O/logs/build_report.json komira//src/alpha:alpha[coverage][tests] komira//src/alpha:alpha[coverage][branch_info] komira//src/beta:beta[coverage][tests]"
} >"$W/want_buck2"
cmp -s "$W/buck2_calls" "$W/want_buck2" || { diff "$W/want_buck2" "$W/buck2_calls" >&2 || true; red "B1: buck2 was not asked for alpha's branch records (alone) in the one build"; }
pass
[ "$(grep -c -x -- --branch-lcov "$W/covcheck_argv")" -eq 1 ] && [ "$(grep -A1 -x -- --branch-lcov "$W/covcheck_argv" | tail -n 1)" = "$IA" ] ||
    red "B1: covcheck's --branch-lcov is not alpha's record alone"
[ "$(grep -c -x -- --cobertura "$W/covcheck_argv")" -eq 2 ] || red "B1: covcheck did not read both reports"
grep -F '| `src/alpha` (touched) |' "$O/publish/summary.md" | grep -qF '| 50.00% (1/2) |' ||
    red "B1: the summary's alpha row does not show its branch record (50.00% (1/2))"
grep -F '| `src/beta` |' "$O/publish/summary.md" | grep -qF '| not measured |' ||
    red "B1: the summary's beta row (no records read) is not branch not measured"
[ "$(cat "$O/publish/branch_libraries.txt")" = "komira//src/alpha:alpha" ] || red "B1: branch_libraries.txt is not alpha alone"
[ ! -s "$O/publish/branch_not_measured.txt" ] || red "B1: branch_not_measured.txt is not empty"
! grep -q "Not measured: branch" "$O/publish/summary.md" || red "B1: the summary has a branch not measured section"
pass

# B2. buck2's own report (build_report_branch_failed.json) for a listed
# library whose classifier refused its records: its runs built, so its
# line report is read; its records are not (none is passed), it is listed
# as branch not measured in the summary and in every body's summary, and
# the job exits 0. Red when that failure turns the job red, or the library
# goes unmeasured, or unlisted.
cp "$D/.github/ci/tests/build_report_branch_failed.json" "$W/build_report_copy"
RL="tests//negative/coverage:branchretor"
printf '%s\n' "$RL" >"$W/uquery_out"
printf '%s\n' "$RL" >"$W/branch_gate"
grep -o '"buck-out/[^"]*/cov/tests/[^"]*\.xml"' "$W/build_report_copy" | tr -d '"' | sort -u >"$W/real_xml"
[ "$(grep -c . "$W/real_xml")" -eq 1 ] || red "B2: the fixture does not name 1 report"
while IFS= read -r x; do mkdir -p "$M/${x%/*}" && cp "$M/$XA" "$M/$x"; done <"$W/real_xml"
measure B2
rm "$W/build_report_copy"
[ "$RC" -eq 0 ] || red "B2: a listed library's branch records failed to build, and the script exited $RC (it must exit 0)"
grep -q "build .*$RL\[coverage\]\[tests\] $RL\[coverage\]\[branch_info\]\$" "$W/buck2_calls" || red "B2: the build did not ask for $RL's branch records"
[ ! -s "$O/publish/not_measured.txt" ] || red "B2: its runs built, and it is listed as not measured"
[ "$(grep -c -x -- --cobertura "$W/covcheck_argv")" -eq 1 ] || red "B2: covcheck did not read its report"
! grep -q -x -- --branch-lcov "$W/covcheck_argv" || red "B2: covcheck was given branch records of a library whose records failed"
[ "$(cat "$O/publish/branch_not_measured.txt")" = "$RL" ] || red "B2: branch_not_measured.txt is not $RL"
line="- \`$RL\`: branch not measured (its branch records failed to build)"
grep -qxF -- "$line" "$O/publish/summary.md" || red "B2: the summary does not list $RL as branch not measured"
for f in "$O"/publish/checkrun/*.json; do
    grep -qF "\\n$line" "$f" || red "B2: ${f##*/}'s summary does not list $RL as branch not measured"
done
grep -q "$RL: branch NOT MEASURED: its branch records failed to build" "$W/out" || red "B2: the log does not say its branch is not measured"
pass

# B3. Read per library from the build report (stand-in): alpha (listed)
# failed in its OWN gate alone, which reads the same records, so its line
# report is read and its records are not (branch not measured, saying
# why); beta (listed) failed in a branch coverage action of its dependency
# alpha, which is no failure of its own: not measured at all. Exit 0.
printf 'src/alpha/alpha.mojo\nsrc/beta/beta.mojo\n' >"$W/git_names"
printf 'komira//src/alpha:alpha\nkomira//src/beta:beta\n' >"$W/uquery_out"
printf 'komira//src/alpha:alpha\nkomira//src/beta:beta\n' >"$W/branch_gate"
printf 'komira//src/alpha:alpha FAIL mojo_cov_gate@self %s %s\nkomira//src/beta:beta FAIL mojo_cov_branch_classify@komira//src/alpha:alpha %s\n' "$XA" "$IA" "$XB" >"$W/build_table"
measure B3
[ "$RC" -eq 0 ] || red "B3: exited $RC"
[ "$(cat "$O/publish/not_measured.txt")" = "komira//src/beta:beta" ] || red "B3: not_measured.txt is not beta alone"
[ "$(cat "$O/publish/branch_not_measured.txt")" = "komira//src/alpha:alpha" ] || red "B3: branch_not_measured.txt is not alpha alone"
! grep -q -x -- --branch-lcov "$W/covcheck_argv" || red "B3: covcheck was given the records of a library whose gate failed"
grep -A1 -x -- --cobertura "$W/covcheck_argv" | grep -qx "$XA" || red "B3: covcheck did not read alpha's report"
grep -qxF -- '- `komira//src/alpha:alpha`: branch not measured (its coverage gate, which reads the same records, failed)' "$O/publish/summary.md" ||
    red "B3: the summary does not say alpha's gate failed"
pass

# B4. A listed library whose entry is SUCCESS and names no branch record for
# its report: buck2 or the rule is wrong, exit 1.
printf 'komira//src/alpha:alpha\n' >"$W/uquery_out"
printf 'komira//src/alpha:alpha SUCCESS - %s\n' "$XA" >"$W/build_table"
measure B4
[ "$RC" -eq 1 ] && grep -q "names 0 branch record file(s) for 1 report(s)" "$W/err" || red "B4: a listed library with no record, and the script exited $RC"
pass

# B7. A listed library whose entry names its README's report
# (cov/tests/readme.xml) beside its test's report and the test's one branch
# record: the README's run has no branch records (line coverage only), so
# one record for its one test is right, exit 0, and covcheck reads both
# reports and the record. Red when the README's report is counted as a
# test's (exit 1, "1 branch record file(s) for 2 report(s)").
XR="buck-out/v2/art/komira/0123/src/alpha/__alpha__/cov/tests/readme.xml"
cp "$M/$XA" "$M/$XR"
printf 'komira//src/alpha:alpha SUCCESS - %s %s %s\n' "$XA" "$XR" "$IA" >"$W/build_table"
measure B7
[ "$RC" -eq 0 ] || red "B7: a listed library with a README report beside one test's report and record, and the script exited $RC: $(head -c 300 "$W/err")"
[ "$(grep -c -x -- --cobertura "$W/covcheck_argv")" -eq 2 ] && grep -qx "$XR" "$W/covcheck_argv" || red "B7: covcheck did not read both reports, the README's included"
[ "$(grep -A1 -x -- --branch-lcov "$W/covcheck_argv" | tail -n 1)" = "$IA" ] || red "B7: covcheck's --branch-lcov is not the test's record"
pass

# C1. A library naming mojo_test targets in coverage_tests (the second
# query's answer): its `<library>_cov_gate[tests]` is built in the same
# call, and that entry's reports are read beside its own. C2: when that
# entry failed (a run of a named test), the library is NOT MEASURED. Red
# when the runs of coverage_tests are not asked for or not read.
rm -f "$W/branch_gate"
printf 'komira//src/alpha:alpha\n' >"$W/uquery_out"
printf 'komira//src/alpha:alpha\n' >"$W/cov_tests_out"
XT="buck-out/v2/art/komira/0123/src/alpha/__alpha_cov_gate__/cov/tests/test_far.xml"
mkdir -p "$M/${XT%/*}"
cp "$M/$XA" "$M/$XT"
printf 'komira//src/alpha:alpha SUCCESS - %s\nkomira//src/alpha:alpha_cov_gate SUCCESS - %s\n' "$XA" "$XT" >"$W/build_table"
measure C1
[ "$RC" -eq 0 ] || red "C1: exited $RC: $(head -c 300 "$W/err")"
grep -q "build .*komira//src/alpha:alpha\[coverage\]\[tests\] komira//src/alpha:alpha_cov_gate\[tests\]\$" "$W/buck2_calls" || red "C1: the build did not ask for alpha_cov_gate[tests]"
[ "$(grep -c -x -- --cobertura "$W/covcheck_argv")" -eq 2 ] && grep -qx "$XT" "$W/covcheck_argv" || red "C1: covcheck did not read the coverage_tests run's report"
[ "$(cat "$O/publish/coverage_tests_libraries.txt")" = "komira//src/alpha:alpha" ] || red "C1: coverage_tests_libraries.txt is not alpha"
pass
printf 'komira//src/alpha:alpha SUCCESS - %s\nkomira//src/alpha:alpha_cov_gate FAIL mojo_cov_run@self\n' "$XA" >"$W/build_table"
measure C2
[ "$RC" -eq 0 ] || red "C2: exited $RC"
[ "$(cat "$O/publish/not_measured.txt")" = "komira//src/alpha:alpha" ] || red "C2: a library whose coverage_tests run failed is not listed as not measured"
pass
rm "$W/cov_tests_out"

# B5. The query's answer is a library and its attribute, each: a library
# with no value (buck2 printing `{}`) is a wrong answer, exit 1.
printf '{\n  "komira//src/alpha:alpha": {}\n}\n' >"$W/uquery_raw"
measure B5
rm "$W/uquery_raw"
[ "$RC" -eq 1 ] && grep -q "which is not a library with its coverage_branch_gate" "$W/err" || red "B5: a library with no coverage_branch_gate, and the script exited $RC"
pass

# B6. The script's BRANCH_CATEGORIES are the categories of the branch
# coverage actions (tools/build/mojo/coverage_branch.bzl), so a failure of
# one of them reads as the library's branch, not as its coverage build.
sed -n 's/^ *category = "\(mojo_[a-z_]*\)",$/\1/p' "$D/tools/build/mojo/coverage_branch.bzl" | sort >"$W/cats_rule"
sed -n 's/^BRANCH_CATEGORIES="\([a-z_ ]*\)"$/\1/p' "$MEASURE" | tr ' ' '\n' | sort >"$W/cats_script"
[ -s "$W/cats_rule" ] && cmp -s "$W/cats_rule" "$W/cats_script" ||
    { diff "$W/cats_rule" "$W/cats_script" >&2 || true; red "B6: BRANCH_CATEGORIES is not the categories of coverage_branch.bzl"; }
pass

# Test-only packages (T cases): a package under a directory of the
# policy's COVERAGE_INFO_ONLY_DIRS (src/tests) is measured and shown, but
# what covcheck finds in it is information. src/tests/e2e/eps is alpha's
# source (2 of 3 lines covered: BelowTarget) in such a package; the policy
# is put in enforce mode, where a finding fails the check run.
mkdir -p "$M/src/tests/e2e/eps"
: >"$M/src/tests/e2e/eps/BUCK"
cp "$M/src/alpha/alpha.mojo" "$M/src/tests/e2e/eps/eps.mojo"
printf 'src/tests/e2e/eps/BUCK\nsrc/tests/e2e/eps/eps.mojo\n' >>"$W/git_files"
XE="buck-out/v2/art/komira/0123/src/tests/e2e/eps/__eps__/cov/tests/test_e.xml"
mkdir -p "$M/${XE%/*}"
sed 's|src/alpha/alpha.mojo|src/tests/e2e/eps/eps.mojo|' "$M/$XA" >"$M/$XE"
sed 's|src/alpha/alpha.mojo|src/tests/e2e/eps/eps.mojo|g' "$W/git_diff" >"$W/git_diff_eps"
cp "$W/git_diff" "$W/git_diff_alpha"
cat "$W/git_diff_alpha" "$W/git_diff_eps" >"$W/git_diff"
: >"$W/branch_gate"
cp "$M/tools/build/coverage/policy.bzl" "$W/policy.keep"
sed -i 's/^COVERAGE_MODE = .*/COVERAGE_MODE = "enforce"/' "$M/tools/build/coverage/policy.bzl"
grep -qx 'COVERAGE_INFO_ONLY_DIRS = \["src/tests"\]' "$M/tools/build/coverage/policy.bzl" ||
    red "T0: the real policy.bzl does not hold COVERAGE_INFO_ONLY_DIRS = [\"src/tests\"] on one line"
# levels <case> <path prefix>: the annotation levels of the paths under it
# in publish/annotations.json, each once, sorted, on one line.
levels() {
    tr '{' '\n' <"$O/publish/annotations.json" | grep -F "\"path\":\"$2" |
        sed -n 's/.*"annotation_level":"\([a-z]*\)".*/\1/p' | sort -u | tr '\n' ' '
}
pass

# T0. The policy's COVERAGE_INFO_ONLY_DIRS line is read as written, one
# line of double-quoted directories, or the script fails (exit 1) naming
# it: renamed (no line), given twice, a list over several lines, a
# single-quoted item; and an item that is no repository directory ('.',
# '..', a '..' segment, a trailing '/', empty). Red when a malformed line
# reads as an empty list (no test-only package) or an item is passed on.
info_policy() { # <case> <want in the message> <sed program>
    cp "$W/policy.keep" "$M/tools/build/coverage/policy.bzl"
    sed -i "$3" "$M/tools/build/coverage/policy.bzl"
    measure "$1"
    cp "$W/policy.keep" "$M/tools/build/coverage/policy.bzl"
    sed -i 's/^COVERAGE_MODE = .*/COVERAGE_MODE = "enforce"/' "$M/tools/build/coverage/policy.bzl"
    [ "$RC" -eq 1 ] && grep -qF -- "$2" "$W/err" || red "$1: a malformed COVERAGE_INFO_ONLY_DIRS, and the script exited $RC without '$2'"
    [ ! -s "$W/buck2_calls" ] || red "$1: a malformed COVERAGE_INFO_ONLY_DIRS, and buck2 was asked something"
    pass
}
NO1="has no single COVERAGE_INFO_ONLY_DIRS line"
info_policy T0a "$NO1" 's/^COVERAGE_INFO_ONLY_DIRS = /COVERAGE_INFO_ONLY_DIRS_X = /'
info_policy T0b "$NO1" 's/^\(COVERAGE_INFO_ONLY_DIRS = .*\)$/\1\n\1/'
info_policy T0c "$NO1" 's/^COVERAGE_INFO_ONLY_DIRS = \[\(.*\)\]$/COVERAGE_INFO_ONLY_DIRS = [\n    \1,\n]/'
info_policy T0d "$NO1" "s/^COVERAGE_INFO_ONLY_DIRS = .*/COVERAGE_INFO_ONLY_DIRS = ['src\/tests']/"
NODIR="is not a repository directory"
for bad in . .. src/../tests src/tests/ ""; do
    info_policy "T0e($bad)" "$NODIR" "s|^COVERAGE_INFO_ONLY_DIRS = .*|COVERAGE_INFO_ONLY_DIRS = [\"src/tests\", \"$bad\"]|"
done

# T1. Only the test-only package is touched: covcheck is given the policy's
# directory as --info-package; the check run concludes success in enforce
# mode with no finding, its BelowTarget information; every annotation of the
# package is a notice, and no body carries a failure. Red when the script
# passes no --info-package, or covcheck counts the package's findings.
printf 'src/tests/e2e/eps/eps.mojo\n' >"$W/git_names"
printf 'komira//src/tests/e2e/eps:eps\n' >"$W/uquery_out"
printf 'komira//src/tests/e2e/eps:eps SUCCESS - %s\n' "$XE" >"$W/build_table"
measure T1
[ "$RC" -eq 0 ] || red "T1: exited $RC"
[ "$(grep -A1 -x -- --info-package "$W/covcheck_argv" | grep -vx -- --info-package)" = src/tests ] ||
    red "T1: covcheck's --info-package is not the policy's src/tests alone"
grep -q '"conclusion":"success"' "$O/publish/result.json" && grep -q '"findings":\[\],' "$O/publish/result.json" ||
    red "T1: a test-only package below the target, and the result is not success with no finding"
grep -q '"info_findings":\[{"kind":"BelowTarget","package":"src/tests/e2e/eps","metric":"line"' "$O/publish/result.json" ||
    red "T1: the result does not give the package's BelowTarget as information"
last=$(ls "$O/publish/checkrun" | tail -n 1)
grep -q '"status":"completed","conclusion":"success"' "$O/publish/checkrun/$last" || red "T1: the last body does not conclude success"
! grep -q '"annotation_level":"\(failure\|warning\)"' "$O"/publish/checkrun/*.json || red "T1: a body carries a failure or warning annotation"
[ "$(levels T1 src/tests/e2e/eps/)" = "notice " ] || red "T1: the package's annotations are not all notices: $(levels T1 src/tests/e2e/eps/)"
grep -qF '| `src/tests/e2e/eps` (touched) |' "$O/publish/summary.md" && grep -qF '| info: BelowTarget' "$O/publish/summary.md" ||
    red "T1: the summary does not show the package with its information"
pass

# T2. The same change touching alpha too: alpha below the target still fails
# the run (the information is the test-only package's alone), its
# annotations failures, the test-only package's still notices. Red when the
# exclusion covers every package.
printf 'src/alpha/alpha.mojo\nsrc/tests/e2e/eps/eps.mojo\n' >"$W/git_names"
printf 'komira//src/alpha:alpha\nkomira//src/tests/e2e/eps:eps\n' >"$W/uquery_out"
printf 'komira//src/alpha:alpha SUCCESS - %s\nkomira//src/tests/e2e/eps:eps SUCCESS - %s\n' "$XA" "$XE" >"$W/build_table"
measure T2
[ "$RC" -eq 0 ] || red "T2: exited $RC"
last=$(ls "$O/publish/checkrun" | tail -n 1)
grep -q '"status":"completed","conclusion":"failure"' "$O/publish/checkrun/$last" || red "T2: alpha below the target, and the run does not conclude failure"
grep -q '"findings":\[{"kind":"BelowTarget","package":"src/alpha",' "$O/publish/result.json" || red "T2: alpha's BelowTarget is not a finding"
[ "$(levels T2 src/alpha/)" = "failure " ] || red "T2: alpha's annotations are not failures: $(levels T2 src/alpha/)"
[ "$(levels T2 src/tests/e2e/eps/)" = "notice " ] || red "T2: the test-only package's annotations are not all notices: $(levels T2 src/tests/e2e/eps/)"
pass
cp "$W/policy.keep" "$M/tools/build/coverage/policy.bzl"
cp "$W/git_diff_alpha" "$W/git_diff"

cd /
rm -rf "$T"
printf '{"version": 1, "data": {"status": "success", "message": "coverage_ci_cases: %s cases passed"}}\n' "$N" >"$RESULT"
echo "coverage_ci_cases GREEN: $N cases"
