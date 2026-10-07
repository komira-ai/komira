#!/bin/sh
# report.sh -- checks of the per-test reports of coverage runs (test 43), run
# as a build action by cov_report_check (defs.bzl):
#   sh report.sh <busybox> <out> golden (--golden <golden> <report>)...
#   sh report.sh <busybox> <out> census --covcheck <covcheck...> --package <dir>
#       (--file <repo path> <source>)... (--expect <s>)... (--cobertura <report>)...
#   sh report.sh <busybox> <out> result (--expect <s>)... --json <result.json>
#
# golden: each report is its golden file, byte for byte.
# census: covcheck's build gate (`covcheck gate --mode census`) reads the
#   reports over a source root holding each --file at its repository path and
#   a BUCK file in <dir>, with every --file and that BUCK file as the
#   repository's files and an empty ratchet. It must exit 0, and its result
#   JSON must hold each --expect string (the package's numbers): the reports
#   cov_run.sh writes are what covcheck reads, end to end.
# result (test 46): the result JSON of a library's coverage gate holds each
#   --expect string.
# Writes what it checked to <out>; exits 1 naming the first failure.
set -euf
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail
set -o pipefail
abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
BB=$(abs "$1")
OUT=$(abs "$2")
MODE=$3
shift 3
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.cov_report" ;;
    /*) T="$BUCK_SCRATCH_PATH/cov_report" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/cov_report" ;;
esac
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
export PATH LC_ALL=C
red() { echo "cov_report_check RED: $*" >&2; exit 1; }
: >"$OUT"
case "$MODE" in
    golden)
        [ "$#" -ge 3 ] || red "golden: no report"
        while [ "$#" -gt 0 ]; do
            [ "$1" = --golden ] && [ "$#" -ge 3 ] || { echo "report.sh: usage" >&2; exit 2; }
            g=$2 r=$3
            shift 3
            cmp -s "$g" "$r" || red "${r##*/} is not ${g##*/} byte for byte; diff golden report:
$(diff "$g" "$r" || true)"
            echo "ok ${r##*/} = ${g##*/} ($(wc -c <"$r") bytes)" >>"$OUT"
        done
        ;;
    census)
        [ "$1" = --covcheck ] || { echo "report.sh: census needs --covcheck first" >&2; exit 2; }
        shift
        CC=""
        while [ "$#" -gt 0 ] && [ "$1" != --package ]; do
            CC="$CC $(abs "$1")"
            shift
        done
        [ "$#" -ge 2 ] || { echo "report.sh: census needs --package" >&2; exit 2; }
        PKG=$2
        shift 2
        ROOT="$T/root"
        mkdir -p "$ROOT/$PKG"
        : >"$ROOT/$PKG/BUCK"
        printf '%s\0' "$PKG/BUCK" >"$T/repo_files"
        printf '# no floors\n' >"$T/ratchet.tsv"
        EXPECT="$T/expect"
        : >"$EXPECT"
        set -- "$@" --end
        while [ "$1" != --end ]; do
            case "$1" in
                --file)
                    mkdir -p "$ROOT/${2%/*}"
                    cp "$3" "$ROOT/$2"
                    printf '%s\0' "$2" >>"$T/repo_files"
                    shift 3
                    ;;
                --expect)
                    printf '%s\n' "$2" >>"$EXPECT"
                    shift 2
                    ;;
                --cobertura)
                    set -- "$@" --cobertura "$(abs "$2")"
                    shift 2
                    ;;
                *) echo "report.sh: unknown argument $1" >&2; exit 2 ;;
            esac
        done
        shift
        # shellcheck disable=SC2086 # CC is the command, one word per argument
        $CC gate --package "$PKG" --repo-files "$T/repo_files" --source-root "$ROOT" "$@" \
            --ratchet "$T/ratchet.tsv" --mode census --result-out "$T/result.json" --summary-out "$T/summary.md" >"$T/log" 2>&1 ||
            red "covcheck gate exited $? over the reports: $(cat "$T/log")"
        while IFS= read -r e; do
            grep -F -- "$e" "$T/result.json" >/dev/null || red "the result JSON does not hold '$e': $(cat "$T/result.json")"
            echo "ok result holds $e" >>"$OUT"
        done <"$EXPECT"
        [ -s "$EXPECT" ] || red "census: no --expect; the result JSON: $(cat "$T/result.json")"
        ;;
    result)
        n=0
        while [ "$#" -ge 2 ] && [ "$1" = --expect ]; do
            printf '%s\n' "$2" >>"$T/expect"
            n=$((n + 1))
            shift 2
        done
        [ "$#" = 2 ] && [ "$1" = --json ] && [ "$n" -gt 0 ] || { echo "report.sh: result needs --expect <s>... --json <file>" >&2; exit 2; }
        J=$2
        while IFS= read -r e; do
            grep -F -- "$e" "$J" >/dev/null || red "the gate's result JSON does not hold '$e': $(cat "$J")"
            echo "ok result holds $e" >>"$OUT"
        done <"$T/expect"
        ;;
    *) echo "report.sh: unknown mode $MODE" >&2; exit 2 ;;
esac
rm -rf "$T"
