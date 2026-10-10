#!/bin/sh
# cov_gate.sh -- the coverage gate of one mojo_library in a build action
# (`mojo_cov_gate`, tools/build/mojo/coverage.bzl): `covcheck gate` over the
# kcov reports of the library's tests and their branch records, in the
# policy's mode (tools/build/coverage/policy.bzl). README.md, "The build gate".
#
# usage: busybox sh <gate_dir>/cov_gate.sh <busybox> <label> <package> <mode> <target_bp>
#            <root> <tests> <result_out> <summary_out> <marker_out>
#            [--info-package <package>] [<report>...] [--branch-lcov <branch_info>...]
#
#   <gate_dir>   the cov_gate_dir: this script, covcheck/ (the covcheck binary
#                and the runtime libraries it loads) and ratchet.tsv
#   <package>    the library's package, a repository directory (`(root)` for
#                the top), as covcheck maps files to packages
#   <mode>       census, neutral or enforce; <target_bp> 0 to 10000
#   <root>       the library's sources at their repository paths: its
#                non-generated [src] files and its test sources, and a BUCK
#                file at <package>, so covcheck's nearest-BUCK rule finds the
#                package; nothing else
#   <tests>      a file naming the repository path of each test source the
#                library welds, one per line: each is covcheck's
#                --test-source, set aside wherever it is in the package
#   --info-package <package>  the library's package is test-only
#                (COVERAGE_INFO_ONLY_DIRS, policy.bzl): covcheck reports its
#                findings as information, so it has none and the gate
#                never fails on a finding (covcheck --info-package; exits
#                1 and 2 still fail it)
#   <report>     a test's Cobertura report, in repository paths (cov_run.sh)
#   <branch_info> after the argument `--branch-lcov` (given at most once:
#                every argument after it is a branch record file): a
#                test's branch records, in repository paths
#                (cov_branch_classify, tools/build/coverage/branch/README.md)
#
# The repository's files, as covcheck reads them (--repo-files, NUL-separated
# like `git ls-files -z`), are every file under <root>: the gate measures
# each source file of the library, recorded or not (a file no test compiled
# counts all its executable lines uncovered, UnmeasuredFile), and the test
# sources (<tests>, and anything under <package>/tests/) are set aside. With no report (a library
# with no test) the package is NotMeasured.
#
# Exit status: 0 when covcheck wrote its outputs and found nothing fatal in
# the mode (census and neutral fail on no finding but a Regression, a
# ratchet floor not held): <result_out> (JSON) and <summary_out> (Markdown)
# are covcheck's, and <marker_out> says PASS.
# 1 when covcheck exits 3 (a finding in enforce mode, or a Regression in any
# mode: the summary is printed under `COVERAGE GATE FAILED (<mode>):
# <package>`), when covcheck
# exits 1 (an input it refuses: an unmapped report path, a source it cannot
# read) or 2 (bad usage), each with covcheck's message, in every mode; 2 for
# a usage error of this script.
set -euf
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail
set -o pipefail

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
[ "$#" -ge 10 ] || { echo "cov_gate: usage error" >&2; exit 2; }
HERE=$(abs "${0%/*}")
BB=$(abs "$1")
LABEL=$2
PACKAGE=$3
MODE=$4
TARGET=$5
ROOT=$(abs "$6")
TESTS=$(abs "$7")
RESULT=$(abs "$8")
SUMMARY=$(abs "${9}")
MARKER=$(abs "${10}")
shift 10
INFO=""
if [ "${1:-}" = --info-package ]; then
    [ "$#" -ge 2 ] && [ "$2" = "$PACKAGE" ] || { echo "cov_gate: --info-package must name the package $PACKAGE" >&2; exit 2; }
    INFO=$2
    shift 2
fi
case "$MODE" in census | neutral | enforce) ;; *) echo "cov_gate: mode '$MODE' is not census, neutral or enforce" >&2; exit 2 ;; esac
case "$TARGET" in "" | *[!0-9]*) echo "cov_gate: target '$TARGET' is not a number of basis points" >&2; exit 2 ;; esac
case "$PACKAGE" in "" | /* | */ | *//*) echo "cov_gate: package '$PACKAGE' is not a repository directory" >&2; exit 2 ;; esac

# Private scratch (as in tools/build/mojo/toolchain.bzl): a local action runs
# in the checkout root, so it takes the directory buck2 names for it.
case "${BUCK_SCRATCH_PATH:-}" in
    "") K="$PWD/.cov_gate" ;;
    /*) K="$BUCK_SCRATCH_PATH/cov_gate" ;;
    *) K="$PWD/$BUCK_SCRATCH_PATH/cov_gate" ;;
esac
"$BB" mkdir -p "$K/bin"
"$BB" --install -s "$K/bin"
PATH="$K/bin"
export PATH LC_ALL=C
unset LD_LIBRARY_PATH LD_PRELOAD || true

if [ "$PACKAGE" = "(root)" ]; then BUCKF="$ROOT/BUCK"; else BUCKF="$ROOT/$PACKAGE/BUCK"; fi
[ -f "$BUCKF" ] || { echo "cov_gate: $LABEL: the staged sources have no BUCK file at $PACKAGE" >&2; exit 2; }

# The repository's files: every file under <root>, sorted, NUL-separated.
# The rule refuses a source path holding a newline, so one name per line is
# exact here.
(cd "$ROOT" && find . -type f) | sed 's|^\./||' | sort >"$K/files"
tr '\n' '\000' <"$K/files" >"$K/repo_files"

# Each report as `--cobertura FILE`, and each branch record file (after the
# argument `--branch-lcov`) as `--branch-lcov FILE`: a file name holding `=`
# is given as `=FILE` (covcheck reads `PKGDIR=FILE` otherwise); none needs a
# PKGDIR, since every path in them is a repository path already.
n=$#
flag=--cobertura
while [ "$n" -gt 0 ]; do
    a=$1
    shift
    n=$((n - 1))
    if [ "$a" = --branch-lcov ] && [ "$flag" = --cobertura ]; then
        flag=--branch-lcov
        continue
    fi
    r=$(abs "$a")
    case "$r" in *=*) set -- "$@" "$flag" "=$r" ;; *) set -- "$@" "$flag" "$r" ;; esac
done
while IFS= read -r t; do
    set -- "$@" --test-source "$t"
done <"$TESTS"
if [ -n "$INFO" ]; then set -- "$@" --info-package "$INFO"; fi

rc=0
"$HERE/covcheck/covcheck" gate --package "$PACKAGE" --repo-files "$K/repo_files" --source-root "$ROOT" \
    --ratchet "$HERE/ratchet.tsv" --mode "$MODE" --target-bp "$TARGET" \
    --result-out "$RESULT" --summary-out "$SUMMARY" "$@" >"$K/out" 2>&1 || rc=$?
case "$rc" in
    0)
        printf 'PASS %s (%s)\n' "$LABEL" "$MODE" >"$MARKER"
        ;;
    3)
        # enforce: any finding; every mode: a Regression (a floor of
        # ratchet.tsv not held; README.md, "The ratchet").
        echo "==================================================================" >&2
        echo "COVERAGE GATE FAILED ($MODE): $PACKAGE ($LABEL): covcheck gate exited 3" >&2
        name=${LABEL%% *}
        name=${name##*:}
        echo "The conda package (${name}_conda) is not produced until its coverage meets the policy;" >&2
        echo "the library and its dependents still build." >&2
        echo "==================================================================" >&2
        cat "$SUMMARY" >&2
        cat "$K/out" >&2
        exit 1
        ;;
    *)
        cat "$K/out" >&2
        echo "==================================================================" >&2
        echo "COVERAGE GATE ERROR: $PACKAGE ($LABEL): covcheck exited $rc (its message is above)" >&2
        echo "==================================================================" >&2
        exit 1
        ;;
esac
rm -rf "$K"
