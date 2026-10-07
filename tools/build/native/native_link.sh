#!/bin/sh
# The link of libkomira_native.so.1 (README.md, "One shared library"), run by
# a build action of a `komira_native` target (komira_native.bzl):
#   sh native_link.sh <busybox> <zig dir> <zig target> <soname> <version.map> <out.so> <lib.a>...
# Every <lib.a> is linked whole (--whole-archive: the library holds every
# object, not only those something in it references), with
#   -Bsymbolic       the library's own references bind inside it, so no other
#                    object of the process can interpose on them;
#   --gc-sections    sections nothing exported reaches are dropped;
#   -z defs          an undefined symbol no NEEDED library defines fails the
#                    link, rather than the first program that loads it;
#   --version-script exactly the generated exports are global;
#   --strip-debug    the C runtime's debug sections name this action's
#                    working directory (as tools/build/mojo/mojo_wrapper.sh says).
# zig's C++ driver links its libc++ and libc++abi statically (snappy is C++);
# the version script makes their symbols local. A duplicate definition
# among the archives is a link error, which names it.
set -eu

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
BB=$(abs "$1")
ZIG=$(abs "$2")
TARGET=$3
SONAME=$4
MAP=$5
OUT=$6
shift 6

case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.native_link" ;;
    /*) T="$BUCK_SCRATCH_PATH/native_link" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/native_link" ;;
esac
"$BB" mkdir -p "$T/bin" "$T/zig-global" "$T/zig-local" "$T/home"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
ZIG_GLOBAL_CACHE_DIR="$T/zig-global"
ZIG_LOCAL_CACHE_DIR="$T/zig-local"
HOME="$T/home"
export PATH ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR HOME LC_ALL=C

rc=0
"$ZIG/zig" c++ -target "$TARGET" -shared -o "$OUT" \
    "-Wl,-soname,$SONAME" \
    -Wl,-Bsymbolic \
    -Wl,--gc-sections \
    -Wl,-z,defs \
    "-Wl,--version-script,$MAP" \
    -Wl,--strip-debug \
    -Wl,--whole-archive "$@" -Wl,--no-whole-archive > "$T/link.log" 2>&1 || rc=$?
if [ "$rc" != 0 ]; then
    echo "native_link RED: the link of $SONAME failed (exit $rc):" >&2
    cat "$T/link.log" >&2
    exit 1
fi
if grep -q -F "$PWD" "$OUT"; then
    echo "native_link RED: $SONAME names this action's working directory ($PWD)" >&2
    exit 1
fi
rm -rf "$T"
