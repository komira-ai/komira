# case.sh -- one case of the native-code probe (EXPERIMENT; see BUCK).
#
# usage: busybox sh case.sh <busybox> <mojo_wrapper.sh> <compiler_dir> <zig_dir> \
#            <cc_target> <target_cpu> <wd_idle> <wd_sample> <prefix> <src_dir> \
#            <case> <log>
#
# <prefix> is a conda-shaped install: lib/mojo/*.mojoc, lib/libkomira_probe.a,
# lib/libkomira_probe.so.1. Every case compiles with `-I <prefix>/lib/mojo`
# only. The script ALWAYS exits 0: the result is the log (each command, its
# exit status as MOJO_RC= / RUN_RC=, and the program's output).

set -u

abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$PWD" "$1" ;;
    esac
}

BB=$(abspath "$1")
WRAP=$2
TC=$(abspath "$3")
ZIG=$4
CCT=$5
CPU=$6
WDI=$7
WDS=$8
P=$9
shift 9
SRC=$1
CASE=$2
LOG=$3

W=probe_work/$CASE
"$BB" mkdir -p "$W/bin" "$W/out"
"$BB" --install -s "$W/bin"
PATH=$(abspath "$W/bin")
export PATH

exec > "$LOG" 2>&1
echo "=================== CASE $CASE"

WRAPPER=$WRAP
RP=""

# mojo_do <link-tail or ""> <mojo args...>
mojo_do() {
    lt=$1
    shift
    echo "CMD: mojo $*"
    [ -n "$lt" ] && echo "     link tail: $lt"
    [ -n "$RP" ] && echo "     runpath: $RP"
    rc=0
    if [ -n "$lt" ]; then
        sh "$WRAPPER" "$BB" "$TC" "$ZIG" "$CCT" ${RP:+"--runpath=$RP"} "--source-root=$SRC" "--link-tail=$lt" \
            "--watchdog-idle-secs=$WDI" "--watchdog-sample-secs=$WDS" -- "$@" || rc=$?
    else
        sh "$WRAPPER" "$BB" "$TC" "$ZIG" "$CCT" ${RP:+"--runpath=$RP"} "--source-root=$SRC" \
            "--watchdog-idle-secs=$WDI" "--watchdog-sample-secs=$WDS" -- "$@" || rc=$?
    fi
    echo "MOJO_RC=$rc"
}

# run_exe <exe> <LD_LIBRARY_PATH>
run_exe() {
    if [ ! -s "$1" ]; then
        echo "RUN: skipped, $1 was not built"
        return
    fi
    echo "RUN: $1  (LD_LIBRARY_PATH=$2)"
    echo "     run path strings: $(strings -n 4 "$1" | grep ORIGIN | tr '\n' ' ')"
    rc=0
    LD_LIBRARY_PATH="$2" "$1" < /dev/null || rc=$?
    echo "RUN_RC=$rc"
}

build_static() {
    lt=$1
    shift
    mojo_do "$lt" build --target-cpu "$CPU" -I "$P/lib/mojo" "$@" "$SRC/consumer_static.mojo" -o "$W/out/consumer_static"
    [ -s "$W/out/consumer_static" ] && echo "EXE: built" || echo "EXE: not built"
}

build_dl() {
    mojo_do "" build --target-cpu "$CPU" -I "$P/lib/mojo" "$SRC/consumer_dl.mojo" -o "$W/out/consumer_dl"
    [ -s "$W/out/consumer_dl" ] && echo "EXE: built" || echo "EXE: not built"
}

# `mojo run` (the JIT). The wrapper requires `-o <file>` and a non-empty file
# there afterwards; after the source file, `-o x` is the PROGRAM's argv, which
# it ignores, so a pre-made placeholder satisfies the wrapper.
run_jit() {
    printf 'placeholder\n' > "$W/placeholder"
    mojo_do "" run -I "$P/lib/mojo" "$@" -o "$W/placeholder"
}

TCLIB=$TC/lib

# A writable copy of the prefix with the unversioned link name a conda
# package's dev files would add: lib/libkomira_probe.so (a copy of .so.1).
dev_prefix() {
    cp -r "$P" "$W/prefix"
    chmod -R u+w "$W/prefix"
    cp "$W/prefix/lib/libkomira_probe.so.1" "$W/prefix/lib/libkomira_probe.so"
}
PABS=$(abspath "$P")

echo "prefix contents:"
(cd "$P" && find . | sort | sed 's/^/  /')

case "$CASE" in
    A0)
        echo "control: no archive; the link must fail on komira_probe_answer"
        build_static ""
        run_exe "$W/out/consumer_static" "$TCLIB"
        ;;
    A0t)
        echo "A0 with zig cc -v in the link tail (prints the lld command line)"
        build_static "-v"
        ;;
    A1)
        build_static "" -Xlinker "$P/lib/libkomira_probe.a"
        run_exe "$W/out/consumer_static" "$TCLIB"
        ;;
    A2)
        build_static "" -Xlinker "-L$P/lib" -Xlinker -lkomira_probe
        run_exe "$W/out/consumer_static" "$TCLIB"
        ;;
    A1t)
        echo "A1 with zig cc -v in the link tail (zig rejects -Wl,--trace: unsupported linker arg)"
        build_static "-v" -Xlinker "$P/lib/libkomira_probe.a"
        run_exe "$W/out/consumer_static" "$TCLIB"
        ;;
    A1tf)
        echo "A1t forced to fail (a missing -l in the tail), so the compiler shows the link output"
        build_static "-v
-lkomira_probe_no_such_library" -Xlinker "$P/lib/libkomira_probe.a"
        ;;
    A3 | A3L)
        echo "-L/-l with the unversioned libkomira_probe.so present: lld takes the shared object (DT_NEEDED libkomira_probe.so.1)"
        dev_prefix
        build_static "" -Xlinker "-L$W/prefix/lib" -Xlinker -lkomira_probe
        echo "     DT_NEEDED-like strings: $(strings -n 4 "$W/out/consumer_static" 2> /dev/null | grep '^libkomira_probe' | tr '\n' ' ')"
        if [ "$CASE" = A3 ]; then
            run_exe "$W/out/consumer_static" "$TCLIB"
        else
            run_exe "$W/out/consumer_static" "$TCLIB:$(abspath "$W/prefix/lib")"
        fi
        ;;
    AR3)
        echo "mojo run -L/-l with the unversioned libkomira_probe.so present"
        dev_prefix
        run_jit -Xlinker "-L$W/prefix/lib" -Xlinker -lkomira_probe "$SRC/consumer_static.mojo"
        ;;
    AR4)
        echo "mojo run with the shared object's path as -Xlinker"
        run_jit -Xlinker "$P/lib/libkomira_probe.so.1" "$SRC/consumer_static.mojo"
        ;;
    AR0)
        echo "control: mojo run with no archive; must fail on komira_probe_answer"
        run_jit "$SRC/consumer_static.mojo"
        ;;
    AR)
        run_jit -Xlinker "$P/lib/libkomira_probe.a" "$SRC/consumer_static.mojo"
        ;;
    AR2)
        run_jit -Xlinker "-L$P/lib" -Xlinker -lkomira_probe "$SRC/consumer_static.mojo"
        ;;
    B0)
        echo "control: exe outside the prefix, only the toolchain lib on LD_LIBRARY_PATH; dlopen must fail"
        build_dl
        mkdir -p "$W/outside"
        [ -s "$W/out/consumer_dl" ] && cp "$W/out/consumer_dl" "$W/outside/consumer_dl"
        run_exe "$W/outside/consumer_dl" "$TCLIB"
        ;;
    B1)
        echo "exe at <prefix>/consumer_dl (its DT_RUNPATH \$ORIGIN/lib = <prefix>/lib); only the toolchain lib on LD_LIBRARY_PATH"
        build_dl
        cp -r "$P" "$W/prefix"
        chmod -R u+w "$W/prefix"
        [ -s "$W/out/consumer_dl" ] && cp "$W/out/consumer_dl" "$W/prefix/consumer_dl"
        run_exe "$W/prefix/consumer_dl" "$TCLIB"
        ;;
    B1bin)
        echo "exe at <prefix>/bin/consumer_dl (conda layout: \$ORIGIN/lib = <prefix>/bin/lib); only the toolchain lib on LD_LIBRARY_PATH"
        build_dl
        cp -r "$P" "$W/prefix"
        chmod -R u+w "$W/prefix"
        mkdir -p "$W/prefix/bin"
        [ -s "$W/out/consumer_dl" ] && cp "$W/out/consumer_dl" "$W/prefix/bin/consumer_dl"
        run_exe "$W/prefix/bin/consumer_dl" "$TCLIB"
        ;;
    B1binrp)
        echo "exe at <prefix>/bin/consumer_dl built with --runpath=\$ORIGIN/../lib; only the toolchain lib on LD_LIBRARY_PATH"
        RP='$ORIGIN/../lib'
        build_dl
        cp -r "$P" "$W/prefix"
        chmod -R u+w "$W/prefix"
        mkdir -p "$W/prefix/bin"
        [ -s "$W/out/consumer_dl" ] && cp "$W/out/consumer_dl" "$W/prefix/bin/consumer_dl"
        run_exe "$W/prefix/bin/consumer_dl" "$TCLIB"
        ;;
    B2)
        echo "exe outside the prefix, LD_LIBRARY_PATH = toolchain lib + <prefix>/lib (the activation-script route)"
        build_dl
        mkdir -p "$W/outside"
        [ -s "$W/out/consumer_dl" ] && cp "$W/out/consumer_dl" "$W/outside/consumer_dl"
        run_exe "$W/outside/consumer_dl" "$TCLIB:$PABS/lib"
        ;;
    BR0 | BR)
        # The wrapper fixes LD_LIBRARY_PATH to the toolchain's lib; a copy of
        # it appends $PROBE_EXTRA_LD so `mojo run` sees <prefix>/lib.
        sed 's|^LD_LIBRARY_PATH="\$TC/lib"$|LD_LIBRARY_PATH="$TC/lib${PROBE_EXTRA_LD:+:$PROBE_EXTRA_LD}"|' "$WRAP" > "$W/wrapper.sh"
        if grep -q 'PROBE_EXTRA_LD' "$W/wrapper.sh"; then
            echo "wrapper copy: LD_LIBRARY_PATH = toolchain lib + \$PROBE_EXTRA_LD"
        else
            echo "WRAPPER PATCH FAILED: the line LD_LIBRARY_PATH=\"\$TC/lib\" was not found"
        fi
        WRAPPER=$W/wrapper.sh
        if [ "$CASE" = BR ]; then
            PROBE_EXTRA_LD=$PABS/lib
            export PROBE_EXTRA_LD
            echo "PROBE_EXTRA_LD=$PROBE_EXTRA_LD"
        else
            echo "control: no prefix lib on LD_LIBRARY_PATH; dlopen must fail"
        fi
        run_jit "$SRC/consumer_dl.mojo"
        ;;
    *)
        echo "unknown case $CASE"
        ;;
esac
echo "=================== END $CASE"
exit 0
