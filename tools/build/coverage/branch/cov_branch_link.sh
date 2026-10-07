#!/bin/sh
# cov_branch_link.sh -- links one welded test's LLVM bitcode into a test
# binary with IR profile counters, in a build action (`mojo_cov_pgo_link`,
# tools/build/mojo/coverage_branch.bzl; README.md, "cov_branch_link").
#
# usage: busybox sh <branch_dir>/cov_branch_link.sh <busybox> <compiler_dir> <zig_dir> <cc_target>
#            <bitcode> <out> [<link tail argument>...]
#
#   <branch_dir>    the link directory of a cov_branch_dir ([link]): this
#                   script, lld/ (bin/lld, the Mojo package's LLD 24) and
#                   llvm/runtime/ (the profile runtime), which it finds
#                   beside itself
#   <compiler_dir>  the Mojo compiler closure: lib/libKGENCompilerRTShared.so
#   <zig_dir>       the Mojo toolchain's link directory (zig), the one a
#                   release test links through
#   <bitcode>       the test's LLVM bitcode ([coverage][bc][<test>])
#   <link tail>     the C libraries of the test's closure, as mojo_wrapper.sh
#                   appends them to the end of a link line
#
# Steps:
#   1. lld instruments the bitcode, as an LTO link with -r at -O0 whose pass
#      pipeline is `pgo-instr-gen,instrprof,default<O0>`: a relocatable
#      object with IR profile counters. lld is the LLVM the Mojo compiler is
#      built on, so the bitcode is read by its own LLVM.
#   2. zig links that object as a release test is linked (the line zig is
#      given when `mojo build` links through mojo_wrapper.sh's `cc` shim:
#      the compiler's runtime library, `--gc-sections`, `-lm`,
#      `--strip-debug`, the one run path `$ORIGIN/lib` as DT_RUNPATH, then
#      the link tail), with the profile runtime as a whole archive. Test 47's
#      tests//functional/coverage:link_line records both lines and fails
#      when they differ by more than the profile runtime.
#   3. The binary must hold no path of this action (its working directory or
#      its scratch directory), and must be an ELF file.
#
# Why --strip-debug: nothing reads the binary's debug info. What a branch
# was in the source is read from the bitcode (the IR the profile is applied
# to, which keeps its line tables), never from the binary; and zig's C
# runtime objects record this action's directory as their compilation
# directory, which the strip removes with the rest, as in a release link.
# So no relocation (cov_zig's) is needed, and step 3 checks it.
#
# Exit status: 1 when a step fails, naming it; 2 for a usage error.
set -euf
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail
set -o pipefail

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
[ "$#" -ge 6 ] || { echo "cov_branch_link: usage error" >&2; exit 2; }
HERE=$(abs "${0%/*}")
BB=$(abs "$1")
TC=$(abs "$2")
ZIG=$(abs "$3")
TARGET=$4
BC=$(abs "$5")
OUT=$(abs "$6")
shift 6
# What is left is the link tail, paths relative to this directory.

case "${BUCK_SCRATCH_PATH:-}" in
    "") K="$PWD/.cov_branch_link" ;;
    /*) K="$BUCK_SCRATCH_PATH/cov_branch_link" ;;
    *) K="$PWD/$BUCK_SCRATCH_PATH/cov_branch_link" ;;
esac
"$BB" mkdir -p "$K/bin" "$K/home" "$K/tmp"
"$BB" --install -s "$K/bin"
PATH="$K/bin"
HOME="$K/home"
TMPDIR="$K/tmp"
ZIG_GLOBAL_CACHE_DIR="$K/zig-global"
ZIG_LOCAL_CACHE_DIR="$K/zig-local"
export PATH HOME TMPDIR ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR LC_ALL=C

red() {
    echo "BRANCH COVERAGE LINK FAILED: $*" >&2
    [ -f "$K/log" ] && { echo "--- log:" >&2; tail -n 40 "$K/log" >&2; }
    exit 1
}

LLD="$HERE/lld/bin/lld"
RT="$HERE/llvm/runtime/libclang_rt.profile-x86_64.a"
KGEN="$TC/lib/libKGENCompilerRTShared.so"
for f in "$LLD" "$RT" "$KGEN" "$ZIG/zig" "$BC"; do
    [ -s "$f" ] || { echo "cov_branch_link: $f is missing or empty" >&2; exit 2; }
done
[ "$(od -A n -t x1 -N 4 "$BC" | tr -d ' \n')" = "4243c0de" ] || red "$5 is not LLVM bitcode"

# 1. Instrument.
"$LLD" -flavor gnu -r -m elf_x86_64 "$BC" -o "$K/pg.o" --lto-O0 \
    "--lto-newpm-passes=pgo-instr-gen,instrprof,default<O0>" >"$K/log" 2>&1 ||
    red "lld could not instrument $5 (pgo-instr-gen)"

# 2. Link, as mojo_wrapper.sh's cc shim links a release test.
# shellcheck disable=SC2016 # $ORIGIN is the loader's, not the shell's
"$ZIG/zig" cc -target "$TARGET" -Wl,--strip-debug -Wl,--enable-new-dtags '-Wl,-rpath,$ORIGIN/lib' \
    "$K/pg.o" "$KGEN" -o "$OUT" -Wl,--gc-sections -lm \
    -Wl,--whole-archive "$RT" -Wl,--no-whole-archive "$@" >"$K/log" 2>&1 ||
    red "zig could not link the instrumented test with the profile runtime"

# 3. No path of this action.
[ "$(od -A n -t x1 -N 4 "$OUT" | tr -d ' \n')" = "7f454c46" ] || red "the link wrote no ELF file"
for d in "$PWD" "$K"; do
    if grep -F "$d" "$OUT" >/dev/null; then
        red "the binary holds this action's directory $d: $(strings -n 4 "$OUT" | grep -F "$d" | head -n 3 | tr '\n' ' ')"
    fi
done
rm -rf "$K"
