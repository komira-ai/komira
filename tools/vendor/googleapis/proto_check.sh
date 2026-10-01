# proto_check: refuses a vendored googleapis tree unless it is exactly its pin
# and exactly the import closure of its roots. Run by busybox sh, one action:
#
#   proto_check.sh BB PROTOC TREE PIN LICENSE OUT_SET OUT_TREE ROOT...
#
# BB is busybox, PROTOC the protoc distribution (bin/protoc, include/), TREE
# the vendored files staged at their import paths, PIN the PIN.tsv, LICENSE
# the vendored LICENSE, and the ROOTs import paths in TREE. It refuses, naming
# the row or the file, unless
#   - PIN has one `repository` row, one `commit` row (a 40-hex sha) and one
#     `license` row, whose sha256 is LICENSE's;
#   - PIN's `root` rows are the ROOTs;
#   - PIN's `file` rows name each file of TREE once, with its sha256, and no
#     other file; and TREE holds nothing under google/protobuf/ (protoc's);
#   - protoc parses the ROOTs with nothing on its path but TREE and protoc's
#     include/, so a file the closure needs and TREE lacks fails here; and
#   - every file of TREE is in the descriptor set protoc writes for the ROOTs
#     (--include_imports), so TREE holds the closure and nothing else.
# Only then does it write OUT_SET (that descriptor set) and OUT_TREE (a copy
# of TREE), so nothing reads files that disagree with their pin.
set -eu

BB=$1 PROTOC=$2 TREE=$3 PIN=$4 LICENSE=$5 OUT_SET=$6 OUT_TREE=$7
shift 7

# The busybox applets on PATH, in the action's scratch directory.
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.proto_check" ;;
    /*) T="$BUCK_SCRATCH_PATH/proto_check" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/proto_check" ;;
esac
"$BB" rm -rf "$T"
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
export PATH

fail() {
    echo "proto_check: $*" >&2
    rm -rf "$T"
    exit 1
}
TAB=$(printf '\t')

# The value of the one row whose key is $1 (field 2), refusing 0 or 2+ rows.
one() {
    n=$(grep -c "^$1$TAB" "$PIN" || true)
    [ "$n" -eq 1 ] || fail "PIN.tsv has $n $1 rows, not 1"
    grep "^$1$TAB" "$PIN" | cut -f "${2:-2}"
}

one repository > /dev/null
COMMIT=$(one commit)
case "$COMMIT" in
    *[!0-9a-f]* | "") fail "PIN.tsv commit $COMMIT is not a 40-hex sha" ;;
esac
[ "${#COMMIT}" -eq 40 ] || fail "PIN.tsv commit $COMMIT is not a 40-hex sha"
bad=$(grep -v -e '^#' -e '^$' "$PIN" | cut -f 1 | grep -v -x -e repository -e commit -e root -e license -e file || true)
[ -z "$bad" ] || fail "PIN.tsv has a row of unknown kind: $(echo "$bad" | head -n 1)"

sha() { sha256sum "$1" | cut -d ' ' -f 1; }
[ "$(one license 2)" = LICENSE ] || fail "PIN.tsv license row names $(one license 2), not LICENSE"
want=$(one license 3)
got=$(sha "$LICENSE")
[ "$got" = "$want" ] || fail "sha256 of LICENSE is $got, PIN.tsv records $want"

# The roots: PIN's root rows, and the target's, as sorted sets.
grep "^root$TAB" "$PIN" | cut -f 2 | LC_ALL=C sort > "$T/roots.pin"
printf '%s\n' "$@" | LC_ALL=C sort > "$T/roots.target"
[ -s "$T/roots.target" ] || fail "the target names no root"
cmp -s "$T/roots.pin" "$T/roots.target" ||
    fail "PIN.tsv roots ($(tr '\n' ' ' < "$T/roots.pin")) are not the target's ($(tr '\n' ' ' < "$T/roots.target"))"

# The files: each pinned once, with its sha256, and the tree holds no other.
grep "^file$TAB" "$PIN" | cut -f 2 | LC_ALL=C sort > "$T/files.pin"
dup=$(uniq -d "$T/files.pin" | head -n 1)
[ -z "$dup" ] || fail "PIN.tsv pins $dup more than once"
(cd "$TREE" && find . -type f -o -type l) | sed 's|^\./||' | LC_ALL=C sort > "$T/files.tree"
extra=$(comm -13 "$T/files.pin" "$T/files.tree" | head -n 1)
[ -z "$extra" ] || fail "$extra is vendored but not pinned in PIN.tsv"
gone=$(comm -23 "$T/files.pin" "$T/files.tree" | head -n 1)
[ -z "$gone" ] || fail "$gone is pinned in PIN.tsv but not vendored"
wkt=$(grep '^google/protobuf/' "$T/files.tree" | head -n 1 || true)
[ -z "$wkt" ] || fail "$wkt is vendored, but google/protobuf/ is protoc's own (its include/)"
grep "^file$TAB" "$PIN" | while IFS="$TAB" read -r _ path want; do
    got=$(sha "$TREE/$path")
    [ "$got" = "$want" ] || fail "sha256 of $path is $got, PIN.tsv records $want"
done

# protoc, with only TREE and protoc's include/ on its path.
"$PROTOC/bin/protoc" -I "$TREE" -I "$PROTOC/include" --include_imports \
    --descriptor_set_out="$T/set.pb" "$@" 2> "$T/protoc.err" ||
    fail "protoc cannot parse the roots from the vendored tree: $(cat "$T/protoc.err")"

# The files of the descriptor set: in protoc's text form, a FileDescriptorProto
# `name` is the only one indented two spaces.
"$PROTOC/bin/protoc" -I "$PROTOC/include" --decode=google.protobuf.FileDescriptorSet \
    google/protobuf/descriptor.proto < "$T/set.pb" > "$T/set.txt" 2> "$T/protoc.err" ||
    fail "protoc cannot decode the descriptor set: $(cat "$T/protoc.err")"
sed -n 's/^  name: "\(.*\)"$/\1/p' "$T/set.txt" | grep -v '^google/protobuf/' | LC_ALL=C sort > "$T/files.closure"
[ -s "$T/files.closure" ] || fail "the descriptor set names no file"
unused=$(comm -13 "$T/files.closure" "$T/files.pin" | head -n 1)
[ -z "$unused" ] || fail "$unused is vendored but not in the import closure of the roots"
missing=$(comm -23 "$T/files.closure" "$T/files.pin" | head -n 1)
[ -z "$missing" ] || fail "$missing is in the import closure but not vendored"

cp "$T/set.pb" "$OUT_SET"
mkdir -p "$OUT_TREE"
cp -R "$TREE/." "$OUT_TREE/"
rm -rf "$T"
