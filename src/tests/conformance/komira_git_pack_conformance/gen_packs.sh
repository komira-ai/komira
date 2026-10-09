#!/bin/sh
# Writes the packs komira_git_pack_conformance reads, with the pinned git
# (//third_party/git), in one build action of the `git_packs` rule (defs.bzl):
#   sh gen_packs.sh <busybox> <out_dir> <git_dist>
#
# Two repositories get the same history (`history` below): one in the sha1
# object format, one in sha256. Thirty commits, each at a fixed date, change a
# 400-line file in one line, grow a 70 to 110 KB file and edit lines of it,
# append to a third file, add a file every fifth commit and delete one every
# tenth, and an annotated tag lands every seventh. The objects stay loose in
# the repositories; every pack is written outside them, so each is made from
# the objects alone (no delta is reused from an earlier pack).
#
# <out_dir> holds, for each pack <name>:
#   <name>.pack     what `git pack-objects` wrote
#   <name>.idx      what `git index-pack` writes for <name>.pack
#   <name>.verify   `git verify-pack -v`'s object lines, one per entry, as
#                   `<id> <type> <size> <size-in-pack> <offset> <depth> <base>`
#                   (depth 0 and base `-` for a non-delta)
# The sha1 packs, all of every object of the repository:
#   ofs       --delta-base-offset, window 10, depth 50 (OFS_DELTA entries)
#   ref       window 10, depth 50, no --delta-base-offset (REF_DELTA entries)
#   nodelta   window 0 (no delta)
#   deep      --delta-base-offset, window 250, depth 4095
#   narrow    --delta-base-offset, window 2, depth 3
#   stored    as ofs, at --compression=0 (zlib stored blocks)
# and also:
#   ofs_large.idx   `git index-pack --index-version=2,0x40` of ofs.pack:
#                   every offset over 0x40 in the eight-byte table
#   thin.pack       `--thin --stdout` of main~10..main (REF_DELTAs on objects
#                   main~10 has; no .idx: git index-pack refuses it too)
#   thin.ids        the ids it carries (`git rev-list --objects`), sorted
#   objects.batch   `git cat-file --batch-all-objects --batch` of the
#                   repository: `<id> <type> <size>\n<payload>\n` per object
# The sha256 repository: sha256.pack/.idx/.verify (as ofs) and
# objects256.batch.
#
# pack.threads is 1, so the delta search, and with it every byte written, is
# the same on every run.
set -eu
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail
set -o pipefail

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
BB=$(abs "$1")
OUT=$(abs "$2")
DIST=$(abs "$3")

case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.gen_packs" ;;
    /*) T="$BUCK_SCRATCH_PATH/gen_packs" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/gen_packs" ;;
esac
"$BB" mkdir -p "$T/bin" "$T/home" "$T/work"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
HOME="$T/home"
export PATH LC_ALL=C HOME
export GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat
export GIT_AUTHOR_NAME="A U Thor" GIT_AUTHOR_EMAIL=author@example.com
export GIT_COMMITTER_NAME="C O Mitter" GIT_COMMITTER_EMAIL=committer@example.com
GIT="$DIST/bin/git"
mkdir -p "$OUT"

fail() {
    echo "gen_packs: $*" >&2
    [ -f "$T/log" ] && { echo "--- log:" >&2; tail -n 40 "$T/log" >&2; }
    exit 1
}

# history <repo> <object format>
history() {
    r=$1
    "$GIT" init -q -b main --object-format="$2" "$r" >"$T/log" 2>&1 || fail "git init $2 failed"
    mkdir -p "$r/src/deep/er" "$r/docs"
    : >"$r/empty"
    i=1
    while [ "$i" -le 30 ]; do
        awk -v i="$i" 'BEGIN { for (k = 1; k <= 400; k++) printf "line %d of a.txt, revision %d\n", k, (k % 30 == i % 30) ? i : 0 }' >"$r/src/a.txt"
        awk -v i="$i" 'BEGIN { for (k = 1; k <= 5000 + 100 * i; k++) printf "%08d %s\n", (k * 7919) % 100000, (k % 97 == i) ? "edited" : "same" }' >"$r/src/deep/er/big.txt"
        printf 'entry %d of the log\n' "$i" >>"$r/docs/log.txt"
        if [ $((i % 5)) -eq 0 ]; then
            awk -v i="$i" 'BEGIN { for (k = 1; k <= 20 * i; k++) printf "new file %d, line %d\n", i, k }' >"$r/src/n$i.txt"
        fi
        if [ $((i % 10)) -eq 0 ]; then
            rm -f "$r/src/n$((i - 5)).txt"
        fi
        d="$((1790000000 + 60 * i)) +0000"
        "$GIT" -C "$r" add -A >"$T/log" 2>&1 || fail "git add failed at commit $i"
        GIT_AUTHOR_DATE="$d" GIT_COMMITTER_DATE="$d" "$GIT" -C "$r" commit -q -m "commit $i" >"$T/log" 2>&1 ||
            fail "git commit failed at commit $i"
        if [ $((i % 7)) -eq 0 ]; then
            GIT_COMMITTER_DATE="$d" "$GIT" -C "$r" tag -a "v$i" -m "tag $i" >"$T/log" 2>&1 || fail "git tag failed at commit $i"
        fi
        i=$((i + 1))
    done
}

# pack <repo> <name> <pack-objects options...>: every object of the
# repository, into <name>.pack, .idx and .verify.
pack() {
    r=$1
    name=$2
    shift 2
    "$GIT" -C "$r" -c pack.threads=1 pack-objects -q --all "$@" "$T/work/$name" </dev/null >"$T/work/$name.sum" 2>"$T/log" ||
        fail "git pack-objects $name failed"
    sum=$(cat "$T/work/$name.sum")
    mv "$T/work/$name-$sum.pack" "$OUT/$name.pack"
    "$GIT" -C "$r" index-pack -o "$OUT/$name.idx" "$OUT/$name.pack" >"$T/log" 2>&1 || fail "git index-pack $name failed"
    "$GIT" -C "$r" verify-pack -v "$OUT/$name.idx" >"$T/work/$name.verify" 2>"$T/log" || fail "git verify-pack $name failed"
    awk '$1 ~ /^[0-9a-f]+$/ && (length($1) == 40 || length($1) == 64) && NF >= 5 {
        if (NF >= 7) print $1, $2, $3, $4, $5, $6, $7; else print $1, $2, $3, $4, $5, 0, "-"
    }' "$T/work/$name.verify" >"$OUT/$name.verify"
    [ -s "$OUT/$name.verify" ] || fail "verify-pack $name listed no object"
}

R="$T/sha1"
history "$R" sha1
pack "$R" ofs --delta-base-offset --window=10 --depth=50
pack "$R" ref --window=10 --depth=50
pack "$R" nodelta --window=0
pack "$R" deep --delta-base-offset --window=250 --depth=4095
pack "$R" narrow --delta-base-offset --window=2 --depth=3
pack "$R" stored --compression=0 --delta-base-offset --window=10 --depth=50
"$GIT" -C "$R" index-pack --index-version=2,0x40 -o "$OUT/ofs_large.idx" "$OUT/ofs.pack" >"$T/log" 2>&1 ||
    fail "git index-pack --index-version=2,0x40 failed"
"$GIT" -C "$R" cat-file --batch-all-objects --batch >"$OUT/objects.batch" 2>"$T/log" || fail "git cat-file --batch failed"
new=$("$GIT" -C "$R" rev-parse main)
old=$("$GIT" -C "$R" rev-parse main~10)
printf '%s\n^%s\n' "$new" "$old" | "$GIT" -C "$R" -c pack.threads=1 pack-objects -q --revs --thin --delta-base-offset --stdout \
    >"$OUT/thin.pack" 2>"$T/log" || fail "git pack-objects --thin failed"
"$GIT" -C "$R" rev-list --objects "$new" "^$old" >"$T/work/thin.list" 2>"$T/log" || fail "git rev-list failed"
cut -c1-40 "$T/work/thin.list" | sort >"$OUT/thin.ids"

R256="$T/sha256"
history "$R256" sha256
pack "$R256" sha256 --delta-base-offset --window=10 --depth=50
"$GIT" -C "$R256" cat-file --batch-all-objects --batch >"$OUT/objects256.batch" 2>"$T/log" || fail "git cat-file --batch (sha256) failed"

rm -rf "$T"
