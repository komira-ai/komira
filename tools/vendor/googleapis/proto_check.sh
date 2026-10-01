# proto_check: refuses a googleapis proto tree unless it is exactly the import
# closure of its roots. Run by busybox sh, one action:
#
#   proto_check.sh BB PROTOC TREE OUT_SET OUT_TREE ROOT...
#
# BB is busybox, PROTOC the protoc distribution (bin/protoc, include/), TREE
# the files staged at their import paths (extracted from the pinned googleapis
# archive, whose sha256 the download itself checks), and the ROOTs import
# paths in TREE. It refuses, naming the file, unless
#   - TREE holds nothing under google/protobuf/ (protoc's own);
#   - protoc parses the ROOTs with nothing on its path but TREE and protoc's
#     include/, so a file the closure needs and TREE lacks fails here; and
#   - every file of TREE is in the descriptor set protoc writes for the ROOTs
#     (--include_imports), so TREE holds the closure and nothing else.
# Only then does it write OUT_SET (that descriptor set) and OUT_TREE (a copy
# of TREE), so nothing reads a tree that is not exactly the closure.
set -eu

BB=$1 PROTOC=$2 TREE=$3 OUT_SET=$4 OUT_TREE=$5
shift 5

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
[ "$#" -gt 0 ] || fail "the target names no root"

# The files of the tree; none of them protoc's own.
(cd "$TREE" && find . -type f -o -type l) | sed 's|^\./||' | LC_ALL=C sort > "$T/files.tree"
[ -s "$T/files.tree" ] || fail "the tree holds no file"
wkt=$(grep '^google/protobuf/' "$T/files.tree" | head -n 1 || true)
[ -z "$wkt" ] || fail "$wkt is in the tree, but google/protobuf/ is protoc's own (its include/)"

# protoc, with only TREE and protoc's include/ on its path.
"$PROTOC/bin/protoc" -I "$TREE" -I "$PROTOC/include" --include_imports \
    --descriptor_set_out="$T/set.pb" "$@" 2> "$T/protoc.err" ||
    fail "protoc cannot parse the roots from the tree: $(cat "$T/protoc.err")"

# The files of the descriptor set: in protoc's text form, a FileDescriptorProto
# `name` is the only one indented two spaces.
"$PROTOC/bin/protoc" -I "$PROTOC/include" --decode=google.protobuf.FileDescriptorSet \
    google/protobuf/descriptor.proto < "$T/set.pb" > "$T/set.txt" 2> "$T/protoc.err" ||
    fail "protoc cannot decode the descriptor set: $(cat "$T/protoc.err")"
sed -n 's/^  name: "\(.*\)"$/\1/p' "$T/set.txt" | grep -v '^google/protobuf/' | LC_ALL=C sort > "$T/files.closure"
[ -s "$T/files.closure" ] || fail "the descriptor set names no file"
unused=$(comm -13 "$T/files.closure" "$T/files.tree" | head -n 1)
[ -z "$unused" ] || fail "$unused is in the tree but not in the import closure of the roots"
missing=$(comm -23 "$T/files.closure" "$T/files.tree" | head -n 1)
[ -z "$missing" ] || fail "$missing is in the import closure but not in the tree"

cp "$T/set.pb" "$OUT_SET"
mkdir -p "$OUT_TREE"
cp -R "$TREE/." "$OUT_TREE/"
rm -rf "$T"
