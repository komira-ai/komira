# mojo_wrapper.sh -- runs the hermetic Mojo compiler inside one build action.
#
# usage: busybox sh mojo_wrapper.sh <busybox> <compiler_dir> <zig_dir> \
#            <cc_target> [--runpath=<path>] [--source-root=<dir>] \
#            [--link-tail=<arg>...] [--watchdog-idle-secs=<n>] \
#            [--watchdog-sample-secs=<n>] -- <mojo arguments...>
#
# Each --link-tail argument (a static library, or a driver flag such as
# -lc++) is appended, in order, to the END of every link line, after the
# compiler's own objects and archive. That is the position a single-pass
# linker needs for a library the Mojo code references (zig's lld does not
# depend on it). Paths stay relative to the action's working directory, where
# the compiler runs the link.
#
# --source-root names the directory the sources were staged in. The compiler
# records source file names in what it builds (for error locations); for a
# `build`, the wrapper strips "<that directory's absolute path>/" from them, so
# the output names the file by its path in the package. For a `precompile`
# (which ignores -strip-file-prefix), it runs the compiler from that
# directory's parent and names the package by its basename, so the `.mojoc`
# records `<name>/<file>.mojo` whatever the buck-out path of the action.
#
# Interpreted by the declared busybox shell; every tool it runs is an input of
# the action. It never consults the worker's PATH, and it refuses (exit 2)
# rather than falls back when the toolchain closure is incomplete.
#
# Environment it establishes for the compiler (nothing is inherited):
#   PATH               private busybox applets + the `cc` shim + compiler bin
#   MODULAR_HOME       private dir holding modular.cfg rendered against the
#                      action's own toolchain path (computed at run time, so no
#                      absolute path is part of the action key)
#   LD_LIBRARY_PATH    <compiler_dir>/lib, which also holds the pinned C++
#                      runtime (libstdc++.so.6, libgcc_s.so.1). The compiler
#                      binary finds it first through its own run path
#                      ($ORIGIN/../lib); this covers what it starts.
#   MODULAR_CACHE_DIR, TMPDIR, HOME, XDG_CACHE_HOME   private, per action
#   KGEN_CompilerRT_AsyncRT_ParallelismLevel=1, MODULAR_CRASH_REPORTING_ENABLED=false
#
# Link steps (through the `cc` shim below) drop every run path the compiler
# asks for, since it would name this action's sandbox, and set exactly one:
# DT_RUNPATH `$ORIGIN/lib` (or the `--runpath=` value, which must start
# with `$ORIGIN`), which names no path of this action. They also
# strip debug sections, since zig's C runtime objects record the sandbox as
# their compilation directory. A binary finds the toolchain's runtime
# libraries in the lib/ directory next to it (the rules' runnable output), or
# through `launch.sh` / LD_LIBRARY_PATH, which the loader searches first.
#
# The compile watchdog. The compiler can deadlock inside its own runtime (every
# thread parked, the process tree using no CPU) and then never exits; a remote
# action has no other bound than the executor's action timeout, so one wedge
# holds a worker slot for all of it. The compiler therefore runs in a session
# of its own, and every --watchdog-sample-secs (default 30) the wrapper reads
# the CPU time of its whole process tree from /proc (utime+stime+cutime+cstime
# of each live process in the compiler's session or below it by parent links,
# so a link step's children count, so does a helper reparented away from the
# compiler, and so do children already reaped). A sample in which the tree gained less than 1% of
# one CPU is idle; after --watchdog-idle-secs (default 300) of consecutive
# idle samples the wrapper kills the session and every process of the tree
# and exits 124, saying so. The compiler dies with the wrapper: a HUP, INT or
# TERM to the wrapper kills the tree before it exits (129, 130, 143), and if
# the wrapper is killed outright a tether in the compiler's session kills the
# session (see the compile step below). There is no wall-clock limit: a slow
# compile uses CPU the whole time and is never killed. --watchdog-idle-secs=0 turns the
# watchdog off. The toolchain passes both (mojo_toolchain's
# watchdog_idle_secs and watchdog_sample_secs).
#
# Exit status: the compiler's; 124 when the watchdog killed it; 129, 130 or
# 143 when the wrapper was signalled (the compiler killed first); 2 for a
# toolchain or wrapper refusal; 3 when
# the compiler exits 0 but the `-o` output is missing or empty (a zero-byte
# package is a silent failure); 4 when the output contains this action's
# working directory (the output would differ on every run and name a path
# that exists only inside this action).

set -eu

abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$PWD" "$1" ;;
    esac
}

[ "$#" -ge 5 ] || { echo "mojo_wrapper: usage error" >&2; exit 2; }
BB=$(abspath "$1")
TC=$(abspath "$2")
ZIG=$(abspath "$3")
CC_TARGET=$4
shift 4
RUNPATH='$ORIGIN/lib'
SRCROOT=""
LINK_TAIL=""
WD_IDLE=300
WD_SAMPLE=30
while [ "$#" -gt 0 ]; do
    case "$1" in
        --runpath=*)
            RUNPATH=${1#--runpath=}
            case "$RUNPATH" in
                '$ORIGIN' | '$ORIGIN/'*) ;;
                *) echo "mojo_wrapper: REFUSING: --runpath=$RUNPATH is not \$ORIGIN-relative" >&2; exit 2 ;;
            esac
            ;;
        --source-root=*) SRCROOT=$(abspath "${1#--source-root=}") ;;
        --link-tail=*)
            LINK_TAIL="$LINK_TAIL${1#--link-tail=}
"
            ;;
        --watchdog-idle-secs=*) WD_IDLE=${1#--watchdog-idle-secs=} ;;
        --watchdog-sample-secs=*) WD_SAMPLE=${1#--watchdog-sample-secs=} ;;
        *) break ;;
    esac
    shift
done
case "$WD_IDLE:$WD_SAMPLE" in
    *[!0-9:]* | :* | *:) echo "mojo_wrapper: REFUSING: watchdog seconds must be whole numbers (idle '$WD_IDLE', sample '$WD_SAMPLE')" >&2; exit 2 ;;
esac
[ "$WD_SAMPLE" -ge 1 ] || { echo "mojo_wrapper: REFUSING: --watchdog-sample-secs must be at least 1" >&2; exit 2; }
[ "$#" -gt 0 ] && [ "$1" = "--" ] || { echo "mojo_wrapper: expected -- before compiler arguments" >&2; exit 2; }
shift

EXPECT=""
prev=""
for a in "$@"; do
    [ "$prev" = "-o" ] && EXPECT=$a
    prev=$a
done
[ -n "$EXPECT" ] || { echo "mojo_wrapper: no -o <output> in compiler arguments" >&2; exit 2; }

# Private scratch. A remote action has its working directory to itself; a
# local one runs in the checkout root next to every other local action, so
# it takes the per-action scratch directory buck2 names in BUCK_SCRATCH_PATH.
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.komira_action" ;;
    /*) T="$BUCK_SCRATCH_PATH/komira" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/komira" ;;
esac
"$BB" mkdir -p "$T/bin" "$T/cc" "$T/home" "$T/tmp" "$T/cache" "$T/modular"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
export PATH

# ---- closure check ---------------------------------------------------------
if [ ! -s "$TC/CLOSURE_MANIFEST" ]; then
    echo "mojo_wrapper: REFUSING: $2/CLOSURE_MANIFEST is missing; the compiler input is not an unpacked toolchain" >&2
    exit 2
fi
missing=0
while IFS= read -r member; do
    [ -n "$member" ] || continue
    if [ ! -s "$TC/$member" ]; then
        echo "mojo_wrapper: REFUSING: toolchain member '$member' is missing or empty" >&2
        missing=1
    fi
done < "$TC/CLOSURE_MANIFEST"
[ "$missing" = 0 ] || exit 2
if [ ! -x "$ZIG/zig" ]; then
    echo "mojo_wrapper: REFUSING: C link driver $3/zig is missing" >&2
    exit 2
fi

# ---- modular.cfg, rendered for this action --------------------------------
sed "s|@@MOJO_TOOLCHAIN_ROOT@@|$TC|g" "$TC/share/max/modular.cfg" > "$T/modular/modular.cfg"
if grep -q '@@MOJO_TOOLCHAIN_ROOT@@' "$T/modular/modular.cfg"; then
    echo "mojo_wrapper: REFUSING: modular.cfg still holds the toolchain token after rendering" >&2
    exit 2
fi

# ---- cc shim: `mojo build` links through `cc` on PATH ---------------------
printf '%s' "$LINK_TAIL" > "$T/cc.link_tail"
# Rewrites `-Xlinker -L<dir>` / `-Xlinker -l<lib>` into plain driver flags and
# `-Xlinker --opt` into `-Wl,--opt`; other `-Xlinker` pairs pass through.
# Drops every run path (`-rpath <p>` in any spelling), then adds the one run
# path $RUNPATH (as DT_RUNPATH) and `-Wl,--strip-debug`; see the header.
cat > "$T/cc/cc" <<EOF
#!$BB sh
set -u
_argc=\$#
_expect_val=0
_drop_val=0
while [ "\$_argc" -gt 0 ]; do
  _a="\$1"; shift; _argc=\$((_argc - 1))
  if [ "\$_a" = "-Xlinker" ] && [ "\$_argc" -gt 0 ]; then
    _b="\$1"; shift; _argc=\$((_argc - 1))
    if [ "\$_drop_val" = 1 ]; then
      _drop_val=0; continue
    fi
    if [ "\$_expect_val" = 1 ]; then
      _expect_val=0
      set -- "\$@" "\$_a" "\$_b"; continue
    fi
    case "\$_b" in
      -rpath|--rpath|-R) _drop_val=1 ;;
      -rpath=*|--rpath=*) ;;
      -L*|-l*) set -- "\$@" "\$_b" ;;
      --*)     set -- "\$@" "-Wl,\$_b" ;;
      -*)      _expect_val=1; set -- "\$@" "\$_a" "\$_b" ;;
      *)       set -- "\$@" "\$_b" ;;
    esac
    continue
  fi
  if [ "\$_drop_val" = 1 ]; then
    _drop_val=0; continue
  fi
  case "\$_a" in
    -rpath|--rpath) _drop_val=1; continue ;;
    -Wl,-rpath,*|-Wl,-rpath=*|-Wl,--rpath,*|-Wl,--rpath=*|-Wl,-R,*) continue ;;
    -Wl,-rpath|-Wl,--rpath) _drop_val=1; continue ;;
    -Wl,-L*|-Wl,-l*) set -- "\$@" "\${_a#-Wl,}"; continue ;;
  esac
  set -- "\$@" "\$_a"
done
while IFS= read -r _l; do
  set -- "\$@" "\$_l"
done < "$T/cc.link_tail"
exec "$ZIG/zig" cc -target "$CC_TARGET" -Wl,--strip-debug -Wl,--enable-new-dtags '-Wl,-rpath,$RUNPATH' "\$@"
EOF
chmod +x "$T/cc/cc"
for n in c++ gcc g++ clang clang++; do ln -sf cc "$T/cc/$n"; done

PATH="$T/cc:$TC/bin:$T/bin"
MODULAR_HOME="$T/modular"
LD_LIBRARY_PATH="$TC/lib"
CC="$T/cc/cc"
CXX="$T/cc/c++"
MODULAR_CACHE_DIR="$T/cache"
TMPDIR="$T/tmp"
HOME="$T/home"
XDG_CACHE_HOME="$T/cache"
ZIG_GLOBAL_CACHE_DIR="$T/cache/zig-global"
ZIG_LOCAL_CACHE_DIR="$T/cache/zig-local"
KGEN_CompilerRT_AsyncRT_ParallelismLevel=1
MODULAR_CRASH_REPORTING_ENABLED=false
export PATH MODULAR_HOME LD_LIBRARY_PATH CC CXX MODULAR_CACHE_DIR TMPDIR HOME \
    XDG_CACHE_HOME ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR \
    KGEN_CompilerRT_AsyncRT_ParallelismLevel MODULAR_CRASH_REPORTING_ENABLED

SUBCMD=$1
STRIP=""
if [ -n "$SRCROOT" ] && [ "$1" = "build" ]; then
    STRIP="-strip-file-prefix=$SRCROOT/"
fi
if [ -n "$STRIP" ]; then
    SUB=$1
    shift
    set -- "$SUB" "$STRIP" "$@"
fi

# A package compile records its source files by the path it names them with,
# and `-strip-file-prefix` does not reach `precompile`. So the compiler runs
# from the parent of the staged package directory (--source-root) and is given
# the package by its basename: the `.mojoc` records `<name>/<file>.mojo`, the
# same in every working directory, buck-out isolation directory and staging
# path. The `-I` directories and the `-o` output are made absolute first.
ACTION_DIR=$PWD
RUN_IN=$ACTION_DIR
if [ -n "$SRCROOT" ] && [ "$1" = "precompile" ]; then
    RUN_IN=${SRCROOT%/*}
    n=$#
    prev=""
    for a in "$@"; do
        b=$a
        if [ "$prev" = "-o" ]; then
            b=$(abspath "$a")
        else
            case "$a" in
                -I/*) ;;
                -I*) b="-I$(abspath "${a#-I}")" ;;
                *) [ "$(abspath "$a")" != "$SRCROOT" ] || b=${SRCROOT##*/} ;;
            esac
        fi
        prev=$a
        set -- "$@" "$b"
    done
    shift "$n"
    EXPECT=$(abspath "$EXPECT")
fi
cd "$RUN_IN"

# ---- compile, under the watchdog (see the header) ---------------------------
# tree <root>: prints "<state of root> <CPU ticks of root's live process tree>"
# (root's session plus root's descendants by ppid),
# or "gone 0" once root has exited (a zombie counts as exited). Ticks are
# USER_HZ (100 per second on linux).
tree() {
    "$BB" cat /proc/[0-9]*/stat 2> /dev/null | "$BB" awk -v root="$1" -v mode="${2:-}" '
        {
            # comm (field 2) may hold spaces and parentheses: the fields
            # after it start past the last ")".
            i = 0
            while ((j = index(substr($0, i + 1), ")")) > 0) i += j
            split(substr($0, i + 2), f, " ")
            n++; pid[n] = $1; par[$1] = f[2]; st[$1] = f[1]; sid[$1] = f[4]
            t[$1] = f[12] + f[13] + f[14] + f[15]
        }
        END {
            if (mode == "pids") {
                if (!(root in st)) exit
            } else if (!(root in st) || st[root] == "Z") {
                print "gone 0"
                exit
            }
            # The tree is the session of root (the compiler leads one; a helper
            # that was reparented away, to init or a subreaper, is still in
            # it) plus the ppid descendants of root. What is sampled is exactly
            # what kill_tree kills, so a helper doing the work while root
            # waits is never read as idle.
            in_[root] = 1
            for (k = 1; k <= n; k++) if (sid[pid[k]] == root) in_[pid[k]] = 1
            do {
                grew = 0
                for (k = 1; k <= n; k++)
                    if (!(pid[k] in in_) && (par[pid[k]] in in_)) { in_[pid[k]] = 1; grew = 1 }
            } while (grew)
            if (mode == "pids") { for (p in in_) if (p + 0 > 1) print p; exit }
            tot = 0
            for (p in in_) tot += t[p]
            print st[root], tot
        }'
}

kill_tree() {
    # Stop the session and every process of the tree, so none can start
    # another; list the (now frozen) tree; kill the session and that list.
    # `tree ... pids` prints only pids above 1 (never 0, which `kill` would
    # read as this script's own process group).
    kill -s STOP "-$1" 2> /dev/null || true
    for p in $(tree "$1" pids); do kill -s STOP "$p" 2> /dev/null || true; done
    frozen=$(tree "$1" pids)
    kill -s KILL "-$1" 2> /dev/null || true
    for p in $frozen; do kill -s KILL "$p" 2> /dev/null || true; done
}

rc=0
if [ "$WD_IDLE" = 0 ]; then
    "$TC/bin/mojo" "$@" || rc=$?
else
    # setsid: the compiler leads a session of its own, so killing the session
    # also reaches a descendant whose parent has already exited. That also
    # takes it out of this wrapper's process group, so two things tie it to
    # the wrapper. A signal the wrapper can catch kills the tree at once (the
    # traps below). SIGKILL cannot be caught: a tether in the compiler's
    # session blocks reading a FIFO whose only writer is this wrapper (fd 9;
    # the session is started without it), and when the wrapper dies, however
    # it dies, the kernel closes that end, the read returns, and the tether
    # kills the session's process group. Nothing polls for it.
    "$BB" mkfifo "$T/tether"
    exec 9<> "$T/tether"
    "$BB" setsid "$BB" sh -c '
        bb=$1 fifo=$2
        shift 2
        "$@" &
        c=$!
        { "$bb" cat "$fifo" > /dev/null; "$bb" kill -s KILL 0; } &
        t=$!
        rc=0
        wait "$c" || rc=$?
        "$bb" kill "$t" 2> /dev/null
        exit "$rc"
    ' tether "$BB" "$T/tether" "$TC/bin/mojo" "$@" 9>&- &
    pid=$!
    on_signal() { kill_tree "$pid"; rm -rf "$T"; exit "$1"; }
    trap 'on_signal 129' HUP
    trap 'on_signal 130' INT
    trap 'on_signal 143' TERM
    need=$(((WD_IDLE + WD_SAMPLE - 1) / WD_SAMPLE))
    s=$(tree "$pid")
    last=${s#* }
    idle=0
    waited=0
    while [ "${s% *}" != gone ]; do
        "$BB" sleep 1 9>&-
        waited=$((waited + 1))
        s=$(tree "$pid")
        [ "${s% *}" != gone ] || break
        [ "$waited" -ge "$WD_SAMPLE" ] || continue
        waited=0
        if [ $((${s#* } - last)) -lt "$WD_SAMPLE" ]; then
            idle=$((idle + 1))
        else
            idle=0
        fi
        last=${s#* }
        if [ "$idle" -ge "$need" ]; then
            kill_tree "$pid"
            wait "$pid" 2> /dev/null || true
            echo "mojo-watchdog: killed deadlocked compiler after $((idle * WD_SAMPLE))s of zero process-tree CPU (mojo $SUBCMD, output $EXPECT); the action is safe to retry. Knobs: watchdog_idle_secs / watchdog_sample_secs of the Mojo toolchain." >&2
            rm -rf "$T"
            exit 124
        fi
    done
    wait "$pid" || rc=$?
    trap - HUP INT TERM
fi
if [ "$rc" = 0 ] && [ ! -s "$EXPECT" ]; then
    echo "mojo_wrapper: compiler exited 0 but $EXPECT is missing or empty" >&2
    rc=3
elif [ "$rc" = 0 ] && grep -qF "$ACTION_DIR" "$EXPECT"; then
    echo "mojo_wrapper: $EXPECT contains this action's working directory ($ACTION_DIR):" >&2
    strings -n 4 "$EXPECT" | grep -F "$ACTION_DIR" | head -n 5 >&2
    rc=4
fi
rm -rf "$T"
exit "$rc"
