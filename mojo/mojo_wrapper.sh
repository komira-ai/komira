# mojo_wrapper.sh -- runs the hermetic Mojo compiler inside one build action.
#
# usage: busybox sh mojo_wrapper.sh <busybox> <compiler_dir> <zig_dir> \
#            <cc_target> -- <mojo arguments...>
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
# DT_RUNPATH `$ORIGIN/lib`, which names no path of this action. They also
# strip debug sections, since zig's C runtime objects record the sandbox as
# their compilation directory. A binary finds the toolchain's runtime
# libraries in the lib/ directory next to it (the rules' runnable output), or
# through `launch.sh` / LD_LIBRARY_PATH, which the loader searches first.
#
# Exit status: the compiler's; 2 for a toolchain or wrapper refusal; 3 when
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
# Rewrites `-Xlinker -L<dir>` / `-Xlinker -l<lib>` into plain driver flags and
# `-Xlinker --opt` into `-Wl,--opt`; other `-Xlinker` pairs pass through.
# Drops every run path (`-rpath <p>` in any spelling), then adds the one run
# path `$ORIGIN/lib` (as DT_RUNPATH) and `-Wl,--strip-debug`; see the header.
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
exec "$ZIG/zig" cc -target "$CC_TARGET" -Wl,--strip-debug -Wl,--enable-new-dtags '-Wl,-rpath,\$ORIGIN/lib' "\$@"
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
