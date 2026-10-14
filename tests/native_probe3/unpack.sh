#!/bin/sh
# Writes named members of pinned conda packages into one directory, as one
# build action of the `llvm_branch_unpack` rule (defs.bzl):
#   sh unpack.sh <busybox> <conda_payload> <out_dir> <name>=<package.conda>... -- <dest>=<name>/<member>...
# Each <member> of package <name> is written to <out_dir>/<dest> as a regular
# file: a member that is a symbolic link in its package is followed (within
# the package, never to an absolute path or out through `..`) and the file it
# resolves to is written. Nothing else is written. Exits 2, naming it, on a
# member that is missing or empty, a link that leaves its package, or a
# package named by no `<name>=`.
# The pinned busybox reads neither the zip64 fields nor the zstd payload of a
# `.conda`, so conda_payload (toolchains/kcov/conda_payload.zig) writes the
# payload tar first; busybox tar then extracts only the members asked for.
# Every pipeline fails when any of its stages fails (pipefail).
set -eu
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail
set -o pipefail

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
BB=$(abs "$1")
PAYLOAD=$(abs "$2")
OUT=$(abs "$3")
shift 3

# Private scratch (as in tools/build/mojo/toolchain.bzl).
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.llvm_branch_unpack" ;;
    /*) T="$BUCK_SCRATCH_PATH/llvm_branch_unpack" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/llvm_branch_unpack" ;;
esac
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
export PATH LC_ALL=C

fail() {
    echo "llvm_branch unpack: $*" >&2
    exit 2
}

# The packages: <name>=<package.conda>, each written as $T/pkg/<name>.tar.
mkdir -p "$T/pkg" "$OUT"
while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    name=${1%%=*}
    case "$name" in "" | */* | "$1") fail "bad package argument '$1'" ;; esac
    "$PAYLOAD" "$(abs "${1#*=}")" "$T/pkg/$name.tar" || fail "conda_payload failed on package $name"
    shift
done
[ $# -gt 0 ] || fail "no '--' before the members"
shift

# Extracts <member> of <tar> into <dir>, following a symbolic link to the
# file it names within the package; prints the member path of that file.
extract() {
    tar=$1
    dir=$2
    m=$3
    hops=0
    while :; do
        tar -xf "$tar" -C "$dir" "$m" 2>"$T/tar.log" || fail "$m is not a member of $(basename "$tar" .tar): $(head -n 3 "$T/tar.log")"
        [ -L "$dir/$m" ] || break
        t=$(readlink "$dir/$m")
        case "$t" in /* | ../* | */../* | *..) fail "$m is a link to '$t', outside its directory" ;; esac
        case "$m" in */*) m="${m%/*}/$t" ;; *) m=$t ;; esac
        hops=$((hops + 1))
        [ "$hops" -lt 8 ] || fail "$3: more than 8 links"
    done
    printf '%s' "$m"
}

n=0
for spec in "$@"; do
    dest=${spec%%=*}
    src=${spec#*=}
    name=${src%%/*}
    member=${src#*/}
    case "$dest" in "" | /* | *..*) fail "bad destination in '$spec'" ;; esac
    [ "$name" != "$src" ] || fail "'$spec' names no member (<dest>=<package>/<member>)"
    [ -f "$T/pkg/$name.tar" ] || fail "'$spec' names package '$name', which is not given"
    x="$T/x/$n"
    mkdir -p "$x" "$(dirname "$OUT/$dest")"
    real=$(extract "$T/pkg/$name.tar" "$x" "$member")
    [ -f "$x/$real" ] && [ -s "$x/$real" ] || fail "$name/$member is not a non-empty file"
    cp "$x/$real" "$OUT/$dest"
    n=$((n + 1))
done
[ "$n" -gt 0 ] || fail "no members named"
rm -rf "$T"
