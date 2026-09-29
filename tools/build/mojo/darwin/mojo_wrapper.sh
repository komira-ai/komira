# mojo_wrapper.sh (macOS) -- runs the Mojo compiler inside one build action on
# a macOS arm64 execution host.
#
# usage: sh mojo_wrapper.sh <busybox> <compiler_dir> <link_dir> \
#            <deployment_target> [--runpath=<path>] [--source-root=<dir>] \
#            [--link-tail=<arg>...] -- <mojo arguments...>
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
#
# `--emit shared-lib` (the bundle's library) is refused: bundles are linux
# only.
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
# Exit status: the compiler's; 2 for a toolchain or wrapper refusal; 3 when
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
        *) break ;;
    esac
    shift
done
[ "$#" -gt 0 ] && [ "$1" = "--" ] || { echo "mojo_wrapper: expected -- before compiler arguments" >&2; exit 2; }
shift
for a in "$@"; do
    if [ "$a" = "shared-lib" ]; then
        echo "mojo_wrapper: REFUSING: --emit shared-lib on macOS; bundles are linux only" >&2
        exit 2
    fi
done

EXPECT=""
prev=""
for a in "$@"; do
    [ "$prev" = "-o" ] && EXPECT=$a
    prev=$a
done
[ -n "$EXPECT" ] || { echo "mojo_wrapper: no -o <output> in compiler arguments" >&2; exit 2; }

T="$PWD/.komira_action"
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
rc=0
if [ -n "$STRIP" ]; then
    SUB=$1
    shift
    "$TC/bin/mojo" "$SUB" "$STRIP" "$@" || rc=$?
else
    "$TC/bin/mojo" "$@" || rc=$?
fi
if [ "$rc" = 0 ] && [ ! -s "$EXPECT" ]; then
    echo "mojo_wrapper: compiler exited 0 but $EXPECT is missing or empty" >&2
    rc=3
elif [ "$rc" = 0 ] && grep -qF "$PWD" "$EXPECT"; then
    echo "mojo_wrapper: $EXPECT contains this action's working directory ($PWD):" >&2
    grep -aoF "$PWD" "$EXPECT" | head -n 5 >&2 || true
    rc=4
fi
rm -rf "$T"
exit "$rc"
