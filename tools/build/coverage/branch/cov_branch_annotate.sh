#!/bin/sh
# cov_branch_annotate.sh -- applies one welded test's merged branch profile
# to its LLVM bitcode and writes the annotated IR as text, in a build action
# (`mojo_cov_branch_annotate`, tools/build/mojo/coverage_branch.bzl;
# README.md, "cov_branch_annotate").
#
# usage: busybox sh <branch_dir>/cov_branch_annotate.sh <busybox> <bitcode> <profdata> <ir_out>
#
#   <branch_dir>    the annotate directory of a cov_branch_dir ([annotate]):
#                   this script and lld/ (bin/lld, the Mojo package's LLD
#                   24), which it finds beside itself
#   <bitcode>       the test's LLVM bitcode ([coverage][bc][<test>]), the
#                   bitcode its instrumented binary was made from
#   <profdata>      the merged profile of its run ([coverage][branch][<test>])
#
# Steps:
#   0. The bitcode holds no branch weights of its own (no "branch_weights"
#      metadata string): `pgo-instr-use` leaves the `!prof` it finds on a
#      branch whose block never ran, which would then read as counts.
#   1. lld reads the bitcode as cov_branch_link.sh does (an LTO link with -r
#      at -O0), with the one pass `pgo-instr-use` reading <profdata>, and
#      prints the module after that pass (`-print-after=pgo-instr-use
#      -print-module-scope`, on stderr). The pass gives every conditional
#      branch, switch and select of an instrumented function that ran its
#      `!prof !{!"branch_weights", ...}` metadata: the counts of its arms.
#      The instrumentation of cov_branch_link.sh and this pass run on the
#      same bitcode, so the profile's function hashes match it; a mismatch
#      is LLVM's warning, and fails this action (step 2), and so is a function
#      the profile does not hold (`-pgo-warn-missing-function`): a run
#      writes the counters of every instrumented function it links, zeros
#      included, so a missing one is a profile of other bitcode (or a
#      function the link dropped), not a function that never ran, and would
#      otherwise read as one.
#   2. lld's own diagnostics share the stream: any line starting `lld: `
#      (after any program name), `warning: ` or `error: ` fails the action,
#      naming it, so a profile that does not fit the bitcode (`function
#      control flow change detected (hash mismatch)`: that function's counts
#      dropped) cannot pass as branches that never ran. Then what lld printed
#      is exactly one dump: the header line `; *** IR Dump After
#      PGOInstrumentationUse on [module] ***` first, and no other header.
#   3. <ir_out> is the dump, header included, unchanged.
#
# Exit status: 1 when a step fails, naming it; 2 for a usage error.
set -euf
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail
set -o pipefail

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
[ "$#" = 4 ] || { echo "cov_branch_annotate: usage error" >&2; exit 2; }
HERE=$(abs "${0%/*}")
BB=$(abs "$1")
BC=$(abs "$2")
PROF=$(abs "$3")
OUT=$(abs "$4")

case "${BUCK_SCRATCH_PATH:-}" in
    "") K="$PWD/.cov_branch_annotate" ;;
    /*) K="$BUCK_SCRATCH_PATH/cov_branch_annotate" ;;
    *) K="$PWD/$BUCK_SCRATCH_PATH/cov_branch_annotate" ;;
esac
"$BB" mkdir -p "$K/bin" "$K/tmp"
"$BB" --install -s "$K/bin"
PATH="$K/bin"
TMPDIR="$K/tmp"
export PATH TMPDIR LC_ALL=C

HEADER="; *** IR Dump After PGOInstrumentationUse on [module] ***"

red() {
    echo "BRANCH COVERAGE ANNOTATE FAILED: $*" >&2
    exit 1
}

LLD="$HERE/lld/bin/lld"
for f in "$LLD" "$BC" "$PROF"; do
    [ -s "$f" ] || { echo "cov_branch_annotate: $f is missing or empty" >&2; exit 2; }
done
[ "$(od -A n -t x1 -N 4 "$BC" | tr -d ' \n')" = "4243c0de" ] || red "$2 is not LLVM bitcode"

# 0. No branch weights before the profile is applied. Metadata strings are
# kept as their bytes in the bitcode, one after another (so a substring).
set +e
grep -q -F branch_weights "$BC"
rc=$?
set -e
case "$rc" in
    0) red "$2 already holds branch weights before the profile is applied (a \"branch_weights\" metadata string): pgo-instr-use keeps them on branches that never ran, where they would read as counts" ;;
    1) ;;
    *) red "grep could not read $2 (exit $rc)" ;;
esac

# 1. The profile applied, the module printed after the pass.
if ! "$LLD" -flavor gnu -r -m elf_x86_64 "$BC" -o "$K/use.o" --lto-O0 \
    "--lto-newpm-passes=pgo-instr-use" -mllvm "-pgo-test-profile-file=$PROF" \
    -mllvm -pgo-warn-missing-function -mllvm -print-after=pgo-instr-use -mllvm -print-module-scope >"$K/out" 2>"$K/ir"; then
    # Its message is at the end of what it printed (the dump, if any, first).
    tail -n 20 "$K/ir" | cut -c1-300 >&2
    red "lld could not apply the profile $3 to $2 (pgo-instr-use)"
fi

# 2. No diagnostic, one dump.
if grep -E '^([^ ]*lld: |warning: |error: )' "$K/ir" >"$K/diag"; then
    red "lld reported $(grep -c . "$K/diag") diagnostic(s) applying the profile: $(head -n 5 "$K/diag" | cut -c1-300 | tr '\n' ' ')"
fi
[ ! -s "$K/out" ] || red "lld wrote to its standard output: $(head -n 3 "$K/out" | tr '\n' ' ')"
[ "$(head -n 1 "$K/ir")" = "$HEADER" ] ||
    red "lld's output does not start with the dump header '$HEADER': $(head -n 1 "$K/ir" | cut -c1-200)"
n=$(grep -c -F '; *** IR Dump ' "$K/ir" || true)
[ "$n" = 1 ] || red "lld printed $n IR dumps, expected exactly one"

# 3. The dump.
cp "$K/ir" "$OUT"
rm -rf "$K"
