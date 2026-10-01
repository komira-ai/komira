#!/bin/sh
# upstream_version.sh: how far the googleapis pin in BUCK is behind upstream.
#
#   tools/vendor/googleapis/upstream_version.sh
#
# Prints the pinned commit, the head of googleapis's default branch, and, when
# they differ, which of the files BUCK extracts differ between the two (so a
# bump is needed only when one does). A report, not a gate: nothing in the
# build runs it, and it exits 0 whatever it finds; 3 when it cannot reach
# GitHub, so it never prints a pin as current that it did not compare.
# Needs git, curl and sha256sum.
set -eu

REPO=https://github.com/googleapis/googleapis
RAW=https://raw.githubusercontent.com/googleapis/googleapis
BUCK_FILE=$(dirname "$0")/BUCK

pinned=$(sed -n 's/^_COMMIT = "\([0-9a-f]*\)"$/\1/p' "$BUCK_FILE")
[ -n "$pinned" ] || { echo "upstream_version: no _COMMIT in $BUCK_FILE" >&2; exit 2; }
files=$(sed -n 's/^ *"\(google\/[^"]*\.proto\)",$/\1/p' "$BUCK_FILE" | LC_ALL=C sort -u)

head_line=$(git ls-remote "$REPO" HEAD) || { echo "upstream_version: cannot reach $REPO" >&2; exit 3; }
latest=$(printf '%s\n' "$head_line" | cut -f 1)
[ -n "$latest" ] || { echo "upstream_version: $REPO reports no HEAD" >&2; exit 3; }

echo "pinned:   $pinned"
echo "upstream: $latest (default branch head)"
if [ "$pinned" = "$latest" ]; then
    echo "up to date"
    exit 0
fi

T=$(mktemp)
trap 'rm -f "$T"' EXIT

# The sha256 of file $2 at commit $1; fails (and prints nothing) when the
# fetch does, so a failed fetch never reads as a changed file.
sha_at() {
    curl -sSfL -o "$T" "$RAW/$1/$2" 2> /dev/null || return 1
    sha256sum "$T" | cut -d ' ' -f 1
}

changed=0
for f in LICENSE $files; do
    a=$(sha_at "$pinned" "$f") || { echo "upstream_version: cannot fetch $f at $pinned" >&2; exit 3; }
    if ! b=$(sha_at "$latest" "$f"); then
        echo "  gone upstream: $f"
        changed=$((changed + 1))
    elif [ "$a" != "$b" ]; then
        echo "  changed:       $f"
        changed=$((changed + 1))
    fi
done
if [ "$changed" -eq 0 ]; then
    echo "behind, but none of the extracted files differ: no bump needed"
else
    echo "behind: $changed extracted file(s) differ; README.md says how to bump"
    echo "(a new import in a changed file shows up as a refusal of the bumped build)"
fi
