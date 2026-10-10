#!/bin/sh
# cov_branch_run.sh -- runs one welded test's instrumented binary in a build
# action (`mojo_cov_branch_run`, tools/build/mojo/coverage_branch.bzl),
# through the release gate's runner with the gate's environment, and merges
# the raw profiles it writes into an indexed profile (README.md,
# "cov_branch_run").
#
# usage: busybox sh <branch_dir>/cov_branch_run.sh <busybox> <gate_runner> <compiler_dir> <label>
#            <test_binary> <profdata_out> [--env NAME=VALUE]...
#
#   <branch_dir>    the run directory of a cov_branch_dir ([run]): this
#                   script, llvm/ (bin/llvm-profdata) and raw_version (the
#                   raw profile version every profile must have), which it
#                   finds beside itself
#   <test_binary>   <root>/bin/<test> of the test's staged tree (the release
#                   gate's: <root>/share holds its declared data), the binary
#                   of [coverage][pgo_bin][<test>]
#   --env           the test's environment, passed to gate_runner.sh as given
#
# Steps:
#   1. gate_runner.sh (unchanged: the release gate's runner) runs the test
#      in the gate's environment (this script exports nothing to it but its
#      own PATH, which gate_runner replaces) with one more --env,
#      LLVM_PROFILE_FILE=<scratch>/prof/%p.profraw (an
#      absolute path in this action; %p is the pid, so a child the test
#      starts writes a profile of its own). The test must pass: when it
#      fails, so does this action, with the test's output and this script's
#      message (not gate_runner's banner, which says the release gate's
#      test failed: that one passed).
#   2. At least one raw profile was written there; none (the runtime was not
#      linked, the variable did not reach the test, the test left without
#      running its exit handlers) fails the action.
#   3. Each raw profile starts with the 64-bit raw magic, its version is
#      <raw_version>, and its variant flags carry the IR-instrumentation bit
#      (0x01000000), which only the instrumenter's definition of
#      __llvm_profile_raw_version sets (toolchains/llvm_branch/README.md,
#      "The version coupling"): read as check.sh's raw_version mode reads it.
#   4. llvm-profdata merges them into <profdata_out>; a refusal that is
#      LLVM's `raw profile version mismatch` says which version it expected.
#      `llvm-profdata show` must then report IR instrumentation and at least
#      one function.
#
# What differs from the release gate: the binary is the test compiled at
# -O0 and instrumented by lld (cov_branch_link.sh), not Mojo's own -O1
# build, and its environment also holds LLVM_PROFILE_FILE (the rule refuses
# a test_env that sets it). Like the gate, it waits for the test alone: a
# child still running when the test exits writes its profile after the
# merge, or never, and its counts are not in <profdata_out>. Like the gate,
# it has no time limit of its own (cov_run.sh has one): a test that hangs
# holds the action until the executor's timeout.
#
# Exit status: the test's when it fails (gate_runner's); 1 when no profile
# was written or one is refused; 2 for a usage error.
set -euf
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail
set -o pipefail

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
[ "$#" -ge 6 ] || { echo "cov_branch_run: usage error" >&2; exit 2; }
HERE=$(abs "${0%/*}")
BB=$(abs "$1")
GATE=$(abs "$2")
TC=$3
LABEL=$4
BIN=$(abs "$5")
OUT=$(abs "$6")
shift 6
# What is left is gate_runner's (--env NAME=VALUE...); it checks them.

case "${BUCK_SCRATCH_PATH:-}" in
    "") K="$PWD/.cov_branch_run" ;;
    /*) K="$BUCK_SCRATCH_PATH/cov_branch_run" ;;
    *) K="$PWD/$BUCK_SCRATCH_PATH/cov_branch_run" ;;
esac
"$BB" mkdir -p "$K/bin" "$K/prof"
"$BB" --install -s "$K/bin"
PATH="$K/bin"
# LC_ALL=C is set for this script's own tools after the test has run: the
# test gets the gate's environment, and the gate sets no LC_ALL (gate_runner
# passes on what it does not set).
export PATH

red() {
    echo "==================================================================" >&2
    echo "BRANCH COVERAGE RUN FAILED: $LABEL" >&2
    echo "$*" >&2
    echo "==================================================================" >&2
    exit 1
}

PD="$HERE/llvm/bin/llvm-profdata"
RAW=$(cat "$HERE/raw_version")
case "$RAW" in "" | 0* | *[!0-9]*) echo "cov_branch_run: $HERE/raw_version holds '$RAW', not a version" >&2; exit 2 ;; esac
[ -x "$PD" ] || { echo "cov_branch_run: $PD is missing" >&2; exit 2; }

# 1. The test, under the gate's runner.
rc=0
"$BB" sh "$GATE" "$BB" "$TC" "$LABEL" "$BIN" "$K/gate.passed" "$@" \
    --env "LLVM_PROFILE_FILE=$K/prof/%p.profraw" 2>"$K/gate.err" || rc=$?
export LC_ALL=C
if [ "$rc" != 0 ]; then
    # gate_runner's banner says the release gate's test failed, which it did
    # not (this is the branch coverage run). Its other lines, the test's
    # output among them, are kept.
    awk -v H="GATED TEST FAILED: $LABEL (exit $rc)" \
        -v P="The library's package is not produced until this test passes." '
        !done && $0 == H { held = 1; next }
        held && $0 == P { held = 0; done = 1; next }
        held { print H; held = 0 }
        { print }' "$K/gate.err" >&2
    echo "==================================================================" >&2
    echo "BRANCH COVERAGE RUN FAILED: $LABEL" >&2
    echo "The test failed instrumented for branch coverage (exit $rc). A branch coverage run builds the test at -O0, instruments it with lld and runs it with LLVM_PROFILE_FILE set; a test that passes in the release gate and fails here fails this action, and is a bug to fix." >&2
    echo "==================================================================" >&2
    exit "$rc"
fi

# 2. The raw profiles.
find "$K/prof" -type f -name '*.profraw' | sort >"$K/raws"
[ -s "$K/raws" ] ||
    red "The test passed but wrote no .profraw under $K/prof (LLVM_PROFILE_FILE): the profile runtime did not run its exit handler, or the variable did not reach the test."

# 3. Each one's magic, version and IR bit (as check.sh's raw_version mode
# reads them, toolchains/llvm_branch).
n=0
while read -r f; do
    magic=$(od -A n -t x8 -N 8 "$f" | tr -d ' \n')
    [ "$magic" = "ff6c70726f667281" ] || red "${f##*/} does not start with the 64-bit raw profile magic (got '$magic')"
    v=$(od -A n -t u4 -j 8 -N 4 "$f" | tr -d ' \n')
    flags=$(od -A n -t x4 -j 12 -N 4 "$f" | tr -d ' \n')
    [ "$v" = "$RAW" ] ||
        red "${f##*/} has raw profile version $v, not $RAW, the version the pinned llvm-profdata reads (toolchains/llvm_branch/README.md, The version coupling)."
    [ $((0x$flags & 0x01000000)) != 0 ] ||
        red "${f##*/} has variant flags 0x$flags, without the IR-instrumentation bit 0x01000000: its version word is the profile runtime's default, not the instrumenter's (toolchains/llvm_branch/README.md, The version coupling)."
    n=$((n + 1))
done <"$K/raws"

# 4. Merged; a version refusal named as one.
# shellcheck disable=SC2046 # one path per line, none holding a space (pid names)
if ! "$PD" merge -o "$OUT" $(cat "$K/raws") >"$K/merge.log" 2>&1; then
    if grep -F "raw profile version mismatch" "$K/merge.log" >/dev/null; then
        ev=$(sed -n 's/^.*; expected version = \([0-9][0-9]*\).*$/\1/p' "$K/merge.log" | sort -u | tr '\n' ' ')
        red "llvm-profdata refused a raw profile of version $RAW: it expects ${ev% }: $(head -n 2 "$K/merge.log" | tr '\n' ' ')"
    fi
    red "llvm-profdata merge failed on $n raw profile(s): $(head -n 3 "$K/merge.log" | tr '\n' ' ')"
fi
"$PD" show "$OUT" >"$K/show.txt" 2>&1 || red "llvm-profdata show failed on the merged profile: $(head -n 2 "$K/show.txt" | tr '\n' ' ')"
grep -F "Instrumentation level: IR" "$K/show.txt" >/dev/null || red "the merged profile is not an IR-instrumentation profile: $(head -n 1 "$K/show.txt")"
fns=$(sed -n 's/^Total functions: \([0-9][0-9]*\)$/\1/p' "$K/show.txt")
[ -n "$fns" ] && [ "$fns" -gt 0 ] || red "the merged profile has no function: $(tr '\n' ' ' <"$K/show.txt")"
rm -rf "$K"
