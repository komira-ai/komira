#!/bin/sh
# cov_branch_annotate.sh -- applies one welded test's merged branch profile
# to its LLVM bitcode and writes the annotated IR as text, in a build action
# (`mojo_cov_branch_annotate`, tools/build/mojo/coverage_branch.bzl;
# README.md, "cov_branch_annotate").
#
# usage: busybox sh <branch_dir>/cov_branch_annotate.sh <busybox> <bitcode> <profdata> <binary> <ir_out>
#
#   <branch_dir>    the annotate directory of a cov_branch_dir ([annotate]):
#                   this script, lld/ (bin/lld, the Mojo package's LLD 24)
#                   and llvm/ (bin/llvm-profdata), which it finds beside
#                   itself
#   <bitcode>       the test's LLVM bitcode ([coverage][bc][<test>]), the
#                   bitcode its instrumented binary was made from
#   <profdata>      the merged profile of its run ([coverage][branch][<test>])
#   <binary>        the instrumented binary that run ran
#                   ([coverage][pgo_bin][<test>])
#
# Steps:
#   0. The bitcode holds no branch weights of its own (no "branch_weights"
#      metadata string): `pgo-instr-use` leaves the `!prof` it finds on a
#      branch whose block never ran, which would then read as counts. Nor
#      does it hold entry counts (no "function_entry_count"), which step 3
#      counts as the functions the pass found in the profile.
#   1. The profile holds exactly the functions <binary> links. Every function
#      of the bitcode is instrumented (cov_branch_link.sh), but the link
#      (--gc-sections, as a release test's) drops a function nothing live
#      calls, with its counters and its profile data record: one the compiler
#      calls only from a branch it folds to never taken, as an assert's
#      failure path on two known values. A run writes the record of every
#      function its binary links, zeros included, and of no other. So the
#      (name MD5, hash) pairs of <binary>'s `__llvm_prf_data` records and of
#      the profile's functions (`llvm-profdata show`) must be one set: a
#      record the profile lacks, or holds besides, is a profile of another
#      binary or a merge that lost records, and fails the action.
#   2. lld reads the bitcode as cov_branch_link.sh does (an LTO link with -r
#      at -O0), with the one pass `pgo-instr-use` reading <profdata>, and
#      prints the module after that pass (`-print-after=pgo-instr-use
#      -print-module-scope`, on stderr). The pass gives every conditional
#      branch, switch and select of an instrumented function that ran its
#      `!prof !{!"branch_weights", ...}` metadata: the counts of its arms.
#      Before the dump, LLVM names each function of the bitcode the profile
#      does not hold (`-pgo-warn-missing-function`). Such a function is not
#      in <binary>, by step 1 and step 3 together: step 1 makes the profile
#      the binary's records, and step 3 matches each of them to a function
#      of this bitcode (by its profile name and hash), so a function no
#      record matches is one the binary does not link. Step 1 alone does
#      not give it: a bitcode function whose profile name is not the one
#      the run wrote (test 47's branchinternal: `main` internalized) is
#      named here although it ran. Such a function never ran, and its
#      branches, which carry no weights, read as never run (zero counts),
#      as those of a function that ran no time do.
#   3. Any other line of lld's own fails the action, naming it: a line
#      starting `lld: ` (after any program name), `warning: ` or `error: `,
#      or anything before the dump that is not one of those missing-function
#      lines. So a profile that does not fit the bitcode (`function control
#      flow change detected (hash mismatch)`: that function's counts
#      dropped) cannot pass as branches that never ran. Then what is left is
#      exactly one dump: the header line `; *** IR Dump After
#      PGOInstrumentationUse on [module] ***` first, and no other header.
#      In it, the pass gave an entry count (`!prof` on the `define`) to as
#      many functions as the profile holds: each function <binary> links is
#      one of this bitcode, with its control flow. Fewer is a binary made
#      from other bitcode, or a function whose hash does not match that
#      LLVM does not warn about (a comdat function's mismatch is silent by
#      default, `-no-pgo-warn-mismatch-comdat-weak`).
#   4. <ir_out> is the dump, header included, unchanged.
#
# Exit status: 1 when a step fails, naming it; 2 for a usage error.
set -euf
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail
set -o pipefail

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
[ "$#" = 5 ] || { echo "cov_branch_annotate: usage error" >&2; exit 2; }
HERE=$(abs "${0%/*}")
BB=$(abs "$1")
BC=$(abs "$2")
PROF=$(abs "$3")
BIN=$(abs "$4")
OUT=$(abs "$5")

case "${BUCK_SCRATCH_PATH:-}" in
    "") K="$PWD/.cov_branch_annotate" ;;
    /*) K="$BUCK_SCRATCH_PATH/cov_branch_annotate" ;;
    *) K="$PWD/$BUCK_SCRATCH_PATH/cov_branch_annotate" ;;
esac
"$BB" mkdir -p "$K/bin" "$K/tmp" "$K/names"
"$BB" --install -s "$K/bin"
PATH="$K/bin"
TMPDIR="$K/tmp"
export PATH TMPDIR LC_ALL=C

HEADER="; *** IR Dump After PGOInstrumentationUse on [module] ***"
MISSING="no profile data available for function "

red() {
    echo "BRANCH COVERAGE ANNOTATE FAILED: $*" >&2
    exit 1
}

LLD="$HERE/lld/bin/lld"
PD="$HERE/llvm/bin/llvm-profdata"
for f in "$LLD" "$PD" "$BC" "$PROF" "$BIN"; do
    [ -s "$f" ] || { echo "cov_branch_annotate: $f is missing or empty" >&2; exit 2; }
done
[ "$(od -A n -t x1 -N 4 "$BC" | tr -d ' \n')" = "4243c0de" ] || red "$2 is not LLVM bitcode"

# 0. No branch weights before the profile is applied, and no entry counts.
# Metadata strings are kept as their bytes in the bitcode, one after another
# (so a substring).
set +e
grep -q -F branch_weights "$BC"
rc=$?
set -e
case "$rc" in
    0) red "$2 already holds branch weights before the profile is applied (a \"branch_weights\" metadata string): pgo-instr-use keeps them on branches that never ran, where they would read as counts" ;;
    1) ;;
    *) red "grep could not read $2 (exit $rc)" ;;
esac
set +e
grep -q -F function_entry_count "$BC"
rc=$?
set -e
case "$rc" in
    0) red "$2 already holds function entry counts before the profile is applied (a \"function_entry_count\" metadata string): step 3 counts the functions pgo-instr-use found in the profile by their entry counts" ;;
    1) ;;
    *) red "grep could not read $2 (exit $rc)" ;;
esac

# 1. The profile holds exactly the functions the binary links.
# An unsigned little-endian field of the binary: u <offset> <bytes>.
u() { od -A n -t "u$2" -j "$1" -N "$2" "$BIN" | tr -d ' \n'; }
[ "$(od -A n -t x1 -N 6 "$BIN" | tr -d ' \n')" = "7f454c460201" ] || red "$4 is not a 64-bit little-endian ELF file"
shoff=$(u 40 8)
shentsize=$(u 58 2)
shnum=$(u 60 2)
shstrndx=$(u 62 2)
[ "$shentsize" = 64 ] && [ "$shnum" -gt 0 ] && [ "$shstrndx" -lt "$shnum" ] ||
    red "$4 has no section header table this script reads (entry size '$shentsize', $shnum entries, names at $shstrndx)"
strtab=$(u $((shoff + shstrndx * 64 + 24)) 8)
data_off="" data_size="" cnts_size=""
i=0
while [ "$i" -lt "$shnum" ]; do
    h=$((shoff + i * 64))
    # sed, not head: every reader takes all of its input, so no writer is
    # killed by SIGPIPE (exit 141 under pipefail, seen in remote runs; test
    # 47's branchwide pads this pipeline with 1 MB).
    name=$(dd if="$BIN" bs=1 skip=$((strtab + $(u "$h" 4))) count=16 2>/dev/null | tr '\0' '\n' | sed -n 1p)
    case "$name" in
        __llvm_prf_data)
            [ -z "$data_off" ] || red "$4 has two __llvm_prf_data sections"
            data_off=$(u $((h + 24)) 8)
            data_size=$(u $((h + 32)) 8)
            ;;
        __llvm_prf_cnts)
            [ -z "$cnts_size" ] || red "$4 has two __llvm_prf_cnts sections"
            cnts_size=$(u $((h + 32)) 8)
            ;;
    esac
    i=$((i + 1))
done
[ -n "$data_off" ] && [ -n "$cnts_size" ] || red "$4 has no __llvm_prf_data or no __llvm_prf_cnts section: it is not an instrumented binary"
# A record is 72 bytes (InstrProfData.inc of the pinned LLVM): the name's MD5
# (its first 8 bytes), the function's hash, ..., its counter count (a u32 at
# byte 56). The counts must add up to the counter section, or the layout is
# not the one read here.
[ "$data_size" -gt 0 ] && [ $((data_size % 72)) = 0 ] ||
    red "$4's __llvm_prf_data is $data_size bytes, not a whole number of 72-byte records"
records=$((data_size / 72))
counters=$(od -A n -t u4 -v -j "$data_off" -N "$data_size" "$BIN" |
    awk '{ for (i = 1; i <= NF; i++) { if (n % 18 == 14) s += $i; n++ } } END { printf "%d", s }')
[ $((counters * 8)) = "$cnts_size" ] ||
    red "$4's $records profile data records count $counters counters, but its __llvm_prf_cnts is $cnts_size bytes: not the 72-byte record this script reads"
# <name MD5 prefix> <hash>, one per record: bytes 0-7 in order (the MD5's
# first 8 bytes), bytes 8-15 as a little-endian number.
od -A n -t x1 -v -j "$data_off" -N "$data_size" "$BIN" | awk '
    { for (i = 1; i <= NF; i++) { b[n % 72] = $i; n++; if (n % 72 == 0) {
        s = ""; for (j = 0; j < 8; j++) s = s b[j]
        h = ""; for (j = 15; j >= 8; j--) h = h b[j]
        print s, h } } }' | sort >"$K/binary.recs"
[ "$(grep -c . "$K/binary.recs")" = "$records" ] || red "could not read $records records from $4's __llvm_prf_data"
# The profile's functions: a name line (two spaces, the name, a colon), then
# its `Hash: 0x...` line. Each name is written to a file of its own, so its
# MD5 is of its bytes.
"$PD" show --all-functions "$PROF" >"$K/show.txt" 2>"$K/show.err" ||
    red "llvm-profdata show failed on $3: $(head -n 2 "$K/show.err" | tr '\n' ' ')"
awk -v d="$K/names" '
    /^  [^ ]/ && /:$/ && !held { n++; f = d "/" n; printf "%s", substr($0, 3, length($0) - 3) > f; close(f); held = 1; next }
    held && /^    Hash: 0x[0-9a-f]+$/ { h = substr($2, 3); while (length(h) < 16) h = "0" h; print n, h; held = 0; next }
    held { print "unread", NR; exit 1 }' "$K/show.txt" >"$K/hashes" ||
    red "the function list of $3 could not be read (llvm-profdata show, line $(cut -d ' ' -f 2 "$K/hashes" | tail -n 1))"
fns=$(sed -n 's/^Total functions: \([0-9][0-9]*\)$/\1/p' "$K/show.txt")
[ "$(grep -c . "$K/hashes")" = "${fns:-none}" ] ||
    red "read $(grep -c . "$K/hashes") functions from $3, but llvm-profdata show reports '${fns:-none}'"
if [ "$fns" -gt 0 ]; then
    (cd "$K/names" && find . -type f | sed 's|^\./||' | xargs md5sum) >"$K/md5"
fi
touch "$K/md5"
awk 'NR == FNR { m[$2] = substr($1, 1, 16); next } { print m[$1], $2, $1 }' "$K/md5" "$K/hashes" | sort >"$K/profile.full"
cut -d ' ' -f 1,2 "$K/profile.full" >"$K/profile.recs"
comm -23 "$K/binary.recs" "$K/profile.recs" >"$K/lost"
comm -13 "$K/binary.recs" "$K/profile.recs" >"$K/extra"
if [ -s "$K/lost" ]; then
    red "the profile $3 holds no record of $(grep -c . "$K/lost") of the $records functions $4 links (name MD5 prefix, hash: $(head -n 3 "$K/lost" | tr '\n' ' ')): a run writes the record of every function its binary links, ran or not, so this is a profile of another binary, or a merge that lost records"
fi
if [ -s "$K/extra" ]; then
    first=$(awk 'NR == FNR { x[$1 " " $2] = 1; next } ($1 " " $2) in x { print $3; exit }' "$K/extra" "$K/profile.full")
    red "the profile $3 holds $(grep -c . "$K/extra") function(s) $4 does not link, the first $(cut -c1-300 "$K/names/$first"): a profile of another binary"
fi

# 2. The profile applied, the module printed after the pass.
if ! "$LLD" -flavor gnu -r -m elf_x86_64 "$BC" -o "$K/use.o" --lto-O0 \
    "--lto-newpm-passes=pgo-instr-use" -mllvm "-pgo-test-profile-file=$PROF" \
    -mllvm -pgo-warn-missing-function -mllvm -print-after=pgo-instr-use -mllvm -print-module-scope >"$K/out" 2>"$K/err"; then
    # Its message is at the end of what it printed (the dump, if any, first).
    tail -n 20 "$K/err" | cut -c1-300 >&2
    red "lld could not apply the profile $3 to $2 (pgo-instr-use)"
fi

# 3. Before the header, only the functions the profile does not hold (not
# in the binary, by step 1 and the entry-count check below); no other
# diagnostic; one dump. Those lines are dropped: each such function's
# branches read as never run.
awk -v H="$HEADER" -v M="$MISSING" -v ir="$K/ir" -v pre="$K/pre" '
    !in_dump && $0 == H { in_dump = 1 }
    in_dump { print > ir; next }
    $0 ~ ("^[^ ]*lld: warning: [^ ]*: " M) && $0 ~ / Hash = [0-9]+ up to 0 count discarded$/ { next }
    { print > pre }' "$K/err"
touch "$K/ir" "$K/pre"
{ cat "$K/pre"; grep -E '^([^ ]*lld: |warning: |error: )' "$K/ir" || true; } >"$K/diag"
if [ -s "$K/diag" ]; then
    red "lld reported $(grep -c . "$K/diag") diagnostic(s) applying the profile: $(head -n 5 "$K/diag" | cut -c1-300 | tr '\n' ' ')"
fi
[ ! -s "$K/out" ] || red "lld wrote to its standard output: $(head -n 3 "$K/out" | tr '\n' ' ')"
[ "$(head -n 1 "$K/ir")" = "$HEADER" ] ||
    red "lld's output does not start with the dump header '$HEADER': $(head -n 1 "$K/ir" | cut -c1-200)"
n=$(grep -c -F '; *** IR Dump ' "$K/ir" || true)
[ "$n" = 1 ] || red "lld printed $n IR dumps, expected exactly one"
# Every function the profile holds is one of the bitcode: pgo-instr-use
# gives each function it finds in the profile an entry count (`!prof` on its
# `define`, 0 for one that never ran), and no other.
found=$(grep -c '^define .* !prof ![0-9]' "$K/ir" || true)
[ "$found" = "$fns" ] ||
    red "pgo-instr-use found $found of the $fns functions of the profile $3 in $2: the binary that wrote it was not made from this bitcode"

# 4. The dump.
cp "$K/ir" "$OUT"
rm -rf "$K"
