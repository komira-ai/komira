#!/usr/bin/env bash
# coverage_platforms.sh -- coverage is measured on linux-x86_64 and never on
# another platform (tools/build/platforms/limits.tsv, `coverage-linux-x86-64`):
# on another target platform the switch is a no-op (test 41). With
# --target-platforms darwin-arm64 (the one other registered platform; a
# reserved row such as linux-arm64 is no target platform yet) and
# `-c komira.coverage=true`, for the targets below (a library and a shared
# library whose coverage comes from the switch, and a library and a shared
# library of the tests cell that force it, whose attributes go through the
# same `select`), requires:
#
#   - cquery: none has a coverage attribute set (coverage_debug,
#     coverage_run, coverage_branch, coverage_gate): the `select` of
#     tools/build/mojo/coverage.bzl gives them None there;
#   - aquery: their actions are exactly those with `-c komira.coverage=false`
#     on the same platform, each with the same command line, so none is a
#     coverage action and none waits for one.
#
# The macOS execution platform is registered with placeholder keys
# (`komira_re.darwin_arm64_properties`, `komira_re.darwin_macos_hosts`, as
# darwin/check.sh does): analysis only, nothing runs.
#
# usage: tools/build/tests/functional/coverage_platforms.sh [LOG_DIR]   (from the repo root; BUCK2 overrides the binary)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
BUCK2=${BUCK2:-$ROOT/buck2}
# shellcheck source=tools/build/tests/tool_lib.sh
. "$ROOT/tools/build/tests/tool_lib.sh"
LOG=${1:-${TMPDIR:-/tmp}}

TARGETS=(
    tests//functional/coverage:covlib
    tests//functional/coverage:covlib_forced
    komira//tools/build/examples/shared_lib:plain
    tests//functional/coverage:covso
)
DARWIN=(--target-platforms komira//tools/build/platforms:darwin-arm64
    -c komira_re.darwin_arm64_properties=pool=unreachable-check-only -c komira_re.darwin_macos_hosts=0.0-check)

fail() {
    echo "FAIL  coverage platforms: $*"
    exit 1
}

set_q="set(${TARGETS[*]})"
"$BUCK2" cquery "$set_q" "${DARWIN[@]}" -c komira.coverage=true -a '^coverage_(debug|run|branch|gate)$' --json > "$LOG/coverage_platforms.attrs.json" 2> "$LOG/coverage_platforms.err" ||
    fail "cquery on darwin-arm64 failed (see $LOG/coverage_platforms.err)"
inspect_tool json "$LOG/coverage_platforms.attrs.json" > "$LOG/coverage_platforms.attrs.tsv" ||
    fail "inspect cannot read $LOG/coverage_platforms.attrs.json"
# The libraries have the four attributes, the shared libraries three (no
# coverage_branch); each must be null.
na=$(awk -F '\t' '$2 ~ /^coverage_(debug|run|branch|gate)$/' "$LOG/coverage_platforms.attrs.tsv" | wc -l)
set=$(awk -F '\t' '$2 ~ /^coverage_(debug|run|branch|gate)$/ && $3 != "null" { print $1 " " $2 " = " $3 }' "$LOG/coverage_platforms.attrs.tsv")
[ "$na" -eq 14 ] || fail "on darwin-arm64 the cquery read $na coverage attributes of ${#TARGETS[@]} targets, expected 14 (4 per library, 3 per shared library; see $LOG/coverage_platforms.attrs.tsv)"
[ -z "$set" ] || fail "on darwin-arm64 with komira.coverage=true, coverage attributes are set: $(printf '%s\n' "$set" | head -n 3 | paste -sd ';' -)"

q=""
for t in "${TARGETS[@]}"; do q="$q + all_actions($t)"; done
for c in false true; do
    "$BUCK2" aquery "${q# + }" "${DARWIN[@]}" -c "komira.coverage=$c" -a '^(category|identifier|cmd)$' --json > "$LOG/coverage_platforms_$c.json" 2>> "$LOG/coverage_platforms.err" ||
        fail "aquery on darwin-arm64 with komira.coverage=$c failed (see $LOG/coverage_platforms.err)"
    inspect_tool json "$LOG/coverage_platforms_$c.json" > "$LOG/coverage_platforms_$c.tsv" ||
        fail "inspect cannot read $LOG/coverage_platforms_$c.json"
    # `<label>|<category>|<identifier> TAB <cmd>` per action.
    awk -F '\t' '
        function label(n) { return match(n, /target: `[^ `]+/) ? substr(n, RSTART + 9, RLENGTH - 9) : "" }
        $2 == "category" { cat[$1] = $3 }
        $2 == "identifier" { id[$1] = $3 }
        $2 == "cmd" { cmd[$1] = $3 }
        { a[$1] = 1 }
        END { for (n in a) print label(n) "|" cat[n] "|" id[n] "\t" cmd[n] }' "$LOG/coverage_platforms_$c.tsv" |
        LC_ALL=C sort > "$LOG/coverage_platforms_$c.facts" || fail "cannot read the actions of komira.coverage=$c"
done
n=$(grep -c . "$LOG/coverage_platforms_false.facts")
nl=$(cut -d '|' -f 1 "$LOG/coverage_platforms_false.facts" | sort -u | grep -c .)
[ "$nl" -eq "${#TARGETS[@]}" ] || fail "with komira.coverage=false the aquery on darwin-arm64 gave actions of $nl of ${#TARGETS[@]} targets (see $LOG/coverage_platforms_false.facts)"
if ! cmp -s "$LOG/coverage_platforms_false.facts" "$LOG/coverage_platforms_true.facts"; then
    fail "on darwin-arm64 the actions differ with komira.coverage=true: $(diff "$LOG/coverage_platforms_false.facts" "$LOG/coverage_platforms_true.facts" | grep '^[<>]' | cut -f 1 | head -n 4 | paste -sd ';' -) (see $LOG/coverage_platforms_false.facts and _true.facts)"
fi
echo "PASS  coverage platforms: on darwin-arm64 with -c komira.coverage=true, the ${#TARGETS[@]} targets have no coverage attribute set (14 read) and their $n actions are those with it off, command lines included: coverage is a no-op off linux-x86_64"
