#!/bin/sh
# One case of the run test of libkomira_native.so.1 (README.md, "One shared
# library"), run as a build action by a `komira_native_run_test` target
# (komira_native.bzl):
#   sh native_run.sh <busybox> <mojo_wrapper.sh> <compiler dir> <zig dir> <zig target> \
#       <target cpu> <watchdog idle> <watchdog sample> <prefix> <src dir> <runtime dir> \
#       <elfsyms> <case> <log> [<program> [<library>...]]
# <prefix> is laid out as a conda environment would be: lib/libkomira_native.so.1,
# lib/libkomira_native.so and lib/mojo/<package>.mojoc (or is one the packages
# were installed into). <program> (default native_run) is what R1 runs and B1
# builds; each <library> is linked after komira_native (`-l<library>`, a
# per_library archive a package ships in lib/). The case works on a
# writable copy that also holds the Mojo runtime libraries in lib/ (where an
# environment has them) and a bin/. Every compile sees only `-I <prefix>/lib/mojo`
# (and the programs in <src dir>), and links nothing komira-owned but
# `-Xlinker -L<prefix>/lib -Xlinker -lkomira_native` (and the <library>s).
#   R1   `mojo run` of <program>.mojo
#   B1   `mojo build --runpath='$ORIGIN/../lib'` of <program>.mojo into
#        <prefix>/bin, run there with LD_LIBRARY_PATH unset: the program NEEDs
#        libkomira_native.so.1 (its SONAME), has that run path and no other,
#        and finds the library through it alone
#   IR1  `mojo run` of native_interpose.mojo with `-lkomira_native`: ours is
#        loaded at start, then the system libcrypto.so.3 and libssl.so.3 are
#        dlopened RTLD_GLOBAL; fails when the worker has no system OpenSSL
#   IR2  `mojo run` of native_dlopen.mojo, linking nothing of ours: the system
#        OpenSSL is loaded first, then ours is dlopened by path (as a host
#        process such as a Python interpreter would); fails likewise
# The case passes when every command exits 0 and the program prints
# `RESULT PASS`; otherwise it fails (exit 1) with its log on stderr. The log
# is the action's output either way it passes.
set -u

abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$PWD" "$1" ;;
    esac
}

BB=$(abspath "$1")
WRAP=$(abspath "$2")
TC=$(abspath "$3")
ZIG=$(abspath "$4")
CCT=$5
CPU=$6
WDI=$7
WDS=$8
P0=$(abspath "$9")
shift 9
SRC=$(abspath "$1")
RT=$(abspath "$2")
ELFSYMS=$(abspath "$3")
CASE=$4
LOG=$(abspath "$5")
shift 5
PROG=native_run
if [ "$#" -gt 0 ]; then
    PROG=$1
    shift
fi

case "${BUCK_SCRATCH_PATH:-}" in
    "") W="$PWD/.native_run/$CASE" ;;
    /*) W="$BUCK_SCRATCH_PATH/native_run/$CASE" ;;
    *) W="$PWD/$BUCK_SCRATCH_PATH/native_run/$CASE" ;;
esac
"$BB" mkdir -p "$W/bin" "$W/out" "$W/cwd"
"$BB" --install -s "$W/bin"
PATH="$W/bin"
export PATH LC_ALL=C

exec 3>&2 > "$LOG" 2>&1
echo "=== native_run $CASE"

cp -r "$P0" "$W/prefix"
chmod -R u+w "$W/prefix"
cp "$RT"/* "$W/prefix/lib/"
mkdir -p "$W/prefix/bin"
P="$W/prefix"

failed=0
RP=""

# mojo_do <mojo args...>
mojo_do() {
    echo "CMD: mojo $*"
    [ -z "$RP" ] || echo "     runpath: $RP"
    rc=0
    sh "$WRAP" "$BB" "$TC" "$ZIG" "$CCT" ${RP:+"--runpath=$RP"} "--source-root=$SRC" \
        "--watchdog-idle-secs=$WDI" "--watchdog-sample-secs=$WDS" -- "$@" > "$W/out/mojo.log" 2>&1 || rc=$?
    cat "$W/out/mojo.log"
    echo "MOJO_RC=$rc"
    [ "$rc" = 0 ] || { failed=1; return 1; }
    grep -q '^RESULT PASS' "$W/out/mojo.log"
}

# The wrapper requires `-o <file>` and a non-empty file there afterwards;
# after the source file, `-o x` is the PROGRAM's argv, which it ignores.
run_jit() {
    printf 'placeholder\n' > "$W/placeholder"
    mojo_do run -I "$P/lib/mojo" -I "$SRC" "$@" -o "$W/placeholder" || failed=1
}

# build_into_bin <program>: build <src>/<program>.mojo into <prefix>/bin.
build_into_bin() {
    rc=0
    # shellcheck disable=SC2086 # LINK is a list of words
    mojo_do build --target-cpu "$CPU" -I "$P/lib/mojo" -I "$SRC" $LINK \
        "$SRC/$1.mojo" -o "$W/out/$1" || true
    if [ -s "$W/out/$1" ]; then
        cp "$W/out/$1" "$P/bin/$1"
        "$ELFSYMS" dynsym "$P/bin/$1" | grep -E '^(NEEDED|RUNPATH|RPATH) ' > "$W/out/dyn.txt" || true
        echo "EXE: $(tr '\n' ' ' < "$W/out/dyn.txt")"
        # The program must name the library by its SONAME and find it by the run path alone.
        grep -q -x 'NEEDED libkomira_native.so.1' "$W/out/dyn.txt" || { echo "EXE: does not NEED libkomira_native.so.1"; failed=1; }
        grep -q -x "RUNPATH $RP" "$W/out/dyn.txt" || { echo "EXE: its run path is not $RP"; failed=1; }
    else
        echo "EXE: not built"
        failed=1
    fi
}

# run_bin <program>: run <prefix>/bin/<program> with LD_LIBRARY_PATH unset.
run_bin() {
    exe=$P/bin/$1
    [ -s "$exe" ] || return 0
    echo "RUN: $exe (LD_LIBRARY_PATH unset)"
    rc=0
    (cd "$W/cwd" && env -u LD_LIBRARY_PATH "$exe" < /dev/null) > "$W/out/run.log" 2>&1 || rc=$?
    cat "$W/out/run.log"
    echo "RUN_RC=$rc"
    if [ "$rc" != 0 ] || ! grep -q '^RESULT PASS' "$W/out/run.log"; then
        failed=1
    fi
}

LINK="-Xlinker -L$P/lib -Xlinker -lkomira_native"
for l in "$@"; do
    LINK="$LINK -Xlinker -l$l"
done
case "$CASE" in
    R1)
        # shellcheck disable=SC2086 # LINK is a list of words
        run_jit $LINK "$SRC/$PROG.mojo"
        ;;
    B1)
        # shellcheck disable=SC2016 # $ORIGIN is the loader's, not the shell's
        RP='$ORIGIN/../lib'
        build_into_bin "$PROG"
        run_bin "$PROG"
        ;;
    IR1)
        # shellcheck disable=SC2086 # LINK is a list of words
        run_jit $LINK "$SRC/native_interpose.mojo"
        ;;
    IR2)
        run_jit "$SRC/native_dlopen.mojo" "$P/lib/libkomira_native.so.1"
        ;;
    *)
        echo "unknown case $CASE"
        failed=1
        ;;
esac
echo "=== native_run $CASE: $([ "$failed" = 0 ] && echo PASS || echo FAIL)"
exec 2>&3
if [ "$failed" != 0 ]; then
    cat "$LOG" >&2
    exit 1
fi
exit 0
