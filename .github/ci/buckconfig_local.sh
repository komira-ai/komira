#!/usr/bin/env bash
# buckconfig_local.sh -- CI's .buckconfig.local: write it from a secret, and
# keep the endpoints it names out of logs and uploaded artifacts.
#
# usage: .github/ci/buckconfig_local.sh write          (reads $BUCKCONFIG_LOCAL)
#        .github/ci/buckconfig_local.sh redact <dir>...
#
# write   writes .buckconfig.local in the repo root from the secret, refuses
#         one that sets no engine_address, and registers every address it
#         names (the whole value, host:port and host) with the runner's log
#         masking, one string at a time: GitHub masks a multi-line secret
#         unreliably, and masks nothing in uploaded artifacts.
# redact  replaces those same strings in every file under each <dir> with
#         <redacted> and deletes any copy of .buckconfig.local there, so a
#         failure's uploaded logs do not name the farm. (Artifacts of a
#         public repository can be downloaded by anyone.)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CONF=$ROOT/.buckconfig.local

# Prints each string to hide, one per line: every *_address value, its
# host:port and its host, and instance_name unless it is `default`.
secrets_of() {
    python3 - "$1" <<'PY'
import re, sys
out = set()
for line in open(sys.argv[1]):
    m = re.match(r"\s*([A-Za-z0-9_.-]+)\s*=\s*(\S.*?)\s*$", line)
    if not m:
        continue
    key, value = m.groups()
    if key.endswith("address"):
        out.add(value)
        hp = re.sub(r"^[a-z][a-z0-9+.-]*://", "", value).split("/")[0]
        out.add(hp)
        out.add(re.sub(r":\d+$", "", hp))
    elif key == "instance_name" and value != "default":
        out.add(value)
for s in sorted(out, key=len, reverse=True):
    if s:
        print(s)
PY
}

case "${1:-}" in
    write)
        [ -n "${BUCKCONFIG_LOCAL:-}" ] || { echo "BUCKCONFIG_LOCAL is empty: the repository secret is missing or withheld" >&2; exit 1; }
        umask 077
        printf '%s\n' "$BUCKCONFIG_LOCAL" > "$CONF"
        grep -qE '^\s*engine_address\s*=' "$CONF" || { echo ".buckconfig.local from the secret sets no engine_address" >&2; exit 1; }
        while IFS= read -r s; do echo "::add-mask::$s"; done < <(secrets_of "$CONF")
        echo "wrote .buckconfig.local ($(grep -c . "$CONF") lines)"
        ;;
    redact)
        shift
        [ -f "$CONF" ] || exit 0
        mapfile -t hide < <(secrets_of "$CONF")
        for d in "$@"; do
            [ -d "$d" ] || continue
            find "$d" -name .buckconfig.local -type f -delete
            find "$d" -type f -print0 | python3 -c '
import sys
hide = sys.argv[1:]
for path in sys.stdin.buffer.read().split(b"\0"):
    if not path:
        continue
    with open(path, "rb") as f:
        data = f.read()
    new = data
    for s in hide:
        new = new.replace(s.encode(), b"<redacted>")
    if new != data:
        with open(path, "wb") as f:
            f.write(new)
' "${hide[@]}"
        done
        ;;
    *)
        echo "usage: $0 write | redact <dir>..." >&2; exit 2 ;;
esac
