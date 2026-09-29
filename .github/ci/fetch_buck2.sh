#!/usr/bin/env bash
# fetch_buck2.sh -- install the buck2 that tools/buck2 pins, without dotslash.
#
# usage: .github/ci/fetch_buck2.sh <dest-dir> [platform]
#
# tools/buck2 is a DotSlash file: the release URL, size and sha256 of the
# pinned buck2 for each platform. This reads that file, so CI runs exactly
# the binary a developer's `tools/buck2` runs and there is no second pin to
# keep in step. The download is refused unless its size and sha256 match;
# the binary lands at <dest-dir>/buck2 and its path is printed on stdout.
# [platform] defaults to linux-x86_64. Needs curl, zstd, sha256sum, python3.
set -euo pipefail

[ $# -ge 1 ] && [ $# -le 2 ] || { echo "usage: $0 <dest-dir> [platform]" >&2; exit 2; }
dest=$1
platform=${2:-linux-x86_64}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# DotSlash files are JSON after a shebang line, with `//` comment lines.
read -r url size digest < <(python3 - "$ROOT/tools/buck2" "$platform" <<'PY'
import json, sys
path, platform = sys.argv[1], sys.argv[2]
lines = [l for l in open(path) if not l.lstrip().startswith(("#!", "//"))]
spec = json.loads("".join(lines))["platforms"].get(platform)
if spec is None:
    sys.exit(f"{path}: no entry for platform {platform}")
if spec["hash"] != "sha256" or spec["format"] != "zst":
    sys.exit(f"{path}: {platform}: expected a sha256-pinned zst artifact")
print(spec["providers"][0]["url"], spec["size"], spec["digest"])
PY
)

mkdir -p "$dest"
curl -fsSL --retry 3 -o "$dest/buck2.zst" "$url"
got_size=$(stat -c %s "$dest/buck2.zst")
[ "$got_size" = "$size" ] || { echo "buck2: size $got_size, pinned $size ($url)" >&2; exit 1; }
echo "$digest  $dest/buck2.zst" | sha256sum -c --quiet - >&2 ||
    { echo "buck2: sha256 does not match the pin in tools/buck2 ($url)" >&2; exit 1; }
zstd -q -d -f "$dest/buck2.zst" -o "$dest/buck2"
rm -f "$dest/buck2.zst"
chmod +x "$dest/buck2"
echo "$dest/buck2"
