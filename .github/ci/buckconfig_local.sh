#!/usr/bin/env bash
# buckconfig_local.sh -- CI's .buckconfig.local: write it from a secret, and
# keep the endpoints it names out of logs and uploaded artifacts.
#
# usage: .github/ci/buckconfig_local.sh write          (reads $BUCKCONFIG_LOCAL)
#        .github/ci/buckconfig_local.sh redact <dir>...
#
# write   writes .buckconfig.local in the repo root from the secret. It
#         refuses one that sets no engine_address, one that names no
#         `[komira_re]` light and mojo_compile property sets or forces
#         `execution = local` (either builds on the runner), and one whose
#         instance_name is not a CI sub-instance: the last `/`-separated
#         component must be `ci` (for example `<prefix>/ci`). The remote
#         action cache keys entries by instance name, so CI's entries then
#         live apart from those of the people who use the same service.
#         It registers every address it names (the whole value, host:port
#         and host) with the runner's log masking, one string at a time:
#         GitHub masks a multi-line secret unreliably, and masks nothing in
#         uploaded artifacts.
# redact  replaces those same strings, and as a backstop every IPv4 address
#         in a private or shared (CGNAT) range, in every file under each
#         <dir> with <redacted>, and deletes any copy of .buckconfig.local
#         there. It then re-reads every file and fails if any of those
#         strings is still present. CI uploads the logs only if this step
#         succeeded, because artifacts of a public repository can be
#         downloaded by anyone.
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
        # Without both worker property sets a checkout builds locally, on the CI
        # runner itself (tools/build/platforms/default); refuse rather than do that.
        for key in light_properties mojo_compile_properties; do
            grep -qE "^\s*$key\s*=\s*\S" "$CONF" || { echo ".buckconfig.local from the secret sets no [komira_re] $key: CI would build locally" >&2; rm -f "$CONF"; exit 1; }
        done
        ! grep -qE '^\s*execution\s*=\s*local\s*$' "$CONF" || { echo ".buckconfig.local from the secret forces local execution" >&2; rm -f "$CONF"; exit 1; }
        inst=$(sed -nE 's/^[[:space:]]*instance_name[[:space:]]*=[[:space:]]*([^[:space:]]*)[[:space:]]*$/\1/p' "$CONF" | tail -1)
        [[ "$inst" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*/ci$ ]] || {
            echo ".buckconfig.local from the secret must set instance_name to a CI sub-instance, <prefix>/ci;" >&2
            echo "  CI must not share the action-cache namespace of developers' builds (see docs/ci.md)" >&2
            rm -f "$CONF"; exit 1; }
        while IFS= read -r s; do echo "::add-mask::$s"; done < <(secrets_of "$CONF")
        echo "wrote .buckconfig.local ($(grep -c . "$CONF") lines)"
        ;;
    redact)
        shift
        hide=()
        [ -f "$CONF" ] && mapfile -t hide < <(secrets_of "$CONF")
        for d in "$@"; do
            [ -d "$d" ] || continue
            find "$d" -name .buckconfig.local -type f -delete
            find "$d" -type f -print0 | python3 -c '
import re, sys
hide = [s.encode() for s in sys.argv[1:]]
# Backstop for strings the config does not name (error statuses can carry
# other hosts): 10/8, 172.16/12, 192.168/16 and 100.64/10.
ip = re.compile(rb"(?<![0-9.])(?:10\.(?:[0-9]{1,3}\.){2}[0-9]{1,3}"
                rb"|172\.(?:1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}"
                rb"|192\.168\.[0-9]{1,3}\.[0-9]{1,3}"
                rb"|100\.(?:6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3})(?![0-9])")
left = 0
for path in sys.stdin.buffer.read().split(b"\0"):
    if not path:
        continue
    with open(path, "rb") as f:
        data = f.read()
    new = data
    for s in hide:
        new = new.replace(s, b"<redacted>")
    new = ip.sub(b"<redacted>", new)
    if new != data:
        with open(path, "wb") as f:
            f.write(new)
    with open(path, "rb") as f:
        again = f.read()
    if any(s in again for s in hide) or ip.search(again):
        print("redact: still present after rewrite: %s" % path.decode(errors="replace"), file=sys.stderr)
        left += 1
sys.exit(1 if left else 0)
' "${hide[@]}"
        done
        ;;
    *)
        echo "usage: $0 write | redact <dir>..." >&2; exit 2 ;;
esac
