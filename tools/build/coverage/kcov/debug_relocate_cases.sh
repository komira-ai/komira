#!/bin/sh
# The cases of debug_relocate (README.md), run as a build action by the
# `debug_relocate_cases` target (defs.bzl, kcov_tool_cases):
#   sh debug_relocate_cases.sh <busybox> <result.json> <debug_relocate> <dir>
# Exits 1 on the first wrong result, naming it; writes the validation result
# and exits 0 when every case holds. The paths are made up.
set -eu
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail
set -o pipefail

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
BB=$(abs "$1")
RESULT=$(abs "$2")
TOOL=$(abs "$3")

# Private scratch (as in tools/build/mojo/toolchain.bzl): a local action runs
# in the checkout root, so it takes the directory buck2 names for it.
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

N=0
red() {
    echo "debug_relocate_cases RED: $*" >&2
    for f in "$W/out" "$W/err"; do
        [ -f "$f" ] && { echo "--- ${f##*/}:" >&2; cat "$f" >&2; }
    done
    exit 1
}
pass() { N=$((N + 1)); }

# run <cmd>...: runs it with stdout in $W/out and stderr in $W/err, status in RC.
run() {
    set +e
    "$@" >"$W/out" 2>"$W/err"
    RC=$?
    set -e
}

nul() { printf '\000'; }
[ "$(nul | wc -c)" -eq 1 ] || red "this shell's printf cannot write a NUL byte"

# A made-up sandbox directory (35 bytes) and its placeholder: '/' and 34 '_'.
D=/worker/build/0123456789abcdef/root
P=/__________________________________
[ "${#D}" -eq 35 ] && [ "${#P}" -eq 35 ] || red "the fixture paths are not both 35 bytes"
# A second directory (18 bytes) and its placeholder.
D2=/var/scratch/act42
P2=/_________________
[ "${#D2}" -eq 18 ] && [ "${#P2}" -eq 18 ] || red "the second fixture paths are not both 18 bytes"

# same <file> <expected>: byte for byte, and the same length.
same() {
    [ "$(wc -c <"$1")" -eq "$(wc -c <"$2")" ] || red "$3: length changed ($(wc -c <"$2") -> $(wc -c <"$1"))"
    cmp -s "$1" "$2" || red "$3: bytes differ from the expected file"
}

# 1. An occurrence followed by NUL is rewritten (a DW_AT_comp_dir string).
{ printf 'A%s' "$D"; nul; printf 'B'; } >"$W/f"
{ printf 'A%s' "$P"; nul; printf 'B'; } >"$W/want"
run "$TOOL" "$W/f" "$D"
[ "$RC" -eq 0 ] || red "followed by NUL: exit $RC, want 0"
[ "$(cat "$W/out")" = "1 $D" ] || red "followed by NUL: stdout '$(cat "$W/out")', want '1 $D'"
same "$W/f" "$W/want" "followed by NUL"
pass

# 2. An occurrence followed by '/' is rewritten (a file path under it).
{ printf 'x%s/buck-out/a.mojo' "$D"; nul; } >"$W/f"
{ printf 'x%s/buck-out/a.mojo' "$P"; nul; } >"$W/want"
run "$TOOL" "$W/f" "$D"
[ "$RC" -eq 0 ] || red "followed by '/': exit $RC, want 0"
[ "$(cat "$W/out")" = "1 $D" ] || red "followed by '/': stdout '$(cat "$W/out")', want '1 $D'"
same "$W/f" "$W/want" "followed by '/'"
pass

# 3. An occurrence followed by another byte ('x': the longer name /rootx) is
# refused with exit 1 and its offset, and the file keeps every byte, the
# rewritable occurrence before it included.
{ printf '%s/ok' "$D"; nul; printf '%sx' "$D"; nul; } >"$W/f"
cp "$W/f" "$W/want"
run "$TOOL" "$W/f" "$D"
[ "$RC" -eq 1 ] || red "followed by 'x': exit $RC, want 1"
grep -q "at offset 39 is followed by byte 0x78" "$W/err" || red "followed by 'x': the message does not name offset 39 and byte 0x78"
same "$W/f" "$W/want" "followed by 'x' (must be untouched)"
pass

# 4. An occurrence that ends the file is refused the same way.
{ printf 'A'; nul; printf '%s' "$D"; } >"$W/f"
cp "$W/f" "$W/want"
run "$TOOL" "$W/f" "$D"
[ "$RC" -eq 1 ] || red "at the end of the file: exit $RC, want 1"
grep -q "at offset 2 ends the file" "$W/err" || red "at the end of the file: the message does not name offset 2"
same "$W/f" "$W/want" "at the end of the file (must be untouched)"
pass

# 5. Several occurrences of several directories, each counted; the
# permission bits are kept through the rename, other-write included, which a
# usual umask (022) would clear from a file created with them.
{ printf '%s' "$D"; nul; printf '%s/f' "$D2"; nul; printf '%s/g' "$D"; nul; printf '%s' "$D2"; nul; } >"$W/f"
{ printf '%s' "$P"; nul; printf '%s/f' "$P2"; nul; printf '%s/g' "$P"; nul; printf '%s' "$P2"; nul; } >"$W/want"
chmod 757 "$W/f"
run "$TOOL" "$W/f" "$D" "$D2"
[ "$RC" -eq 0 ] || red "two directories: exit $RC, want 0"
printf '2 %s\n2 %s\n' "$D" "$D2" >"$W/want_out"
cmp -s "$W/out" "$W/want_out" || red "two directories: stdout differs from '2 $D' and '2 $D2'"
same "$W/f" "$W/want" "two directories"
[ "$(stat -c %a "$W/f")" = 757 ] || red "two directories: mode $(stat -c %a "$W/f"), want 757"
pass

# 6. A directory under 8 bytes (7: one under the floor), a relative one, one
# ending in '/', and no directory at all are bad usage: exit 2, the file
# untouched.
printf '/a/b/c/' >"$W/f"
cp "$W/f" "$W/want"
for bad in /a/b/cd a/b/c/d/e/f "$D/"; do
    run "$TOOL" "$W/f" "$bad"
    [ "$RC" -eq 2 ] || red "directory '$bad': exit $RC, want 2"
    grep -q '^usage: debug_relocate' "$W/err" || red "directory '$bad': no usage line"
    same "$W/f" "$W/want" "directory '$bad' (must be untouched)"
done
run "$TOOL" "$W/f"
[ "$RC" -eq 2 ] || red "no directory: exit $RC, want 2"
pass

# 7. A directory of exactly 8 bytes is accepted: the floor is 8, not 9.
{ printf '/a/b/c/d/e'; nul; } >"$W/f"
{ printf '/_______/e'; nul; } >"$W/want"
run "$TOOL" "$W/f" /a/b/c/d
[ "$RC" -eq 0 ] || red "8-byte directory: exit $RC, want 0"
[ "$(cat "$W/out")" = "1 /a/b/c/d" ] || red "8-byte directory: stdout '$(cat "$W/out")', want '1 /a/b/c/d'"
same "$W/f" "$W/want" "8-byte directory"
pass

# 8. A file with no occurrence: 0 rewrites, exit 0, the bytes unchanged, and
# the file not written at all: the same inode (a rename would give a new one).
{ printf 'no sandbox path here'; nul; printf '/worker/build/'; nul; } >"$W/f"
cp "$W/f" "$W/want"
ino=$(stat -c %i "$W/f")
run "$TOOL" "$W/f" "$D"
[ "$RC" -eq 0 ] || red "no occurrence: exit $RC, want 0"
[ "$(cat "$W/out")" = "0 $D" ] || red "no occurrence: stdout '$(cat "$W/out")', want '0 $D'"
same "$W/f" "$W/want" "no occurrence"
[ "$(stat -c %i "$W/f")" = "$ino" ] || red "no occurrence: the file was replaced (inode $ino -> $(stat -c %i "$W/f")), want it not written"
pass

# 9. The second directory refused after the first had rewritable occurrences:
# exit 1 naming the second's offset, nothing printed, the file untouched.
{ printf '%s/ok' "$D"; nul; printf '%sx' "$D2"; nul; } >"$W/f"
cp "$W/f" "$W/want"
run "$TOOL" "$W/f" "$D" "$D2"
[ "$RC" -eq 1 ] || red "second directory refused: exit $RC, want 1"
grep -qF "$D2 at offset 39 is followed by byte 0x78" "$W/err" || red "second directory refused: the message does not name $D2 at offset 39"
[ ! -s "$W/out" ] || red "second directory refused: counts were printed"
same "$W/f" "$W/want" "second directory refused (must be untouched)"
pass

# 10. A symbolic link is refused: replacing it through a rename would turn the
# link into a regular file and leave its target as it was.
{ printf '%s' "$D"; nul; } >"$W/target"
cp "$W/target" "$W/want"
rm -f "$W/link"
ln -s target "$W/link"
run "$TOOL" "$W/link" "$D"
[ "$RC" -eq 1 ] || red "symbolic link: exit $RC, want 1"
grep -qF "is a symbolic link" "$W/err" || red "symbolic link: the message does not say 'is a symbolic link'"
[ -L "$W/link" ] || red "symbolic link: the link was replaced"
same "$W/target" "$W/want" "symbolic link's target (must be untouched)"
pass

# The next cases make a write fail with EFBIG: a file size limit (ulimit -f,
# blocks of 512 or 1024 bytes) with SIGXFSZ ignored, which the tool inherits.
# A 72 KiB file is over the limit either way; check the shell does it first.
{ printf '%s' "$D"; nul; } >"$W/big"
for _ in 1 2 3 4 5 6 7 8 9 10 11; do cat "$W/big" "$W/big" >"$W/big2"; mv "$W/big2" "$W/big"; done
[ "$(wc -c <"$W/big")" -eq 73728 ] || red "the 72 KiB fixture is $(wc -c <"$W/big") bytes"
set +e
(trap '' XFSZ; ulimit -f 1; exec cat "$W/big") >"$W/probe" 2>"$W/err"
RC=$?
set -e
[ "$RC" -ne 0 ] && [ "$RC" -lt 128 ] || red "probe: cat over the size limit exited $RC, want an error status (not a signal)"
[ "$(wc -c <"$W/probe")" -lt 73728 ] || red "probe: the size limit did not stop the write"

# 11. A write that fails part way leaves the file untouched and no temporary
# file behind (exit 1).
mkdir -p "$W/leak"
cp "$W/big" "$W/leak/f"
set +e
(trap '' XFSZ; ulimit -f 1; exec "$TOOL" "$W/leak/f" "$D") >"$W/out" 2>"$W/err"
RC=$?
set -e
[ "$RC" -eq 1 ] || red "failed write: exit $RC, want 1"
same "$W/leak/f" "$W/big" "failed write (must be untouched)"
[ "$(ls -A "$W/leak")" = f ] || red "failed write: the directory holds '$(ls -A "$W/leak" | tr '\n' ' ')', want only 'f' (a temporary file was left)"
pass

# 12. Exit 1 means the file is unchanged: a failed write of the counts (stdout
# appended to a file over the size limit) leaves it as it was.
{ printf '%s' "$D"; nul; } >"$W/f"
cp "$W/f" "$W/want"
cp "$W/big" "$W/stdout"
set +e
(trap '' XFSZ; ulimit -f 1; exec "$TOOL" "$W/f" "$D") >>"$W/stdout" 2>"$W/err"
RC=$?
set -e
[ "$RC" -eq 1 ] || red "failed stdout: exit $RC, want 1"
same "$W/f" "$W/want" "failed stdout (must be untouched)"
pass

# The next cases are ELF files, written byte by byte: a 64-byte ELF64
# little-endian header, then .shstrtab, then one section holding "$D" and a
# NUL, then three section headers (null, .shstrtab, .debug_line).
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
# shdr <name> <type> <flags> <offset> <size>: one ELF64 section header.
shdr() { le 4 "$1"; le 4 "$2"; le 8 "$3"; le 8 0; le 8 "$4"; le 8 "$5"; le 4 0; le 4 0; le 8 1; le 8 0; }
# elf64 <flags of .debug_line> [<e_shoff>]: the file on stdout; e_shoff
# defaults to where the headers really are.
elf64() {
    _strtab_len=23 # "\0.shstrtab\0.debug_line\0"
    _data_len=$((${#D} + 1))
    _shoff=$((64 + _strtab_len + _data_len))
    printf '\177ELF'; le 1 2; le 1 1; le 1 1; zeros 9
    le 2 1; le 2 62; le 4 1; le 8 0; le 8 0; le 8 "${2:-$_shoff}"
    le 4 0; le 2 64; le 2 0; le 2 0; le 2 64; le 2 3; le 2 1
    nul; printf '.shstrtab'; nul; printf '.debug_line'; nul
    printf '%s' "$D"; nul
    zeros 64
    shdr 1 3 0 64 "$_strtab_len"
    shdr 11 1 "$1" $((64 + _strtab_len)) "$_data_len"
}

# 13. An ELF file with a section whose flags hold SHF_COMPRESSED (0x800) is
# refused (exit 1) and left untouched, although "$D" followed by NUL is in it:
# a compressed section's bytes are not the strings they hold, so a byte search
# can miss the directory there, and a count would claim a clean file.
elf64 2048 >"$W/f"
cp "$W/f" "$W/want"
run "$TOOL" "$W/f" "$D"
[ "$RC" -eq 1 ] || red "compressed section: exit $RC, want 1"
grep -q "section 2 is compressed (SHF_COMPRESSED" "$W/err" || red "compressed section: the message does not name section 2 and SHF_COMPRESSED"
[ ! -s "$W/out" ] || red "compressed section: counts were printed"
same "$W/f" "$W/want" "compressed section (must be untouched)"
pass

# 14. The same ELF file with that flag clear (0x2, SHF_ALLOC, beside it) is
# relocated as any file is: the refusal is the flag's, not the format's.
elf64 2 >"$W/f"
[ "$(wc -c <"$W/f")" -eq $((64 + 23 + ${#D} + 1 + 3 * 64)) ] || red "uncompressed ELF: the fixture is $(wc -c <"$W/f") bytes"
run "$TOOL" "$W/f" "$D"
[ "$RC" -eq 0 ] || red "uncompressed ELF: exit $RC, want 0"
[ "$(cat "$W/out")" = "1 $D" ] || red "uncompressed ELF: stdout '$(cat "$W/out")', want '1 $D'"
grep -qF "$P" "$W/f" || red "uncompressed ELF: the placeholder is not in the file"
! grep -qF "$D" "$W/f" || red "uncompressed ELF: the directory is still in the file"
pass

# 15. Relocating is idempotent: the relocated file again, with the same
# directory, is 0 rewrites, exit 0, the same bytes and the same inode (not
# written). The placeholder never holds the directory it replaced.
cp "$W/f" "$W/want"
ino=$(stat -c %i "$W/f")
run "$TOOL" "$W/f" "$D"
[ "$RC" -eq 0 ] || red "idempotent: exit $RC, want 0"
[ "$(cat "$W/out")" = "0 $D" ] || red "idempotent: stdout '$(cat "$W/out")', want '0 $D'"
same "$W/f" "$W/want" "idempotent"
[ "$(stat -c %i "$W/f")" = "$ino" ] || red "idempotent: the file was replaced (inode $ino -> $(stat -c %i "$W/f"))"
pass

# 16. An ELF file whose section headers lie past its end cannot be shown free
# of compressed sections: refused (exit 1), untouched.
elf64 2 4096 >"$W/f"
cp "$W/f" "$W/want"
run "$TOOL" "$W/f" "$D"
[ "$RC" -eq 1 ] || red "section headers past the end: exit $RC, want 1"
grep -q "section headers" "$W/err" || red "section headers past the end: the message does not name the section headers"
same "$W/f" "$W/want" "section headers past the end (must be untouched)"
pass

# 17. More than 0xff00 sections: e_shnum is 0 and section 0's sh_size holds
# the count (3). The compressed section is found through that count.
elf64_many() {
    _strtab_len=23
    _data_len=$((${#D} + 1))
    printf '\177ELF'; le 1 2; le 1 1; le 1 1; zeros 9
    le 2 1; le 2 62; le 4 1; le 8 0; le 8 0; le 8 $((64 + _strtab_len + _data_len))
    le 4 0; le 2 64; le 2 0; le 2 0; le 2 64; le 2 0; le 2 1
    nul; printf '.shstrtab'; nul; printf '.debug_line'; nul
    printf '%s' "$D"; nul
    shdr 0 0 0 0 3
    shdr 1 3 0 64 "$_strtab_len"
    shdr 11 1 "$1" $((64 + _strtab_len)) "$_data_len"
}
elf64_many 2048 >"$W/f"
cp "$W/f" "$W/want"
run "$TOOL" "$W/f" "$D"
[ "$RC" -eq 1 ] || red "compressed section, e_shnum 0: exit $RC, want 1"
grep -q "section 2 is compressed (SHF_COMPRESSED" "$W/err" || red "compressed section, e_shnum 0: the message does not name section 2"
same "$W/f" "$W/want" "compressed section, e_shnum 0 (must be untouched)"
elf64_many 2 >"$W/f"
run "$TOOL" "$W/f" "$D"
[ "$RC" -eq 0 ] || red "uncompressed, e_shnum 0: exit $RC, want 0"
pass

# 18. An ELF32 file (40-byte section headers, 32-bit sh_flags) with a
# compressed section: refused the same way, untouched.
# shdr32 <name> <type> <flags> <offset> <size>: one ELF32 section header.
shdr32() { le 4 "$1"; le 4 "$2"; le 4 "$3"; le 4 0; le 4 "$4"; le 4 "$5"; le 4 0; le 4 0; le 4 1; le 4 0; }
elf32() {
    _strtab_len=23
    _data_len=$((${#D} + 1))
    printf '\177ELF'; le 1 1; le 1 1; le 1 1; zeros 9
    le 2 1; le 2 3; le 4 1; le 4 0; le 4 0; le 4 $((52 + _strtab_len + _data_len))
    le 4 0; le 2 52; le 2 0; le 2 0; le 2 40; le 2 3; le 2 1
    nul; printf '.shstrtab'; nul; printf '.debug_line'; nul
    printf '%s' "$D"; nul
    zeros 40
    shdr32 1 3 0 52 "$_strtab_len"
    shdr32 11 1 "$1" $((52 + _strtab_len)) "$_data_len"
}
elf32 2048 >"$W/f"
[ "$(wc -c <"$W/f")" -eq $((52 + 23 + ${#D} + 1 + 3 * 40)) ] || red "ELF32: the fixture is $(wc -c <"$W/f") bytes"
cp "$W/f" "$W/want"
run "$TOOL" "$W/f" "$D"
[ "$RC" -eq 1 ] || red "compressed section, ELF32: exit $RC, want 1"
grep -q "section 2 is compressed (SHF_COMPRESSED" "$W/err" || red "compressed section, ELF32: the message does not name section 2"
same "$W/f" "$W/want" "compressed section, ELF32 (must be untouched)"
elf32 2 >"$W/f"
run "$TOOL" "$W/f" "$D"
[ "$RC" -eq 0 ] || red "uncompressed, ELF32: exit $RC, want 0"
[ "$(cat "$W/out")" = "1 $D" ] || red "uncompressed, ELF32: stdout '$(cat "$W/out")', want '1 $D'"
pass

# 19. An ELF32 file with e_shnum 0: section 0's 32-bit sh_size (offset 0x14
# of its header) holds the count (3), and the compressed section is found
# through it, as case 17 for ELF64.
elf32_many() {
    _strtab_len=23
    _data_len=$((${#D} + 1))
    printf '\177ELF'; le 1 1; le 1 1; le 1 1; zeros 9
    le 2 1; le 2 3; le 4 1; le 4 0; le 4 0; le 4 $((52 + _strtab_len + _data_len))
    le 4 0; le 2 52; le 2 0; le 2 0; le 2 40; le 2 0; le 2 1
    nul; printf '.shstrtab'; nul; printf '.debug_line'; nul
    printf '%s' "$D"; nul
    shdr32 0 0 0 0 3
    shdr32 1 3 0 52 "$_strtab_len"
    shdr32 11 1 "$1" $((52 + _strtab_len)) "$_data_len"
}
elf32_many 2048 >"$W/f"
[ "$(wc -c <"$W/f")" -eq $((52 + 23 + ${#D} + 1 + 3 * 40)) ] || red "ELF32, e_shnum 0: the fixture is $(wc -c <"$W/f") bytes"
cp "$W/f" "$W/want"
run "$TOOL" "$W/f" "$D"
[ "$RC" -eq 1 ] || red "compressed section, ELF32, e_shnum 0: exit $RC, want 1"
grep -q "section 2 is compressed (SHF_COMPRESSED" "$W/err" || red "compressed section, ELF32, e_shnum 0: the message does not name section 2"
same "$W/f" "$W/want" "compressed section, ELF32, e_shnum 0 (must be untouched)"
elf32_many 2 >"$W/f"
run "$TOOL" "$W/f" "$D"
[ "$RC" -eq 0 ] || red "uncompressed, ELF32, e_shnum 0: exit $RC, want 0"
[ "$(cat "$W/out")" = "1 $D" ] || red "uncompressed, ELF32, e_shnum 0: stdout '$(cat "$W/out")', want '1 $D'"
pass

rm -rf "$T"
printf '{"version": 1, "data": {"status": "success", "message": "debug_relocate: %s cases passed"}}\n' "$N" >"$RESULT"
echo "debug_relocate_cases GREEN: $N cases"
