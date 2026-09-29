# mojo_wrapper.sh (macOS) -- runs the Mojo compiler inside one build action on
# a macOS arm64 execution host.
#
# usage: sh mojo_wrapper.sh <busybox> <compiler_dir> <link_dir> \
#            <deployment_target> -- <mojo arguments...>
#
# The same contract as ../mojo_wrapper.sh, with what differs on macOS:
#
#   <busybox>      mojo/darwin/busybox.sh: the busybox calling convention over
#                  /bin and /usr/bin of the operating system.
#   <compiler_dir> the unpacked osx-arm64 compiler closure. The compiler and
#                  its bin/lld find lib/ through their own run path
#                  (@loader_path/../lib); nothing is set for the loader.
#   <link_dir>     holds `cc` (mojo/darwin/cc: the host's /usr/bin/cc, with
#                  run paths rewritten) and `macos_sdk`, the SDK version the
#                  execution platform promises. The action refuses (exit 2) to
#                  run on a host whose SDK is another version, so a result is
#                  never filed under the wrong SDK.
#   <deployment_target>  MACOSX_DEPLOYMENT_TARGET for every link.
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
[ "$1" = "--" ] || { echo "mojo_wrapper: expected -- before compiler arguments" >&2; exit 2; }
shift

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
if [ ! -x "$LINK/cc" ] || [ ! -s "$LINK/macos_sdk" ]; then
    echo "mojo_wrapper: REFUSING: $3 must hold an executable cc and a non-empty macos_sdk" >&2
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

# ---- the host SDK is the one the platform promised -------------------------
want_sdk=$(cat "$LINK/macos_sdk")
have_sdk=$(/usr/bin/xcrun --show-sdk-version 2> /dev/null) || have_sdk=""
if [ "$have_sdk" != "$want_sdk" ]; then
    echo "mojo_wrapper: REFUSING: this host's macOS SDK is '${have_sdk:-none}', the execution platform promises '$want_sdk'" >&2
    exit 2
fi

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

rc=0
"$TC/bin/mojo" "$@" || rc=$?
if [ "$rc" = 0 ] && [ ! -s "$EXPECT" ]; then
    echo "mojo_wrapper: compiler exited 0 but $EXPECT is missing or empty" >&2
    rc=3
elif [ "$rc" = 0 ] && grep -qF "$PWD" "$EXPECT"; then
    echo "mojo_wrapper: $EXPECT contains this action's working directory ($PWD)" >&2
    rc=4
fi
rm -rf "$T"
exit "$rc"
