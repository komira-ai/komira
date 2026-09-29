# rustc_wrapper.sh -- runs the pinned rustc inside a build action.
#
# usage: busybox sh rustc_wrapper.sh <busybox> <sysroot> <zig_dir> <cc_target> \
#            <output> -- <rustc arguments...>
#
# <sysroot> is the unpacked toolchain (bin/rustc, lib/, lib/rustlib/<target>).
# rustc runs with --sysroot set to it, so it never looks for a standard
# library anywhere else. The environment is fixed: PATH holds only busybox
# applets, and HOME, TMPDIR and the zig caches are private to the action.
#
# Links (binaries, proc-macro libraries) go through a `cc` shim written into
# the action's private directory: `zig cc -target <cc_target>` with debug
# sections stripped (zig's C runtime objects record the action's directory).
# rustc is given the shim through `-C linker`, so no linker is searched for
# on PATH.
#
# Exit status: rustc's; 2 for a toolchain or usage refusal; 3 when rustc
# exits 0 but <output> is missing or empty; 4 when <output> contains this
# action's working directory (it would differ on every run).
set -eu

abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$PWD" "$1" ;;
    esac
}

[ "$#" -ge 6 ] || { echo "rustc_wrapper: usage error" >&2; exit 2; }
BB=$(abspath "$1")
SYSROOT=$(abspath "$2")
ZIG=$(abspath "$3")
CC_TARGET=$4
OUTPUT=$5
shift 5
[ "$1" = "--" ] || { echo "rustc_wrapper: expected -- before rustc arguments" >&2; exit 2; }
shift

if [ ! -x "$SYSROOT/bin/rustc" ]; then
    echo "rustc_wrapper: REFUSING: $SYSROOT/bin/rustc is missing" >&2
    exit 2
fi
if [ ! -x "$ZIG/zig" ]; then
    echo "rustc_wrapper: REFUSING: link driver $ZIG/zig is missing" >&2
    exit 2
fi

# Private scratch. A remote action has its working directory to itself; a
# local one runs in the checkout root next to every other local action, so
# it takes the per-action scratch directory buck2 names in BUCK_SCRATCH_PATH.
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.komira_rustc" ;;
    /*) T="$BUCK_SCRATCH_PATH/komira" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/komira" ;;
esac
"$BB" mkdir -p "$T/bin" "$T/cc" "$T/home" "$T/tmp" "$T/cache"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
export PATH

cat > "$T/cc/cc" <<EOF
#!$BB sh
exec "$ZIG/zig" cc -target "$CC_TARGET" -Wl,--strip-debug "\$@"
EOF
chmod +x "$T/cc/cc"

HOME="$T/home"
TMPDIR="$T/tmp"
XDG_CACHE_HOME="$T/cache"
ZIG_GLOBAL_CACHE_DIR="$T/cache/zig-global"
ZIG_LOCAL_CACHE_DIR="$T/cache/zig-local"
export HOME TMPDIR XDG_CACHE_HOME ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR
unset LD_LIBRARY_PATH LD_PRELOAD RUSTFLAGS RUSTC_BOOTSTRAP || true

rc=0
# The working directory differs per action; rustc records it (the crate's
# working_dir) unless it is remapped.
"$SYSROOT/bin/rustc" --sysroot "$SYSROOT" -C "linker=$T/cc/cc" \
    "--remap-path-prefix=$PWD=." "$@" || rc=$?
if [ "$rc" = 0 ] && [ ! -s "$OUTPUT" ]; then
    echo "rustc_wrapper: rustc exited 0 but $OUTPUT is missing or empty" >&2
    rc=3
elif [ "$rc" = 0 ] && grep -qF "$PWD" "$OUTPUT"; then
    echo "rustc_wrapper: $OUTPUT contains this action's working directory ($PWD)" >&2
    rc=4
fi
rm -rf "$T"
exit "$rc"
