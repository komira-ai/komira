#!/usr/bin/env bash
# tools/build/tests/golden/golden.sh -- the zero-execution check for the linux-x86_64 platform.
#
# usage: golden.sh gen [FILE]       write the golden (default: stdout)
#        golden.sh check [FILE]     regenerate it and diff against FILE (default: linux-x86_64.golden next to
#                                   this script); exit 1 on any difference, printing the differing lines
#        golden.sh tree             print the hash over the aquery of every target of //src and its
#                                   dependencies (not committed: every library PR changes //src)
#        golden.sh actions          build the sample targets and print one `<action>\t<digest>` line per
#                                   action (sorted): what-ran's action digests, the key the remote cache uses
#   run from the repo root; BUCK2 names the buck2 binary (default ./buck2).
#
# A change to a rule, a toolchain or the platform table that changes what an action runs changes a line of
# the golden, so a PR that must leave linux-x86_64 untouched shows an empty diff. The golden holds:
#   config   the platform and its configuration (`buck2 audit configurations`: the hash that is in every
#            output path and action key, and the constraints it is made of);
#   sample   per sample target, sha256 of `buck2 aquery` of the target and everything it depends on (command
#            line, category, identifier, kind of every action: not the executor or the properties, which
#            are the client's).
# The samples are targets the build system owns (tools/build, third_party), so a library PR does not move
# the committed golden; `tree` is the same hash over //src, compared by hand between a base and a PR.
# What aquery cannot show is an action's INPUT digests: `actions` mode builds the samples and reads them
# from what-ran. A source edit moves those, not the golden; that is why a golden says "rules and toolchains",
# not "the whole repository". `check` needs a client whose execution platforms include linux-x86_64.
set -uo pipefail

BUCK2=${BUCK2:-./buck2}
PLATFORM=komira//tools/build/platforms:linux-x86_64
HERE=$(cd "$(dirname "$0")" && pwd)
SAMPLES=(
    komira//tools/build/examples:hello
    komira//tools/build/examples:hellopkg
    komira//tools/build/examples:test_hellopkg
    komira//tools/build/toolchains:conda_unpack
    komira//tools/build/toolchains:zig_cc_launcher
    komira//tools/build/mojo:gate_runner.sh
    komira//third_party/snappy:snappy
    komira//tools/build/proto-codegen:komira_proto_codegen
)

sha() { if command -v sha256sum > /dev/null; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }

aq() { "$BUCK2" aquery --target-platforms "$PLATFORM" -a '^(cmd|category|identifier|kind)$' "$@" 2> /dev/null; }

gen() {
    local cfg
    cfg=$("$BUCK2" cquery --target-platforms "$PLATFORM" komira//tools/build/toolchains:conda_unpack 2> /dev/null | grep -o 'komira//tools/build/platforms:linux-x86_64#[0-9a-f]*' | head -n 1)
    [ -n "$cfg" ] || { echo "golden.sh: cannot read the configuration of $PLATFORM" >&2; return 1; }
    echo "# komira golden: linux-x86_64 (tools/build/tests/golden/golden.sh)"
    echo "config $cfg"
    "$BUCK2" audit configurations "$cfg" 2> /dev/null | sed 's/^/config /'
    local t out
    for t in "${SAMPLES[@]}"; do
        out=$(aq "deps($t)") || { echo "golden.sh: aquery of $t failed" >&2; return 1; }
        [ -n "$out" ] || { echo "golden.sh: aquery of $t is empty" >&2; return 1; }
        printf 'sample %s %s\n' "$(printf '%s' "$out" | sha)" "$t"
    done
}

tree() {
    local all out
    all=$("$BUCK2" targets //src/... 2> /dev/null | grep -v ':doc_tree$')
    [ -n "$all" ] || { echo "golden.sh: no target under //src" >&2; return 1; }
    # shellcheck disable=SC2086  # one argument per target
    out=$(aq 'deps(set(%s))' $all) || { echo "golden.sh: aquery of //src failed" >&2; return 1; }
    [ -n "$out" ] || { echo "golden.sh: aquery of //src is empty" >&2; return 1; }
    printf 'tree %s //src/...(%s targets)\n' "$(printf '%s' "$out" | sha)" "$(printf '%s\n' "$all" | wc -l | tr -d ' ')"
}

case "${1:-}" in
    tree) tree ;;
    gen)
        if [ -n "${2:-}" ]; then gen > "$2.tmp" && mv "$2.tmp" "$2"; else gen; fi
        ;;
    check)
        want=${2:-$HERE/linux-x86_64.golden}
        [ -s "$want" ] || { echo "FAIL  golden: $want is missing or empty"; exit 1; }
        got=$(gen) || { echo "FAIL  golden: cannot regenerate it"; exit 1; }
        if diff <(cat "$want") <(printf '%s\n' "$got") > /dev/null; then
            echo "PASS  golden: linux-x86_64 configuration and the sample action hashes equal $(basename "$want")"
        else
            echo "FAIL  golden: linux-x86_64 differs from $(basename "$want"):"
            diff <(cat "$want") <(printf '%s\n' "$got") | grep '^[<>]' | cut -c1-200
            exit 1
        fi
        ;;
    actions)
        "$BUCK2" build "${SAMPLES[@]}" > /dev/null 2>&1 || { echo "golden.sh: the sample build failed" >&2; exit 1; }
        "$BUCK2" log what-ran --format json 2> /dev/null |
            sed -E 's/.*"identity":"([^"]*)".*"digest":"([^"]*)".*/\1\t\2/' | LC_ALL=C sort -u
        ;;
    *)
        echo "usage: golden.sh gen [FILE] | check [FILE] | actions" >&2
        exit 2
        ;;
esac
