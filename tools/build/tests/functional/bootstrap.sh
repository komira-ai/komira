#!/usr/bin/env bash
# bootstrap.sh -- the ./buck2 bootstrap installs only what tools/buck2 pins.
#
# usage: tools/build/tests/functional/bootstrap.sh <scratch-dir>
#
# Runs the repository's ./buck2 script in <scratch-dir> against a made-up
# release: a small shell script, compressed with zstd and served from a
# file:// URL, described by a pin file in the layout of tools/buck2. No
# network, no real buck2. Needs what ./buck2 needs (curl, zstd, sha256sum
# or shasum).
#
#   a. A matching pin installs the release into the cache and runs it with
#      the caller's arguments; a second run uses the cache.
#   b. A pin whose sha256 does not match is refused, and nothing is cached.
#   c. A pin whose size does not match is refused, and nothing is cached.
#   d. The real tools/buck2 is read as ./buck2 reads it: the fields for both
#      platforms are a 64-hex sha256, a size, and a .zst release URL.
set -euo pipefail

[ $# = 1 ] || { echo "usage: $0 <scratch-dir>" >&2; exit 2; }
S=$1
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
fails=0
pass() { echo "PASS  bootstrap: $1"; }
fail() { echo "FAIL  bootstrap: $1"; fails=$((fails + 1)); }
sha() { if command -v sha256sum > /dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

rm -rf "$S"
mkdir -p "$S/release"
printf '#!/bin/sh\necho "made-up buck2: $*"\n' > "$S/release/buck2"
zstd -q "$S/release/buck2" -o "$S/release/buck2.zst"
SIZE=$(wc -c < "$S/release/buck2.zst" | tr -d ' ')
DIGEST=$(sha "$S/release/buck2.zst")

# A checkout holding ./buck2 and a pin in the layout of tools/buck2: every
# platform entry gets the given size, digest and URL.
checkout() { # dir size digest
    mkdir -p "$1/tools"
    cp "$ROOT/buck2" "$1/buck2"
    sed -E -e "s#\"size\": [0-9]+#\"size\": $2#" \
        -e "s#\"digest\": \"[0-9a-f]+\"#\"digest\": \"$3\"#" \
        -e "s#\"url\": \"[^\"]+\"#\"url\": \"file://$S/release/buck2.zst\"#" \
        "$ROOT/tools/buck2" > "$1/tools/buck2"
}

# a
checkout "$S/good" "$SIZE" "$DIGEST"
if ! out=$(XDG_CACHE_HOME="$S/cache" "$S/good/buck2" build //x 2> "$S/good.err"); then
    fail "a matching pin did not run: $(head -3 "$S/good.err")"
elif [ "$out" != "made-up buck2: build //x" ]; then
    fail "a matching pin ran something else: $out"
elif [ ! -x "$S/cache/komira/buck2/$DIGEST/buck2" ]; then
    fail "a matching pin ran but cached nothing at komira/buck2/<sha256>/buck2"
elif ! out=$(XDG_CACHE_HOME="$S/cache" "$S/good/buck2" again 2> "$S/good2.err") || [ "$out" != "made-up buck2: again" ] || [ -s "$S/good2.err" ]; then
    fail "the second run did not come straight from the cache: $(head -3 "$S/good2.err")"
else
    pass "a matching pin installs, runs with the caller's arguments, and is cached"
fi

# b, c
refused() { # name size digest wanted-message
    checkout "$S/$1" "$2" "$3"
    if XDG_CACHE_HOME="$S/cache_$1" "$S/$1/buck2" --version > "$S/$1.out" 2> "$S/$1.err"; then
        fail "$1: ran although the pin does not match"
    elif ! grep -qF "$4" "$S/$1.err"; then
        fail "$1: refused without saying \"$4\": $(head -3 "$S/$1.err")"
    elif [ -n "$(find "$S/cache_$1" -type f 2> /dev/null)" ]; then
        fail "$1: refused but left files in the cache: $(find "$S/cache_$1" -type f | head -3)"
    else
        pass "$1: refused, cache left empty"
    fi
}
refused wrong_sha256 "$SIZE" "$(printf '%064d' 0)" "tools/buck2 pins $(printf '%064d' 0)"
refused wrong_size $((SIZE + 1)) "$DIGEST" "tools/buck2 pins $((SIZE + 1))"

# d
bad=""
for p in linux-x86_64 macos-aarch64; do
    row=$(awk -v p="\"$p\":" 'index($0, p) { f = 1 } f && /"(size|digest|url)"/ { printf "%s ", $0 } f && /"url"/ { exit }' "$ROOT/tools/buck2")
    echo "$row" | grep -Eq '"size": [0-9]+,' || bad="$bad $p:size"
    echo "$row" | grep -Eq '"digest": "[0-9a-f]{64}"' || bad="$bad $p:digest"
    echo "$row" | grep -Eq '"url": "https://[^"]+\.zst"' || bad="$bad $p:url"
done
if [ -n "$bad" ]; then fail "tools/buck2 is not in the layout ./buck2 reads:$bad"; else pass "tools/buck2 has a size, sha256 and .zst URL for both platforms"; fi

[ "$fails" = 0 ]
