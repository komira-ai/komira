#!/usr/bin/env bash
# opt_level.sh -- tests compile at -O1, shipped code at -O3, and a target's
# own override wins. Reads the `mojo build` command of each target below from
# `buck2 aquery` (analysis only; nothing is built) and requires the
# `--optimization-level` value in the table.
#
# usage: tools/build/tests/functional/opt_level.sh [LOG_DIR]   (from the repo root; BUCK2 overrides the binary)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
BUCK2=${BUCK2:-$ROOT/buck2}
# shellcheck source=tools/build/tests/tool_lib.sh
. "$ROOT/tools/build/tests/tool_lib.sh"
LOG=${1:-${TMPDIR:-/tmp}}
out="$LOG/opt_level.json"

# label category level. A target listed here must have at least one action of
# that category, and every one of them must carry the level.
EXPECT="
komira//tools/build/examples:test_hellopkg mojo_build_test 1
komira//tools/build/examples/libgate_ok:libgate_ok mojo_build_test 1
komira//tools/build/examples/aws_lc:test_aws_lc mojo_build 1
komira//tools/build/examples/s2n_tls:test_s2n_handshake mojo_build 1
komira//tools/build/examples:hello mojo_build 3
komira//tools/build/examples:hello mojo_build_shared 3
komira//tools/build/examples:hello_pkg_user mojo_build 3
tests//functional/opt_level:test_o3 mojo_build_test 3
tests//functional/opt_level:lib_o3 mojo_build_test 3
tests//functional/opt_level:bin_o1 mojo_build 1
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
if ! inspect_tool json "$out" > "$out.tsv"; then
    echo "FAIL  optimization levels: inspect cannot read the aquery output (see $out.tsv)"
    exit 1
fi
awk -F '\t' -v EXPECT="$EXPECT" -v BUNDLE="$BUNDLE" '
    $2 == "category" { cat[$1] = $3 }
    $2 == "cmd" { cmd[$1] = $3 }
    function add(k, lv,    s) { # got[k]: the distinct levels, sorted, "/"-joined
        if (!(k in got)) { got[k] = lv; return }
        s = "/" got[k] "/"
        if (index(s, "/" lv "/")) return
        got[k] = got[k] "/" lv
        n = split(got[k], a, "/"); for (i = 2; i <= n; i++) for (j = i; j > 1 && a[j - 1] > a[j]; j--) { t = a[j]; a[j] = a[j - 1]; a[j - 1] = t }
        got[k] = a[1]; for (i = 2; i <= n; i++) got[k] = got[k] "/" a[i]
    }
    END {
        for (k in cat) {
            c = cat[k]
            if (c !~ /^mojo_build/ || !match(k, /\(target: `[^ `]+/)) continue
            label = substr(k, RSTART + 10, RLENGTH - 10)
            lv = "<none>"
            if (match(cmd[k], /, --optimization-level, [^,\]]*[,\]]/)) lv = substr(cmd[k], RSTART + 24, RLENGTH - 25)
            add(label SUBSEP c, lv)
        }
        bad = ""; ok = 0
        m = split(EXPECT, lines, "\n")
        for (i = 1; i <= m; i++) {
            if (split(lines[i], f, " ") != 3) continue
            k = f[1] SUBSEP f[2]
            if (!(k in got)) bad = bad "; " f[1] " has no " f[2] " action"
            else if (got[k] != f[3]) bad = bad "; " f[1] " " f[2] " at -O" got[k] ", expected -O" f[3]
            else ok++
        }
        shared = 0
        for (k in got) {
            split(k, p, SUBSEP)
            if (p[2] != "mojo_build_shared") continue
            shared++
            if (got[k] != "3") bad = bad "; " p[1] " " p[2] " at -O" got[k] ", expected -O3 (shared library)"
        }
        if (!shared) bad = bad "; " BUNDLE " reaches no mojo_build_shared action"
        if (bad != "") { print "FAIL  optimization levels: " substr(bad, 3); exit 1 }
        print "PASS  optimization levels: " ok " compile commands as declared (tests -O1; binaries and the bundle'"'"'s " shared " shared library action(s) -O3; overrides honoured)"
    }' "$out.tsv"
