#!/bin/sh
# Vendors the import closure of some googleapis .proto files at one commit.
#
#   tools/vendor/googleapis/vendor.sh <commit> <root.proto>...
#
# run from the repository root, for example
#
#   tools/vendor/googleapis/vendor.sh <commit> \
#       google/logging/v2/logging.proto google/logging/v2/log_entry.proto
#
# It fetches each root from the googleapis repository at <commit> over HTTPS,
# then every file the fetched files import, until the closure is complete.
# google/protobuf/* is not fetched: protoc provides those (its include/). It
# replaces tools/vendor/googleapis/google/ with the closure and LICENSE with
# the commit's, and writes PIN.tsv: the commit, the roots, and the sha256 of
# LICENSE and of each file. Run at the same commit with the same roots, it
# reproduces the tree and PIN.tsv byte for byte.
#
# It reads imports with a line pattern, which is enough to fetch; the
# proto_check target (BUCK) then runs protoc over what it fetched and refuses
# a file that is missing from the closure or not in it. The build never
# fetches.
#
# POSIX sh, curl, sed, sort, mktemp and sha256sum.
set -eu

if [ "$#" -lt 2 ]; then
    echo "usage: $0 <commit> <root.proto>..." >&2
    exit 2
fi
COMMIT=$1
shift
REPO=https://github.com/googleapis/googleapis
RAW=https://raw.githubusercontent.com/googleapis/googleapis/$COMMIT
HERE=tools/vendor/googleapis

[ -f "$HERE/BUCK" ] || { echo "vendor.sh: run from the repository root ($HERE/BUCK not found)" >&2; exit 2; }
case "$COMMIT" in
    *[!0-9a-f]*) echo "vendor.sh: the commit must be a full lowercase hex sha, not $COMMIT" >&2; exit 2 ;;
esac
[ "${#COMMIT}" -eq 40 ] || { echo "vendor.sh: the commit must be a full 40-hex sha, not $COMMIT" >&2; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/tree"

fetch() {
    mkdir -p "$TMP/tree/$(dirname "$1")"
    curl -fsS --proto =https -o "$TMP/tree/$1" "$RAW/$1" || { echo "vendor.sh: cannot fetch $1 at $COMMIT" >&2; exit 1; }
}

# Breadth first over the imports; `seen` holds every path met so far.
ROOTS=$*
queue=$ROOTS
seen=" "
while [ -n "$queue" ]; do
    set -- $queue
    f=$1
    shift
    queue=$*
    case "$seen" in *" $f "*) continue ;; esac
    seen="$seen$f "
    case "$f" in google/protobuf/*) continue ;; esac
    fetch "$f"
    for i in $(sed -n -E 's/^import[[:space:]]+(public[[:space:]]+|weak[[:space:]]+)?"([^"]+)";.*$/\2/p' "$TMP/tree/$f"); do
        queue="$queue $i"
    done
done
curl -fsS --proto =https -o "$TMP/LICENSE" "$RAW/LICENSE" || { echo "vendor.sh: cannot fetch LICENSE at $COMMIT" >&2; exit 1; }

sha() { sha256sum "$1" | sed 's/ .*//'; }
TAB=$(printf '\t')
{
    echo "# The googleapis files vendored here: one commit, the roots, and the sha256"
    echo "# of LICENSE and of every file of the roots' import closure (google/protobuf/*"
    echo "# excepted: protoc provides those). Written by vendor.sh; proto_check refuses"
    echo "# the tree unless it is exactly this. Rows are tab-separated."
    echo "repository${TAB}$REPO"
    echo "commit${TAB}$COMMIT"
} > "$TMP/PIN.tsv"
for r in $ROOTS; do echo "root${TAB}$r" >> "$TMP/PIN.tsv"; done
echo "license${TAB}LICENSE${TAB}$(sha "$TMP/LICENSE")" >> "$TMP/PIN.tsv"
(cd "$TMP/tree" && find . -type f | sed 's|^\./||' | LC_ALL=C sort) | while read -r p; do
    echo "file${TAB}$p${TAB}$(sha "$TMP/tree/$p")"
done >> "$TMP/PIN.tsv"

rm -rf "$HERE/google"
cp -R "$TMP/tree/google" "$HERE/google"
cp "$TMP/LICENSE" "$HERE/LICENSE"
cp "$TMP/PIN.tsv" "$HERE/PIN.tsv"
echo "vendor.sh: vendored $(grep -c "^file$TAB" "$HERE/PIN.tsv") files at $COMMIT; build its proto_check targets (BUCK) to check them" >&2
