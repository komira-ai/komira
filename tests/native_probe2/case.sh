# case.sh -- one case of native probe 2 (EXPERIMENT; see BUCK).
#
# usage: busybox sh case.sh <busybox> <mojo_wrapper.sh> <compiler_dir> <zig_dir> \
#            <cc_target> <target_cpu> <wd_idle> <wd_sample> <prefix> <src_dir> \
#            <runtime_dir> <elfsyms> <case> <log>
#
# <prefix> holds lib/libkomira_native.so{,.1}, lib/libkomira_native_leaky.so{,.1}
# and lib/mojo/*.mojoc. Each case works on a writable copy that also gets the
# Mojo runtime libraries in lib/ (where a pixi environment has them) and a
# bin/. Every compile sees only `-I <prefix>/lib/mojo`. The script ALWAYS
# exits 0: the result is the log (each command, MOJO_RC= / RUN_RC=, and the
# program's CHECK/RESULT lines).

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
P0=$9
shift 9
SRC=$1
RT=$2
ELFSYMS=$(abspath "$3")
CASE=$4
LOG=$5

W=probe_work/$CASE
"$BB" mkdir -p "$W/bin" "$W/out"
"$BB" --install -s "$W/bin"
PATH=$(abspath "$W/bin")
export PATH

exec > "$LOG" 2>&1
echo "=================== CASE $CASE"

cp -r "$P0" "$W/prefix"
chmod -R u+w "$W/prefix"
cp "$RT"/* "$W/prefix/lib/"
mkdir -p "$W/prefix/bin"
P=$(abspath "$W/prefix")
echo "prefix: $(cd "$P" && find . -type f | sort | tr '\n' ' ')"

RP=""

# mojo_do <mojo args...>
mojo_do() {
    echo "CMD: mojo $*"
    [ -n "$RP" ] && echo "     runpath: $RP"
    rc=0
    sh "$WRAP" "$BB" "$TC" "$ZIG" "$CCT" ${RP:+"--runpath=$RP"} "--source-root=$SRC" \
        "--watchdog-idle-secs=$WDI" "--watchdog-sample-secs=$WDS" -- "$@" || rc=$?
    echo "MOJO_RC=$rc"
}

# The wrapper requires `-o <file>` and a non-empty file there afterwards;
# after the source file, `-o x` is the PROGRAM's argv, which it ignores.
run_jit() {
    printf 'placeholder\n' > "$W/placeholder"
    mojo_do run -I "$P/lib/mojo" "$@" -o "$W/placeholder"
}

# build_into_bin <consumer> <link args...>: build, then place the program at <prefix>/bin.
build_into_bin() {
    c=$1
    shift
    mojo_do build --target-cpu "$CPU" -I "$P/lib/mojo" "$@" "$SRC/$c.mojo" -o "$W/out/$c"
    if [ -s "$W/out/$c" ]; then
        cp "$W/out/$c" "$P/bin/$c"
        echo "EXE: built; dynamic section: $("$ELFSYMS" dynsym "$P/bin/$c" | grep -E '^(NEEDED|RUNPATH|RPATH)' | tr '\n' ' ')"
    else
        echo "EXE: not built"
    fi
}

# run_bin <consumer>: run <prefix>/bin/<consumer> with LD_LIBRARY_PATH unset,
# then once more under LD_DEBUG=libs to show where the loader found each library.
run_bin() {
    exe=$P/bin/$1
    if [ ! -s "$exe" ]; then
        echo "RUN: skipped, $exe was not built"
        return
    fi
    echo "RUN: $exe  (LD_LIBRARY_PATH unset)"
    rc=0
    (cd "$W" && env -u LD_LIBRARY_PATH "$exe" < /dev/null) || rc=$?
    echo "RUN_RC=$rc"
    echo "loader (LD_DEBUG=libs), lines naming komira_native, libcrypto, libssl:"
    (cd "$W" && env -u LD_LIBRARY_PATH LD_DEBUG=libs "$exe" < /dev/null 2>&1 > /dev/null) |
        grep -E 'komira_native|libcrypto|libssl' | grep -E 'find library|trying file|search path|calling init' | sed 's/^ *[0-9]*: */  /' | head -20
}

LINK="-Xlinker -L$P/lib -Xlinker -lkomira_native"
LEAKY="-Xlinker -L$P/lib -Xlinker -lkomira_native_leaky"

case "$CASE" in
    R0)
        echo "control: mojo run with no -l; must fail on komira_awslc_SHA256 and the others"
        run_jit "$SRC/consumer_main.mojo"
        ;;
    R1)
        echo "(a) mojo run, -Xlinker -L<prefix>/lib -Xlinker -lkomira_native"
        run_jit $LINK "$SRC/consumer_main.mojo"
        ;;
    B0)
        echo "control: mojo build with the default run path (\$ORIGIN/lib), program in <prefix>/bin, no LD_LIBRARY_PATH; must fail to start"
        build_into_bin consumer_main $LINK
        run_bin consumer_main
        ;;
    B1)
        echo "(b) mojo build --runpath=\$ORIGIN/../lib, program in <prefix>/bin, no LD_LIBRARY_PATH"
        RP='$ORIGIN/../lib'
        build_into_bin consumer_main $LINK
        run_bin consumer_main
        ;;
    IR1)
        echo "(c) mojo run, system libcrypto.so.3/libssl.so.3 dlopened RTLD_GLOBAL first"
        run_jit $LINK "$SRC/consumer_interpose.mojo"
        ;;
    IB1)
        echo "(c) mojo build --runpath=\$ORIGIN/../lib, system libcrypto.so.3/libssl.so.3 dlopened RTLD_GLOBAL first"
        RP='$ORIGIN/../lib'
        build_into_bin consumer_interpose $LINK
        run_bin consumer_interpose
        ;;
    LR1)
        echo "control for (c): mojo run against the leaky library; the check must see interposition"
        run_jit $LEAKY "$SRC/consumer_leaky.mojo"
        ;;
    LB1)
        echo "control for (c): mojo build against the leaky library; the check must see interposition"
        RP='$ORIGIN/../lib'
        build_into_bin consumer_leaky $LEAKY
        run_bin consumer_leaky
        ;;
    LOG1)
        echo "komira_log's hidden holder accessors through the shared object: mojo run (expected to fail)"
        run_jit $LINK "$SRC/consumer_log.mojo"
        ;;
    LOG2)
        echo "komira_log's hidden holder accessors through the shared object: mojo build (expected to fail)"
        RP='$ORIGIN/../lib'
        build_into_bin consumer_log $LINK
        run_bin consumer_log
        ;;
    *)
        echo "unknown case $CASE"
        ;;
esac
echo "=================== END $CASE"
exit 0
