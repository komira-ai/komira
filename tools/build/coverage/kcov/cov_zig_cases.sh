#!/bin/sh
# The cases of cov_zig (README.md), run as a build action by the
# `cov_zig_cases` target (defs.bzl, kcov_tool_cases):
#   sh cov_zig_cases.sh <busybox> <result.json> <cov_zig> <dir> <debug_relocate> <zig dir>
# Most cases run cov_zig in a directory whose real/zig is a stand-in that
# records its arguments and writes a given file as the link output; the last
# ones run it over the pinned zig. Exits 1 on the first wrong result, naming
# it; writes the validation result and exits 0 when every case holds.
set -eu
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail
set -o pipefail

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
BB=$(abs "$1")
RESULT=$(abs "$2")
TOOL=$(abs "$3")
RELOC=$(abs "$5")
ZIG=$(abs "$6")

case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.kcov_cases" ;;
    /*) T="$BUCK_SCRATCH_PATH/kcov_cases" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/kcov_cases" ;;
esac
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
export PATH LC_ALL=C
W="$T/work"
mkdir -p "$W"
# The zig cache of the pinned-zig cases, private to this action.
ZIG_GLOBAL_CACHE_DIR="$T/zig-global"
ZIG_LOCAL_CACHE_DIR="$T/zig-local"
HOME="$T/home"
export ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR HOME

N=0
red() {
    echo "cov_zig_cases RED: $*" >&2
    for f in "$W/out" "$W/err" "$W/argv"; do
        [ -f "$f" ] && { echo "--- ${f##*/}:" >&2; cat "$f" >&2; }
    done
    exit 1
}
pass() { N=$((N + 1)); }
run() {
    set +e
    "$@" >"$W/out" 2>"$W/err"
    RC=$?
    set -e
}
nul() { printf '\000'; }
[ "$(nul | wc -c)" -eq 1 ] || red "this shell's printf cannot write a NUL byte"

# le <bytes> <value>: <value> as <bytes> little-endian bytes.
le() {
    _n=$1 _v=$2
    while [ "$_n" -gt 0 ]; do
        # shellcheck disable=SC2059 # the format is the computed octal escape
        printf "\\$(printf '%03o' $((_v & 255)))"
        _v=$((_v >> 8))
        _n=$((_n - 1))
    done
}
[ "$(le 2 16961)" = AB ] || red "le cannot write little-endian bytes"
zeros() { _z=$1; while [ "$_z" -gt 0 ]; do nul; _z=$((_z - 1)); done; }
shdr() { le 4 "$1"; le 4 "$2"; le 8 "$3"; le 8 0; le 8 "$4"; le 8 "$5"; le 4 0; le 4 0; le 8 1; le 8 0; }
# elf <section name> <flags> <payload file>: an ELF64 file on stdout with
# three sections: null, .shstrtab, and <section name> holding the payload.
elf() {
    _sl=$((1 + 10 + ${#1} + 1))
    _pl=$(wc -c <"$3")
    printf '\177ELF'; le 1 2; le 1 1; le 1 1; zeros 9
    le 2 2; le 2 62; le 4 1; le 8 0; le 8 0; le 8 $((64 + _sl + _pl))
    le 4 0; le 2 64; le 2 0; le 2 0; le 2 64; le 2 3; le 2 1
    nul; printf '.shstrtab'; nul; printf '%s' "$1"; nul
    cat "$3"
    zeros 64
    shdr 1 3 0 64 "$_sl"
    shdr 11 1 "$2" $((64 + _sl)) "$_pl"
}

# The stand-in zig: records its arguments one per line in $W/argv, copies
# $STUB_OUT to the `-o` output (separate or joined), exits $STUB_RC.
S="$W/shim"
mkdir -p "$S/real"
cp "$TOOL" "$S/zig"
cp "$RELOC" "$S/debug_relocate"
cat >"$S/real/zig" <<EOF
#!$BB sh
: >"$W/argv"
o=""
prev=""
for a in "\$@"; do
    printf '%s\n' "\$a" >>"$W/argv"
    [ "\$prev" = -o ] && o=\$a
    case "\$a" in -o?*) o=\${a#-o} ;; esac
    prev=\$a
done
[ -n "\$o" ] && [ -n "\${STUB_OUT:-}" ] && $BB cp "\$STUB_OUT" "\$o"
exit "\${STUB_RC:-0}"
EOF
chmod +x "$S/zig" "$S/real/zig" "$S/debug_relocate"

# Each case runs in its own directory; C is its physical path, what the
# compiler records as the compilation directory.
cased() { rm -rf "${W:?}/$1"; mkdir -p "$W/$1"; cd "$W/$1"; C=$(pwd -P); }
# fixture <file> <section> <flags> <payload>: an ELF output for the stand-in.
fixture() { printf '%s' "$4" >"$W/payload"; nul >>"$W/payload"; elf "$2" "$3" "$W/payload" >"$1"; }
placeholder() { printf '/'; _i=1; while [ "$_i" -lt "${#1}" ]; do printf _; _i=$((_i + 1)); done; }

TGT=x86_64-linux-gnu.2.34
# 1. A link: -Wl,--strip-debug dropped, the two flags appended after the
# compiler's own arguments, everything else in order; the output's
# working directory rewritten to the placeholder.
cased link
fixture "$W/fx" .debug_line 0 "$C/a.mojo"
run env STUB_OUT="$W/fx" "$S/zig" cc -target "$TGT" -Wl,--strip-debug -Wl,--enable-new-dtags '-Wl,-rpath,$ORIGIN/lib' a.o -o out -lm
[ "$RC" -eq 0 ] || red "link: exit $RC, want 0"
printf '%s\n' cc -target "$TGT" -Wl,--enable-new-dtags '-Wl,-rpath,$ORIGIN/lib' a.o -o out -lm -Wl,--build-id=none -Wl,--compress-debug-sections=none >"$W/want"
cmp -s "$W/argv" "$W/want" || red "link: real/zig was given other arguments than the link's minus -Wl,--strip-debug plus the two appended flags"
grep -qF "$(placeholder "$C")/a.mojo" out || red "link: the output does not hold the placeholder of $C"
! grep -qF "$C" out || red "link: the output still holds $C"
pass

# 2. The output named joined (-oout) is relocated too.
cased joined
fixture "$W/fx" .debug_info 0 "$C"
run env STUB_OUT="$W/fx" "$S/zig" c++ a.o -oout
[ "$RC" -eq 0 ] || red "joined -o: exit $RC, want 0"
! grep -qF "$C" out || red "joined -o: the output still holds $C"
pass

# 3. A compile (-c) is not a link: the arguments reach real/zig unchanged,
# -Wl,--strip-debug included, and the output is not relocated.
cased compile
fixture "$W/fx" .debug_line 0 "$C"
run env STUB_OUT="$W/fx" "$S/zig" cc -c a.c -Wl,--strip-debug -o a.o
[ "$RC" -eq 0 ] || red "compile: exit $RC, want 0"
printf '%s\n' cc -c a.c -Wl,--strip-debug -o a.o >"$W/want"
cmp -s "$W/argv" "$W/want" || red "compile: real/zig was not given the arguments unchanged"
grep -qF "$C" a.o || red "compile: the output was relocated"
pass

# 4. Another subcommand passes through unchanged.
cased other
run "$S/zig" ar rcs lib.a -Wl,--strip-debug
[ "$RC" -eq 0 ] || red "other subcommand: exit $RC, want 0"
printf '%s\n' ar rcs lib.a -Wl,--strip-debug >"$W/want"
cmp -s "$W/argv" "$W/want" || red "other subcommand: real/zig was not given the arguments unchanged"
pass

# 5. A failed link exits with real/zig's status and relocates nothing.
cased failed
fixture "$W/fx" .debug_line 0 "$C"
run env STUB_OUT="$W/fx" STUB_RC=7 "$S/zig" cc a.o -o out
[ "$RC" -eq 7 ] || red "failed link: exit $RC, want 7"
grep -qF "$C" out || red "failed link: the output was relocated"
pass

# 6. Debug sections that do not name the working directory: exit 1. The
# DWARF names a directory nobody relocated, so the bytes would differ by
# machine.
cased elsewhere
fixture "$W/fx" .debug_line 0 /some/other/compile/dir
run env STUB_OUT="$W/fx" "$S/zig" cc a.o -o out
[ "$RC" -eq 1 ] || red "debug info elsewhere: exit $RC, want 1"
grep -qF "has debug sections but holds the working directory" "$W/err" || red "debug info elsewhere: the message does not say so"
pass

# 7. No debug section and no working directory: 0 rewrites are fine.
cased nodebug
fixture "$W/fx" .text 0 nothing
run env STUB_OUT="$W/fx" "$S/zig" cc a.o -o out
[ "$RC" -eq 0 ] || red "no debug section: exit $RC, want 0"
pass

# 8. debug_relocate's refusal fails the link: the working directory
# followed by another byte (a longer name).
cased refused
fixture "$W/fx" .debug_line 0 "${C}x"
run env STUB_OUT="$W/fx" "$S/zig" cc a.o -o out
[ "$RC" -eq 1 ] || red "relocation refused: exit $RC, want 1"
grep -qF "debug_relocate refused out (exit 1)" "$W/err" || red "relocation refused: the message does not name debug_relocate's refusal"
grep -qF "is followed by byte 0x78" "$W/err" || red "relocation refused: debug_relocate's own message is not passed on"
pass

# 9. A compressed debug section fails the link (debug_relocate refuses it).
cased compressed
fixture "$W/fx" .debug_line 2048 "$C"
run env STUB_OUT="$W/fx" "$S/zig" cc a.o -o out
[ "$RC" -eq 1 ] || red "compressed section: exit $RC, want 1"
grep -qF "SHF_COMPRESSED" "$W/err" || red "compressed section: the message does not name SHF_COMPRESSED"
pass

# 10. An output that is not ELF64: exit 1.
cased notelf
printf 'not an ELF file %s' "$C" >"$W/fx"
run env STUB_OUT="$W/fx" "$S/zig" cc a.o -o out
[ "$RC" -eq 1 ] || red "not ELF: exit $RC, want 1"
grep -qF "is not an ELF64 little-endian file" "$W/err" || red "not ELF: the message does not say so"
pass

# 11. The working directory reached through a symbolic link: $PWD (the
# logical path, which a compiler may record instead) is relocated too, and so
# is an absolute $BUCK_SCRATCH_PATH outside the working directory.
cased logical
mkdir -p "$W/scratch_elsewhere"
rm -f "$W/via_link"
ln -s "$W/logical" "$W/via_link"
cd "$W/via_link"
L=$PWD
[ "$L" != "$C" ] || red "logical: the shell's PWD is the physical path; the case cannot be made"
fixture "$W/fx" .debug_line 0 "$C"
printf '%s/b.mojo' "$L" >>"$W/fx"; nul >>"$W/fx"
printf '%s/zig/crt.c' "$W/scratch_elsewhere" >>"$W/fx"; nul >>"$W/fx"
run env STUB_OUT="$W/fx" BUCK_SCRATCH_PATH="$W/scratch_elsewhere" PWD="$L" "$S/zig" cc a.o -o out
[ "$RC" -eq 0 ] || red "logical: exit $RC, want 0"
for d in "$C" "$L" "$W/scratch_elsewhere"; do
    ! grep -qF "$d" out || red "logical: the output still holds $d"
done
pass

# 12. Only the logical spelling: the output names $PWD (the working directory
# through a symbolic link, which LLVM records when it names the same
# directory) and never the physical path. That directory was relocated, so
# the link passes: the zero-count check counts both spellings.
cased logical_only
rm -f "$W/via_link2"
ln -s "$W/logical_only" "$W/via_link2"
cd "$W/via_link2"
L=$PWD
[ "$L" != "$C" ] || red "logical only: the shell's PWD is the physical path; the case cannot be made"
fixture "$W/fx" .debug_line 0 "$L"
run env STUB_OUT="$W/fx" PWD="$L" "$S/zig" cc a.o -o out
[ "$RC" -eq 0 ] || red "logical only: exit $RC, want 0"
! grep -qF "$L" out || red "logical only: the output still holds $L"
grep -qF "$(placeholder "$L")" out || red "logical only: the output does not hold the placeholder of $L"
pass

# 13. Only the absolute $BUCK_SCRATCH_PATH, outside the working directory:
# the output names it and neither spelling of the working directory. It is
# relocated (debug_relocate counts it), but the zero-count check counts the
# working directory's spellings alone, so the link fails: a count of every
# directory given would pass it, and the runtime's DWARF could then name a
# directory nobody relocated.
cased scratch_only
mkdir -p "$W/sbx_scratch"
fixture "$W/fx" .debug_line 0 "$W/sbx_scratch/zig/crt.c"
case "$W/sbx_scratch" in "$C"/*) red "scratch only: the scratch directory is under the working directory; the case cannot be made" ;; esac
run env STUB_OUT="$W/fx" BUCK_SCRATCH_PATH="$W/sbx_scratch" PWD="$C" "$S/zig" cc a.o -o out
[ "$RC" -eq 1 ] || red "scratch only: exit $RC, want 1"
grep -qF "has debug sections but holds the working directory" "$W/err" || red "scratch only: the message does not say so"
! grep -qF "$W/sbx_scratch" out || red "scratch only: the output still holds $W/sbx_scratch (not relocated)"
pass

# 14. A link at a release optimization level is refused before real/zig
# runs: zig 0.12 then gives lld -O2 or -O3 (link/Elf.zig), which merges
# string tails, and a string that is the tail of a relocated directory would
# be rewritten with it. -O0 and -Og are Debug for zig, and a bare -O goes to
# clang without changing the mode: those links pass, and so does a compile.
for o in -O1 -O2 -O3 -O4 -Ofast -Os -Oz; do
    cased "opt$o"
    rm -f "$W/argv"
    fixture "$W/fx" .debug_line 0 "$C"
    run env STUB_OUT="$W/fx" "$S/zig" cc a.o "$o" -o out
    [ "$RC" -eq 1 ] || red "link with $o: exit $RC, want 1"
    grep -qF "optimization level $o" "$W/err" || red "link with $o: the message does not name $o"
    [ ! -e "$W/argv" ] || red "link with $o: real/zig ran"
done
for o in -O0 -Og -O; do
    cased "opt$o"
    fixture "$W/fx" .debug_line 0 "$C"
    run env STUB_OUT="$W/fx" "$S/zig" cc a.o "$o" -o out
    [ "$RC" -eq 0 ] || red "link with $o: exit $RC, want 0"
done
cased optcompile
run env STUB_OUT="$W/fx" "$S/zig" cc -c a.c -O2 -o a.o
[ "$RC" -eq 0 ] || red "compile with -O2: exit $RC, want 0 (only a link is refused)"
pass

# 15. The pinned zig, end to end, as a Mojo link uses it: a C file compiled
# with line tables (-g, -c: passed through), then linked through cov_zig with
# -Wl,--strip-debug. The binary keeps .debug_line, holds the placeholder of
# the working directory and not the directory, and has no compressed section
# (debug_relocate, which refuses one, rewrites nothing in a copy).
S2="$W/shim2"
mkdir -p "$S2"
cp "$TOOL" "$S2/zig"
cp "$RELOC" "$S2/debug_relocate"
ln -s "$ZIG" "$S2/real"
cased pinned
printf 'int value(int x) {\n    return x + 1;\n}\nint main(void) {\n    return value(-1);\n}\n' >hello.c
run "$S2/zig" cc -target "$TGT" -g -c hello.c -o hello.o
[ "$RC" -eq 0 ] || red "pinned zig: the compile exited $RC"
run "$S2/zig" cc -target "$TGT" -Wl,--strip-debug -Wl,--enable-new-dtags hello.o -o hello
[ "$RC" -eq 0 ] || red "pinned zig: the link exited $RC"
grep -qF .debug_line hello || red "pinned zig: the binary has no .debug_line"
grep -qF "$(placeholder "$C")" hello || red "pinned zig: the binary does not hold the placeholder of $C"
! grep -qF "$C" hello || red "pinned zig: the binary still holds $C"
cp hello hello.copy
run "$RELOC" hello.copy /nonexistent/directory/name
[ "$RC" -eq 0 ] || red "pinned zig: debug_relocate refused the binary (a compressed section?)"
pass

# 16. The same link through the pinned zig directly, as a release build runs
# it: no .debug_line. So case 15's line tables are cov_zig's doing.
run "$ZIG/zig" cc -target "$TGT" -Wl,--strip-debug -Wl,--enable-new-dtags hello.o -o hello_release
[ "$RC" -eq 0 ] || red "pinned zig, release: the link exited $RC"
! grep -qF .debug_line hello_release || red "pinned zig, release: the binary has .debug_line; case 15 proves nothing"
pass

cd /
rm -rf "$T"
printf '{"version": 1, "data": {"status": "success", "message": "cov_zig: %s cases passed"}}\n' "$N" >"$RESULT"
echo "cov_zig_cases GREEN: $N cases"
