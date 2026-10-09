#!/bin/sh
# check.sh -- checks of coverage binaries (test 41), run as a build action by
# cov_debug_check (defs.bzl):
#   sh check.sh <busybox> <out> <debug_relocate> hermetic|same [--name=<s>]... [--dir=<ere>]... <binary>...
#
# hermetic: each binary
#   - has a .debug_line section and holds each <s> as a whole string: the
#     file name of a library source its test calls, which only the compile's
#     line tables put there (zig's C runtime has line tables of its own, so
#     .debug_line alone does not show the compile kept any; without them a
#     binary holds the test's own file name, as the name of its compile unit,
#     but no library file's);
#   - holds a whole string matching each <ere>: the directories of the line
#     tables the pinned Mojo writes, which are relative (`tests`, and the
#     library's import name: its package is compiled from the parent of its
#     staged sources). Mojo records no compilation
#     directory, so these names stay relative to wherever the binary is read;
#   - holds a placeholder `/` + `_`...: the compilation directory of zig's C
#     runtime units (the only units that record one), relocated;
#   - holds no placeholder followed by `/` (an absolute path under the
#     working directory, a Mojo name made absolute) and no whole string that
#     is an absolute path other than the placeholder and the ELF interpreter
#     (a sandbox path, whatever the executor's directory layout; the
#     wrapper's exit 4 has already refused the action's own directory
#     anywhere in the bytes);
#   - has no compressed section: debug_relocate refuses a file with one, so a
#     run over a copy that rewrites nothing must succeed.
# same: the binaries have one sha256.
# Writes one line per binary to <out>; exits 1 naming the first failure.
set -euf
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail
set -o pipefail
abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
BB=$(abs "$1")
OUT=$(abs "$2")
RELOC=$(abs "$3")
MODE=$4
shift 4
NAMES=""
DIRS=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --name=*) NAMES="$NAMES ${1#--name=}" ;;
        --dir=*) DIRS="$DIRS ${1#--dir=}" ;;
        *) break ;;
    esac
    shift
done
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.cov_check" ;;
    /*) T="$BUCK_SCRATCH_PATH/cov_check" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/cov_check" ;;
esac
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
export PATH LC_ALL=C
[ "$#" -ge 1 ] || { echo "check.sh: no binary" >&2; exit 2; }
red() { echo "cov_debug_check RED: $*" >&2; exit 1; }
: >"$OUT"
case "$MODE" in
    hermetic)
        [ -n "$NAMES" ] || { echo "check.sh: hermetic needs a --name" >&2; exit 2; }
        for b in "$@"; do
            n=${b##*/}
            [ -s "$b" ] || red "$n: missing or empty"
            grep -aqF .debug_line "$b" || red "$n: no .debug_line section; the line tables did not reach the binary"
            strings -n 4 "$b" >"$T/strings"
            for s in $NAMES; do
                grep -qxF "$s" "$T/strings" || red "$n: no string '$s'; the compile kept no line tables"
            done
            for d in $DIRS; do
                grep -qxE "$d" "$T/strings" || red "$n: no relative directory matching '$d'; the line tables do not name the sources relative to the working directory"
            done
            grep -aqE '/_{8,}' "$b" || red "$n: no placeholder '/___...'; the C runtime's compilation directory was not relocated"
            ! grep -aqE '/_{8,}/' "$b" || red "$n: holds an absolute path under the working directory ($(grep -aoE '/_{8,}/[[:print:]]*' "$b" | head -n 1)); the line tables must name sources relative to it"
            grep -E '^/' "$T/strings" | grep -vxE '/_{8,}|/lib64/ld-linux-x86-64\.so\.2' >"$T/abs" || true
            [ ! -s "$T/abs" ] || red "$n: holds an absolute path ($(head -n 1 "$T/abs")); a coverage binary may name only the placeholder and the ELF interpreter"
            cp "$b" "$T/copy"
            "$RELOC" "$T/copy" /nonexistent/directory/name >"$T/out" 2>&1 || red "$n: debug_relocate refused it: $(cat "$T/out")"
            echo "ok $n: .debug_line, line tables naming$NAMES, relative directories$DIRS, placeholder, no absolute path, no compressed section" >>"$OUT"
        done
        ;;
    same)
        first=""
        for b in "$@"; do
            s=$(sha256sum "$b" | cut -d ' ' -f 1)
            echo "$s ${b#"$PWD"/}" >>"$OUT"
            [ -n "$first" ] || first=$s
            [ "$s" = "$first" ] || red "$(tr '\n' ';' <"$OUT") differ"
        done
        [ "$#" -ge 2 ] || red "same: needs two binaries"
        ;;
    *) echo "check.sh: unknown mode $MODE" >&2; exit 2 ;;
esac
rm -rf "$T"
