#!/usr/bin/env bash
# opt_level.sh -- tests compile at -O1, shipped code at -O3, and a target's
# own override wins. Reads the `mojo build` command of each target below from
# `buck2 aquery` (analysis only; nothing is built) and requires the
# `--optimization-level` value in the table.
#
# usage: tools/build/checks/opt_level.sh [LOG_DIR]   (from the repo root; BUCK2 overrides the binary)
set -uo pipefail
BUCK2=${BUCK2:-$(cd "$(dirname "$0")/../../.." && pwd)/buck2}
LOG=${1:-${TMPDIR:-/tmp}}
out="$LOG/opt_level.json"

# label category level. A target listed here must have at least one action of
# that category, and every one of them must carry the level.
EXPECT="
komira//tools/build/examples:test_hellopkg mojo_build_test 1
komira//tools/build/examples/libgate_ok:libgate_ok mojo_build_test 1
komira//tools/build/examples/aws_lc:test_aws_lc mojo_build 1
komira//tools/build/examples/s2n_tls:test_s2n_handshake mojo_build 1
checks//numa:hello mojo_build 1
komira//tools/build/examples:hello mojo_build 3
komira//tools/build/examples:hello mojo_build_shared 3
komira//tools/build/examples:hello_pkg_user mojo_build 3
checks//opt_level:test_o3 mojo_build_test 3
checks//opt_level:lib_o3 mojo_build_test 3
checks//opt_level:bin_o1 mojo_build 1
"
# The bundle's shared libraries are found through the bundle, not listed.
BUNDLE=komira//tools/build/examples:hello_bundle

targets=$(printf '%s\n' "$EXPECT" | awk 'NF { print $1 }' | LC_ALL=C sort -u | tr '\n' ' ')
query="deps($BUNDLE)"
for t in $targets; do query="$query + deps($t)"; done
if ! "$BUCK2" aquery "$query" --output-attribute cmd --output-attribute category --json > "$out" 2> "$out.err"; then
    echo "FAIL  optimization levels: aquery failed (see $out.err)"
    exit 1
fi
EXPECT="$EXPECT" BUNDLE="$BUNDLE" python3 - "$out" <<'PY'
import json, os, re, sys
got = {}  # (label, category) -> set of levels
for key, a in json.load(open(sys.argv[1])).items():
    cat = a.get("category", "")
    if not cat.startswith("mojo_build"):
        continue
    label = re.match(r"\(target: `([^ `]+)", key).group(1)
    m = re.search(r", --optimization-level, ([^,\]]*)[,\]]", a.get("cmd", ""))
    got.setdefault((label, cat), set()).add(m.group(1) if m else "<none>")
bad, n = [], 0
for line in os.environ["EXPECT"].split("\n"):
    if not line.strip():
        continue
    label, cat, want = line.split()
    levels = got.get((label, cat))
    if not levels:
        bad.append("{} has no {} action".format(label, cat))
    elif levels != {want}:
        bad.append("{} {} at -O{}, expected -O{}".format(label, cat, "/".join(sorted(levels)), want))
    else:
        n += 1
shared = {k: v for k, v in got.items() if k[1] == "mojo_build_shared"}
if not shared:
    bad.append("{} reaches no mojo_build_shared action".format(os.environ["BUNDLE"]))
for (label, cat), levels in sorted(shared.items()):
    if levels != {"3"}:
        bad.append("{} {} at -O{}, expected -O3 (shared library)".format(label, cat, "/".join(sorted(levels))))
if bad:
    print("FAIL  optimization levels: " + "; ".join(bad))
    sys.exit(1)
print("PASS  optimization levels: {} compile commands as declared (tests -O1; binaries and the bundle's {} shared library action(s) -O3; overrides honoured)".format(n, len(shared)))
PY
