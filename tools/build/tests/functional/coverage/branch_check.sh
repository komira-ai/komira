#!/bin/sh
# branch_check.sh -- a check of a branch coverage run's profile (test 47),
# run as a build action by cov_branch_check (defs.bzl):
#   sh branch_check.sh <busybox> <out> <llvm_dir> <profdata> <function> <count>,<count>...
#
# <llvm_dir> is toolchains/llvm_branch's tools directory (bin/llvm-profdata).
# `llvm-profdata show --counts --function=<function>` must show exactly one
# function (the option matches any name containing <function>), and its
# block counts, sorted, must be <count>,... (sorted: their order is the
# instrumentation's). Writes what it read to <out>; exits 1 naming the first
# failure.
set -euf
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail
set -o pipefail
abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
[ "$#" = 6 ] || { echo "branch_check: usage error" >&2; exit 2; }
BB=$(abs "$1")
OUT=$(abs "$2")
PD=$(abs "$3")/bin/llvm-profdata
PROF=$(abs "$4")
FN=$5
WANT=$6
case "${BUCK_SCRATCH_PATH:-}" in
    "") K="$PWD/.branch_check" ;;
    /*) K="$BUCK_SCRATCH_PATH/branch_check" ;;
    *) K="$PWD/$BUCK_SCRATCH_PATH/branch_check" ;;
esac
"$BB" mkdir -p "$K/bin"
"$BB" --install -s "$K/bin"
PATH="$K/bin"
export PATH LC_ALL=C
red() {
    echo "branch_check RED: $*" >&2
    exit 1
}
"$PD" show --counts --function="$FN" "$PROF" >"$K/show.txt" 2>&1 || red "llvm-profdata show --counts --function=$FN failed: $(head -n 2 "$K/show.txt" | tr '\n' ' ')"
grep -x "Functions shown: 1" "$K/show.txt" >/dev/null ||
    red "llvm-profdata shows $(sed -n 's/^Functions shown: //p' "$K/show.txt") function(s) named like '$FN', not exactly 1: $(grep -E '^  [^ ].*:$' "$K/show.txt" | tr '\n' ' ')"
got=$(sed -n 's/^ *Block counts: \[\(.*\)\]$/\1/p' "$K/show.txt" | tr -d ' ' | tr ',' '\n' | sort -n | tr '\n' ',')
[ "$got" = "$WANT," ] || red "the counters of $FN are '${got%,}' (sorted), not '$WANT': $(grep -E '^  [^ ].*:$' "$K/show.txt" | tr '\n' ' ')"
cp "$K/show.txt" "$OUT"
rm -rf "$K"
