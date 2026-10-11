# case.sh -- one case of native probe 3 (PROBE, never merged; see BUCK).
#
# usage: busybox sh case.sh <busybox> <mojo_wrapper.sh> <compiler_dir> <zig_dir> \
#            <cc_target> <target_cpu> <wd_idle> <wd_sample> <env> <src_dir> \
#            <runtime_dir> <elfsyms> <case> <expect> <log>
#
# <env> holds lib/ (the owners' libkomira_<lib>_native.so.1, the holder archive
# and JIT object), lib/mojo/*.mojoc, nort/ and codecs/. Each case assembles a
# writable installed environment E from it, conda-shaped:
#   E/lib    the .so.1 files and their unversioned link names, the Mojo runtime
#            libraries, the codecs (not in DL-MISS), lib/mojo/*.mojoc;
#   E/bin    the programs a case builds, and for `mojo run` an installed mojo:
#            bin/mojo copied from the toolchain (so its $ORIGIN/../lib is E/lib),
#            the compiler's other files linked in.
# `mojo build` goes through mojo_wrapper.sh (run path --runpath=$ORIGIN/../lib);
# `mojo run` runs E/bin/mojo itself. Every program and every `mojo run` runs with
# LD_LIBRARY_PATH unset. The log holds each command, MOJO_RC= / RUN_RC=, the
# programs' CHECK/RESULT lines, and CASE_RESULT. The exit status is the
# expectation: <expect> "pass" needs CASE_RESULT PASS; "fail:<ERE>" needs
# CASE_RESULT FAIL and a log line matching <ERE>.

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
EXPECT=$5
LOG=$(abspath "$6")

case "${BUCK_SCRATCH_PATH:-}" in
    "") W=$PWD/_probe3/$CASE ;;
    /*) W=$BUCK_SCRATCH_PATH/probe3 ;;
    *) W=$PWD/$BUCK_SCRATCH_PATH/probe3 ;;
esac
"$BB" mkdir -p "$W/bin" "$W/out" "$W/run" "$W/home" "$W/tmp" "$W/mc" "$W/mh"
"$BB" --install -s "$W/bin"
PATH=$W/bin
export PATH

exec 3>&2
exec > "$LOG" 2>&1
echo "=================== CASE $CASE (expect $EXPECT)"

scrub() {
    sed "s|$E|<env>|g; s|$SRC|<src>|g; s|$TC|<compiler>|g"
}

OK=1
fail() {
    echo "FAILED: $*"
    OK=0
}

# ---- the installed environment -----------------------------------------------
E=$W/env
mkdir -p "$E/bin" "$E/lib"
E=$(realpath "$E")
cp -r "$P0/lib/." "$E/lib/"
chmod -R u+w "$E"
for f in "$E"/lib/*.so.1; do
    ln -s "$(basename "$f")" "${f%.1}"
done
cp "$RT"/* "$E/lib/"
case "$CASE" in
    DL_MISS_*) echo "env: the codecs are NOT installed" ;;
    *) cp "$P0"/codecs/* "$E/lib/" ;;
esac
chmod -R u+w "$E"
cp "$SRC"/*.pem "$W/run/"

# An installed `mojo`: the toolchain's bin/mojo copied into E/bin, so the loader
# reads its run path from E/bin; every other compiler file linked in, after what
# the environment already holds.
install_mojo() {
    cp "$TC/bin/mojo" "$E/bin/mojo"
    chmod u+w "$E/bin/mojo"
    for f in "$TC"/bin/*; do
        n=$(basename "$f")
        [ -e "$E/bin/$n" ] || ln -s "$f" "$E/bin/$n"
    done
    for f in "$TC"/lib/*; do
        n=$(basename "$f")
        if [ -e "$E/lib/$n" ] || [ -L "$E/lib/$n" ]; then
            echo "env: lib/$n is the environment's, not the compiler's"
        else
            ln -s "$f" "$E/lib/$n"
        fi
    done
    sed "s|@@MOJO_TOOLCHAIN_ROOT@@|$TC|g" "$TC/share/max/modular.cfg" > "$W/mh/modular.cfg"
    echo "mojo: $("$ELFSYMS" dynsym "$E/bin/mojo" | grep -E '^(NEEDED|RUNPATH|RPATH)' | tr '\n' ' ')"
    echo "compiler lib/ holds codecs: $(ls "$TC/lib" | grep -E '^lib(lz4|z|zstd)\.so' | tr '\n' ' ')"
}

# ---- compile and run -----------------------------------------------------------
MOJO_RC=0
RUN_RC=0

# mojo_run <args...>: E/bin/mojo run, LD_LIBRARY_PATH unset, from $W/run.
# With DEBUG=1 the loader's record (LD_DEBUG=libs) goes to $W/ld.txt.
DEBUG=0
mojo_run() {
    echo "CMD: <env>/bin/mojo run $*" | scrub
    MOJO_RC=0
    (
        cd "$W/run" || exit 2
        if [ "$DEBUG" = 1 ]; then
            exec env -u LD_LIBRARY_PATH LD_DEBUG=libs LD_DEBUG_OUTPUT="$W/ld" PATH="$E/bin:$W/bin" \
                MODULAR_HOME="$W/mh" MODULAR_CACHE_DIR="$W/mc" XDG_CACHE_HOME="$W/mc" TMPDIR="$W/tmp" HOME="$W/home" \
                KGEN_CompilerRT_AsyncRT_ParallelismLevel=1 MODULAR_CRASH_REPORTING_ENABLED=false \
                timeout 420 "$E/bin/mojo" run "$@" < /dev/null
        fi
        exec env -u LD_LIBRARY_PATH PATH="$E/bin:$W/bin" \
            MODULAR_HOME="$W/mh" MODULAR_CACHE_DIR="$W/mc" XDG_CACHE_HOME="$W/mc" TMPDIR="$W/tmp" HOME="$W/home" \
            KGEN_CompilerRT_AsyncRT_ParallelismLevel=1 MODULAR_CRASH_REPORTING_ENABLED=false \
            timeout 420 "$E/bin/mojo" run "$@" < /dev/null
    ) > "$W/mr.txt" 2>&1 || MOJO_RC=$?
    scrub < "$W/mr.txt" | head -c 20000
    echo "MOJO_RC=$MOJO_RC"
    [ "$MOJO_RC" = 0 ] || fail "mojo run exited $MOJO_RC"
}

# mojo_build <out> <args...>: through mojo_wrapper.sh into E/bin/<out>, run path
# $ORIGIN/../lib (RP overrides it, e.g. $ORIGIN for a library in E/lib).
RP='$ORIGIN/../lib'
mojo_build() {
    out=$1
    shift
    echo "CMD: mojo build $* -o <env>/bin/$out (runpath $RP)" | scrub
    MOJO_RC=0
    sh "$WRAP" "$BB" "$TC" "$ZIG" "$CCT" "--runpath=$RP" "--source-root=$SRC" \
        "--watchdog-idle-secs=$WDI" "--watchdog-sample-secs=$WDS" -- \
        build --target-cpu "$CPU" -I "$E/lib/mojo" "$@" -o "$W/out/$out" > "$W/mb.txt" 2>&1 || MOJO_RC=$?
    scrub < "$W/mb.txt" | head -c 20000
    echo "MOJO_RC=$MOJO_RC"
    if [ "$MOJO_RC" = 124 ]; then
        echo "compile watchdog (124): retrying once"
        MOJO_RC=0
        sh "$WRAP" "$BB" "$TC" "$ZIG" "$CCT" "--runpath=$RP" "--source-root=$SRC" \
            "--watchdog-idle-secs=$WDI" "--watchdog-sample-secs=$WDS" -- \
            build --target-cpu "$CPU" -I "$E/lib/mojo" "$@" -o "$W/out/$out" > "$W/mb.txt" 2>&1 || MOJO_RC=$?
        echo "MOJO_RC=$MOJO_RC"
    fi
    if [ "$MOJO_RC" = 0 ]; then
        case "$out" in
            *.so) cp "$W/out/$out" "$E/lib/$out" ;;
            *) cp "$W/out/$out" "$E/bin/$out" ;;
        esac
    else
        fail "mojo build $out exited $MOJO_RC"
    fi
}

dyn() {
    "$ELFSYMS" dynsym "$1" | grep -E '^(SONAME|NEEDED|RUNPATH|RPATH)' | tr '\n' ' '
}

# run_bin <name> <args...>: E/bin/<name>, LD_LIBRARY_PATH unset, from $W/run.
# PRE: an LD_PRELOAD value. DEBUG=1: the loader's record to $W/ld.*.
PRE=""
run_bin() {
    exe=$E/bin/$1
    shift
    if [ ! -s "$exe" ]; then
        fail "$exe was not built"
        return
    fi
    echo "EXE: $(dyn "$exe")"
    echo "RUN: <env>/bin/$(basename "$exe") $* (LD_LIBRARY_PATH unset${PRE:+, LD_PRELOAD=$PRE})" | scrub
    RUN_RC=0
    (
        cd "$W/run" || exit 2
        if [ "$DEBUG" = 1 ]; then
            exec env -u LD_LIBRARY_PATH ${PRE:+LD_PRELOAD="$PRE"} LD_DEBUG=libs LD_DEBUG_OUTPUT="$W/ld" "$exe" "$@" < /dev/null
        fi
        exec env -u LD_LIBRARY_PATH ${PRE:+LD_PRELOAD="$PRE"} "$exe" "$@" < /dev/null
    ) > "$W/run.txt" 2>&1 || RUN_RC=$?
    scrub < "$W/run.txt" | head -c 20000
    echo "RUN_RC=$RUN_RC"
}

# result_of <file>: the program's own verdict.
program_passed() {
    grep -q '^RESULT PASS' "$1"
}

# ---- the loaded-from record (DL) ---------------------------------------------
# For each codec soname: the file the loader initialised (LD_DEBUG=libs
# "calling init:"), or the last file it tried. INSIDE: under E/lib.
loaded_from() {
    cat "$W"/ld.* > "$W/ld.all" 2> /dev/null || : > "$W/ld.all"
    echo "loader record: $(wc -l < "$W/ld.all") lines"
    for s in liblz4.so.1 libz.so.1 libzstd.so.1; do
        img=""
        for d in /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu /lib64 /usr/lib64 /usr/lib /lib; do
            [ -e "$d/$s" ] && { img="$d/$s"; break; }
        done
        echo "IMAGE_COPY $s ${img:-none}"
        [ -n "$img" ] || fail "the runner image ships no $s: the case would prove nothing"
        p=$(grep -E "calling init: .*/$s\$" "$W/ld.all" | tail -1 | sed 's/.*calling init: //')
        [ -n "$p" ] || p=$(grep -E "trying file=.*/$s\$" "$W/ld.all" | tail -1 | sed 's/.*trying file=//')
        [ -n "$p" ] && [ -e "$p" ] && p=$(realpath "$p")
        grep -E "(find library=$s|trying file=.*/$s\$|search path=)" "$W/ld.all" | grep -B1 -A3 "$s" | scrub | sed "s/^ *[0-9]*: */  /" | head -12
        case "$p" in
            "") echo "LOADED_FROM $s NONE"; fail "$s: not in the loader's record" ;;
            "$E/lib/"*) echo "LOADED_FROM $s INSIDE $(echo "$p" | scrub)" ;;
            *) echo "LOADED_FROM $s OUTSIDE $(echo "$p" | scrub)"; fail "$s loaded from outside the environment" ;;
        esac
    done
}

# The owners, dependents first (the design's "Linking from Mojo").
OWNERS="http_core crypto compression async async_api metrics scan_source libc"
lflags() {
    printf '%s\n' -Xlinker "-L$E/lib"
    for o in "$@"; do
        printf '%s\n' -Xlinker "-lkomira_${o}_native"
    done
}
REVERSED="libc scan_source metrics async_api async compression crypto http_core"
WITHOUT_ASYNC="http_core crypto compression async_api metrics scan_source libc"

# shellcheck disable=SC2046 # one flag per line, no spaces in them
case "$CASE" in
    R1 | R2 | R1_MISS | IR1)
        install_mojo
        case "$CASE" in
            R2) set -- $(lflags $REVERSED) ;;
            R1_MISS) set -- $(lflags $WITHOUT_ASYNC) ;;
            *) set -- $(lflags $OWNERS) ;;
        esac
        ARG=""
        [ "$CASE" = IR1 ] && ARG=ir
        mojo_run -I "$E/lib/mojo" "$@" -Xlinker -lkomira_log_holder_jit "$SRC/r1.mojo" $ARG > "$W/r.txt"
        cat "$W/r.txt"
        program_passed "$W/r.txt" || fail "the program did not print RESULT PASS"
        ;;
    B1 | IR2 | ONE)
        mojo_build r1 $(lflags $OWNERS) -Xlinker -lkomira_log_holder "$SRC/r1.mojo"
        case "$CASE" in
            IR2) PRE="libcrypto.so.3:libssl.so.3"; run_bin r1 ir ;;
            ONE) run_bin r1 one ;;
            *) run_bin r1 ;;
        esac
        program_passed "$W/run.txt" || fail "the program did not print RESULT PASS"
        ;;
    B2 | B3)
        mojo_build b2 -Xlinker "-L$E/lib" -Xlinker -lkomira_http_core_native "$SRC/b2.mojo"
        if [ "$CASE" = B3 ]; then
            echo "B3: http_core's library replaced by the one without DT_RUNPATH: $(dyn "$P0/nort/libkomira_http_core_native.so.1")"
            cp "$P0/nort/libkomira_http_core_native.so.1" "$E/lib/libkomira_http_core_native.so.1"
        fi
        echo "http_core: $(dyn "$E/lib/libkomira_http_core_native.so.1")"
        run_bin b2
        program_passed "$W/run.txt" || fail "the program did not print RESULT PASS"
        ;;
    LOG1_R)
        install_mojo
        mojo_run -I "$E/lib/mojo" $(lflags $OWNERS) -Xlinker -lkomira_log_holder_jit "$SRC/log1.mojo" > "$W/r.txt"
        cat "$W/r.txt"
        program_passed "$W/r.txt" || fail "the program did not print RESULT PASS"
        ;;
    LOG1_B)
        mojo_build log1 $(lflags $OWNERS) -Xlinker -lkomira_log_holder "$SRC/log1.mojo"
        run_bin log1
        program_passed "$W/run.txt" || fail "the program did not print RESULT PASS"
        dyn "$E/bin/log1" | grep -q holder_jit && fail "the built program has NEEDED on the JIT object"
        ;;
    LOG2)
        RP='$ORIGIN'
        mojo_build liblog2probe.so --emit shared-lib -Xlinker -soname -Xlinker liblog2probe.so \
            $(lflags $OWNERS) -Xlinker -lkomira_log_holder "$SRC/log2_lib.mojo"
        RP='$ORIGIN/../lib'
        mojo_build log2 $(lflags $OWNERS) -Xlinker -lkomira_log_holder "$SRC/log2_main.mojo"
        echo "library: $(dyn "$E/lib/liblog2probe.so")"
        for f in "$E/lib/liblog2probe.so" "$E/bin/log2"; do
            [ -s "$f" ] || continue
            if dyn "$f" | grep -q holder_jit; then
                fail "$(basename "$f") has NEEDED on the JIT object"
            else
                echo "NO_JIT_NEEDED $(basename "$f")"
            fi
        done
        run_bin log2 "$E/lib/liblog2probe.so"
        program_passed "$W/run.txt" || fail "the program did not print RESULT PASS"
        ;;
    DL_R | DL_MISS_R)
        install_mojo
        DEBUG=1
        mojo_run -I "$E/lib/mojo" -Xlinker "-L$E/lib" -Xlinker -lkomira_compression_native "$SRC/dl.mojo" > "$W/r.txt"
        cat "$W/r.txt"
        program_passed "$W/r.txt" || fail "the program did not print RESULT PASS"
        loaded_from
        ;;
    DL_B | DL_MISS_B)
        mojo_build dl -Xlinker "-L$E/lib" -Xlinker -lkomira_compression_native "$SRC/dl.mojo"
        DEBUG=1
        run_bin dl
        program_passed "$W/run.txt" || fail "the program did not print RESULT PASS"
        loaded_from
        ;;
    *)
        fail "unknown case $CASE"
        ;;
esac

if [ "$OK" = 1 ]; then
    echo "CASE_RESULT $CASE PASS"
else
    echo "CASE_RESULT $CASE FAIL"
fi
echo "=================== END $CASE"

exec >&3 2>&3
case "$EXPECT" in
    pass)
        [ "$OK" = 1 ] && exit 0
        echo "native_probe3: $CASE expected to pass and FAILED; its log:"
        tail -c 6000 "$LOG"
        exit 1
        ;;
    fail:*)
        re=${EXPECT#fail:}
        if [ "$OK" = 0 ] && grep -Eq "$re" "$LOG"; then
            exit 0
        fi
        echo "native_probe3: $CASE expected to fail with /$re/ and did not; its log:"
        tail -c 6000 "$LOG"
        exit 1
        ;;
esac
echo "native_probe3: bad expectation $EXPECT"
exit 2
