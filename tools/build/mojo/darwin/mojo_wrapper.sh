# mojo_wrapper.sh (macOS) -- runs the Mojo compiler inside one build action on
# a macOS arm64 execution host.
#
# usage: sh mojo_wrapper.sh <busybox> <compiler_dir> <link_dir> \
#            <deployment_target> [--runpath=<path>] [--source-root=<dir>] \
#            [--link-tail=<arg>...] [--watchdog-idle-secs=<n>] \
#            [--watchdog-sample-secs=<n>] -- <mojo arguments...>
#
# The same contract as ../mojo_wrapper.sh, with what differs on macOS:
#
#   <busybox>      mojo/darwin/busybox.sh: the busybox calling convention over
#                  /bin and /usr/bin of the operating system.
#   <compiler_dir> the unpacked osx-arm64 compiler closure. The compiler
#                  finds lib/ through its own run path (@loader_path/../lib);
#                  nothing is set for the loader.
#   <link_dir>     holds `cc` (mojo/darwin/cc: the host's /usr/bin/cc, with
#                  run paths rewritten), `host_identity.sh`, and
#                  `macos_hosts`, the host identities a compile may run on
#                  (`[komira_re] darwin_macos_hosts`), one per line. The
#                  action refuses (exit 2) to run on a host whose identity
#                  (developer dir, SDK version and build, cc and ld builds, OS
#                  build; see host_identity.sh) is not listed, so a result is
#                  never filed under a host toolchain the key does not name.
#   <deployment_target>  MACOSX_DEPLOYMENT_TARGET for every link.
#   --runpath, --source-root, --link-tail   as in ../mojo_wrapper.sh; a
#                  `$ORIGIN` run path becomes `@loader_path`.
#   --watchdog-idle-secs, --watchdog-sample-secs   the compile watchdog of
#                  ../mojo_wrapper.sh, sampling ps(1) rather than /proc; see
#                  the compile step below.
#
# `--emit shared-lib` is accepted only for a C-ABI library that names itself
# for dyld (`-Xlinker -install_name`, which mojo_shared_lib passes): its
# output is a .dylib. The bundle's library, named by `-soname`, is refused:
# bundles are linux only.
#
# The system libraries and the SDK are the host's: /usr/lib, /System and the
# Command Line Tools (found by the compiler through /usr/bin/xcrun). No other
# host path is on PATH.
#
# modular.cfg's `shared_libs` asks for a run path naming the compiler's lib/
# (this action's sandbox). It is rewritten to the one run path a runnable
# directory provides, `@loader_path/lib`, plus `-S`, which keeps debug-map
# entries (naming object files inside the sandbox) out of the output. A
# package whose `shared_libs` says anything else is refused (exit 2) rather
# than guessed at.
#
# Exit status: the compiler's; 124 when the watchdog killed it; 129, 130 or
# 143 when the wrapper was signalled (the compiler killed first); 2 for a
# toolchain or wrapper refusal; 3 when
# the compiler exits 0 but the `-o` output is missing or empty; 4 when the
# output contains this action's working directory.

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
LINK=$(abspath "$3")
DEPLOYMENT_TARGET=$4
shift 4
RUNPATH='@loader_path/lib'
SRCROOT=""
LINK_TAIL=""
WD_IDLE=300
WD_SAMPLE=30
while [ "$#" -gt 0 ]; do
    case "$1" in
        --runpath=*)
            RUNPATH=${1#--runpath=}
            case "$RUNPATH" in
                '$ORIGIN') RUNPATH='@loader_path' ;;
                '$ORIGIN/'*) RUNPATH="@loader_path/${RUNPATH#\$ORIGIN/}" ;;
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
shared=0
named=0
for a in "$@"; do
    [ "$a" = "shared-lib" ] && shared=1
    [ "$a" = "-install_name" ] && named=1
done
if [ "$shared" = 1 ] && [ "$named" = 0 ]; then
    echo "mojo_wrapper: REFUSING: --emit shared-lib on macOS without -Xlinker -install_name; bundles are linux only (a C-ABI library, mojo_shared_lib, builds as a .dylib)" >&2
    exit 2
fi

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
"$BB" mkdir -p "$T/bin" "$T/home" "$T/tmp" "$T/cache" "$T/modular"
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
if [ ! -x "$LINK/cc" ] || [ ! -s "$LINK/macos_hosts" ] || [ ! -s "$LINK/host_identity.sh" ]; then
    echo "mojo_wrapper: REFUSING: $3 must hold an executable cc, host_identity.sh and a non-empty macos_hosts" >&2
    exit 2
fi

# ---- modular.cfg, rendered for this action --------------------------------
sed "s|@@MOJO_TOOLCHAIN_ROOT@@|$TC|g" "$TC/share/max/modular.cfg" > "$T/modular/modular.cfg.in"
if grep -q '@@MOJO_TOOLCHAIN_ROOT@@' "$T/modular/modular.cfg.in"; then
    echo "mojo_wrapper: REFUSING: modular.cfg still holds the toolchain token after rendering" >&2
    exit 2
fi
if [ "$(grep -c '^shared_libs = ' "$T/modular/modular.cfg.in" || true)" != 1 ] ||
    ! grep -qxF "shared_libs = -Xlinker,-rpath,-Xlinker,$TC/lib;" "$T/modular/modular.cfg.in"; then
    echo "mojo_wrapper: REFUSING: modular.cfg's shared_libs is not the one run path to the compiler's lib/" >&2
    exit 2
fi
sed 's|^shared_libs = .*|shared_libs = -Xlinker,-rpath,-Xlinker,@loader_path/lib,-Xlinker,-S;|' \
    "$T/modular/modular.cfg.in" > "$T/modular/modular.cfg"
rm -f "$T/modular/modular.cfg.in"

# ---- the host is one the action key names ----------------------------------
have_host=$(sh "$LINK/host_identity.sh") || have_host=""
if [ -z "$have_host" ] || ! grep -qxF "$have_host" "$LINK/macos_hosts"; then
    echo "mojo_wrapper: REFUSING: this host's identity is '${have_host:-unreadable}', not one of [$(tr '\n' ' ' < "$LINK/macos_hosts")] ([komira_re] darwin_macos_hosts). This host:" >&2
    sh "$LINK/host_identity.sh" --fields >&2 || true
    exit 2
fi

# ---- what the `cc` shim adds to every link ---------------------------------
printf '%s' "$LINK_TAIL" > "$T/cc.link_tail"
KOMIRA_CC_RUNPATH=$RUNPATH
KOMIRA_CC_LINK_TAIL="$T/cc.link_tail"
export KOMIRA_CC_RUNPATH KOMIRA_CC_LINK_TAIL

PATH="$LINK:$TC/bin:$T/bin"
MODULAR_HOME="$T/modular"
CC="$LINK/cc"
MACOSX_DEPLOYMENT_TARGET=$DEPLOYMENT_TARGET
MODULAR_CACHE_DIR="$T/cache"
TMPDIR="$T/tmp"
HOME="$T/home"
XDG_CACHE_HOME="$T/cache"
KGEN_CompilerRT_AsyncRT_ParallelismLevel=1
MODULAR_CRASH_REPORTING_ENABLED=false
export PATH MODULAR_HOME CC MACOSX_DEPLOYMENT_TARGET MODULAR_CACHE_DIR TMPDIR \
    HOME XDG_CACHE_HOME KGEN_CompilerRT_AsyncRT_ParallelismLevel \
    MODULAR_CRASH_REPORTING_ENABLED

STRIP=""
if [ -n "$SRCROOT" ] && [ "$1" = "build" ]; then
    STRIP="-strip-file-prefix=$SRCROOT/"
fi
SUBCMD=$1
if [ -n "$STRIP" ]; then
    shift
    set -- "$SUBCMD" "$STRIP" "$@"
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
# The same watchdog as ../mojo_wrapper.sh, read through ps(1) instead of
# /proc, and without a session (macOS has no setsid(1)): the tree is the root
# and its descendants by parent pid, each process's own CPU time (a child
# already reaped no longer counts; one that ran through a sample did).
cat > "$T/tree.sh" <<'TREE'
# tree <root> [pids]: "<state of root> <CPU ticks of root's live tree>", or
# "gone 0" once root has exited; with `pids`, the tree's pids (above 1).
tree() {
    ps -A -o pid= -o ppid= -o stat= -o time= 2> /dev/null | awk -v root="$1" -v mode="${2:-}" '
        function ticks(s,   d, i, n, a, v) {
            d = 0
            if ((i = index(s, "-")) > 0) { d = substr(s, 1, i - 1); s = substr(s, i + 1) }
            n = split(s, a, ":"); v = 0
            for (i = 1; i <= n; i++) v = v * 60 + a[i]
            return int((d * 86400 + v) * 100)
        }
        { n++; pid[n] = $1; par[$1] = $2; st[$1] = substr($3, 1, 1); t[$1] = ticks($4) }
        END {
            if (mode == "pids") {
                if (!(root in st)) exit
            } else if (!(root in st) || st[root] == "Z") {
                print "gone 0"
                exit
            }
            in_[root] = 1
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
# tether_kill <root>: from a process inside the tree (the tether, after
# exec, so $$ is its own pid): kill the rest of it.
tether_kill() {
    for p in $(tree "$1" pids); do [ "$p" = "$$" ] || kill -s KILL "$p" 2> /dev/null || true; done
}
# kill_tree <root>: stop the tree, so none of it can start another process,
# list it again, and kill that list.
kill_tree() {
    for p in $(tree "$1" pids); do kill -s STOP "$p" 2> /dev/null || true; done
    for p in $(tree "$1" pids); do kill -s KILL "$p" 2> /dev/null || true; done
}
TREE
. "$T/tree.sh"

rc=0
if [ "$WD_IDLE" = 0 ]; then
    "$TC/bin/mojo" "$@" || rc=$?
else
    # The compiler runs under a small shell (the root) that also holds a
    # tether: a read of a FIFO whose only writer is this wrapper (fd 9). The
    # traps below kill the tree when the wrapper is signalled; if it is killed
    # outright, the kernel closes its end, the read returns, and the tether
    # kills the tree it belongs to.
    mkfifo "$T/tether"
    exec 9<> "$T/tether"
    sh -c '
        lib=$1 fifo=$2
        shift 2
        "$@" &
        c=$!
        { cat "$fifo" > /dev/null; exec sh -c ". \"\$0\"; tether_kill \"\$1\"" "$lib" "$$"; } &
        t=$!
        rc=0
        wait "$c" || rc=$?
        kill "$t" 2> /dev/null || true
        exit "$rc"
    ' tether "$T/tree.sh" "$T/tether" "$TC/bin/mojo" "$@" 9>&- &
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
        sleep 1 9>&-
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
    grep -aoF "$ACTION_DIR" "$EXPECT" | head -n 5 >&2 || true
    rc=4
fi
rm -rf "$T"
exit "$rc"
