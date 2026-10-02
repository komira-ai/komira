#!/usr/bin/env bash
# tools/build/tests/functional/platform_table/limits_retired.sh -- every limit of the build is declared, and none outlives the PR that retires it.
#
# usage: limits_retired.sh [--root DIR] [--subjects FILE]
#   --root      the tree to check (default: this checkout). Needs git; the tree need not be a repository.
#   --subjects  the commit subjects that count as merged (default: `git log` of origin/main, else HEAD, of --root)
#
# A limit is a place the build says it builds for one platform only. It is declared at its site by a
# `komira-limit:<id>` marker and listed in limits.tsv with the PR that deletes it. Exit 0 when:
#   1. limits.tsv is well formed: three columns, unique ids, `retired_by` is `native-pr:<n>` or `never`, a reason
#      (starting `product:` for `never`);
#   2. every `target_compatible_with` line in the tree carries a marker;
#   3. every marker names a row, and every row has a marker (a row whose limit is gone is deleted);
#   4. no row whose retiring PR has merged still has a marker.
# Prints one FAIL line per violation and exits 1. Reading "merged" from git history is what lets this fail: a limit
# whose PR landed and which is still there is a limit somebody forgot to delete.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../../../../.." && pwd)
SUBJECTS=
while [ $# -gt 0 ]; do
    case "$1" in
        --root) ROOT=$(cd "$2" && pwd) || exit 2; shift 2 ;;
        --subjects) SUBJECTS=$2; shift 2 ;;
        *) echo "limits_retired.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done
TSV="$ROOT/tools/build/platforms/limits.tsv"
[ -f "$TSV" ] || { echo "FAIL  limits: $TSV does not exist"; exit 1; }

rc=0
fail() { echo "FAIL  limits: $1"; rc=1; }

T=$(mktemp -d "${TMPDIR:-/tmp}/komira_limits.XXXXXX")
trap 'rm -rf "$T"' EXIT
if [ -z "$SUBJECTS" ]; then
    SUBJECTS=$T/subjects
    ref=HEAD
    git -C "$ROOT" rev-parse --verify -q origin/main > /dev/null 2>&1 && ref=origin/main
    if ! git -C "$ROOT" log --format=%s "$ref" > "$SUBJECTS" 2> /dev/null; then
        # No history to read: "no PR has merged" would be a guess, and a check that cannot fail is not a check.
        echo "FAIL  limits: $ROOT has no git history to read the merged PRs from (pass --subjects, or run it in a clone)"
        exit 1
    fi
fi

# The sites, excluding this check, its data, the check's own tests and prose.
EXCL=(':!tools/build/platforms/limits.tsv' ':!tools/build/tests/functional/platform_table' ':!*.md')
grep_tree() { git -C "$ROOT" grep --no-index --exclude-standard "$@" -- . "${EXCL[@]}" 2> /dev/null; }

# 1. the rows: $T/rows is `<id> <retired_by>` for each valid row
: > "$T/rows"
n=0
while IFS=$'\t' read -r id by reason extra; do
    n=$((n + 1))
    case "$id" in '#'* | '' | id) continue ;; esac
    if [ -n "$extra" ] || [ -z "$reason" ]; then fail "limits.tsv line $n: want exactly three tab-separated columns (id, retired_by, reason)"; continue; fi
    if ! [[ "$id" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then fail "limits.tsv line $n: id \`$id\` is not lowercase words joined by dashes"; continue; fi
    if grep -q "^$id " "$T/rows"; then fail "limits.tsv line $n: id \`$id\` appears twice"; continue; fi
    if ! [[ "$by" =~ ^(never|native-pr:[0-9]+[a-z]?)$ ]]; then fail "limits.tsv line $n ($id): retired_by \`$by\` is neither \`never\` nor \`native-pr:<n>\`"; continue; fi
    if [ "$by" = never ] && [[ "$reason" != product:* ]]; then fail "limits.tsv line $n ($id): a limit that is never retired needs a reason starting \`product:\`"; continue; fi
    echo "$id $by" >> "$T/rows"
done < "$TSV"
nrows=$(wc -l < "$T/rows" | tr -d ' ')
[ "$nrows" -gt 0 ] || fail "limits.tsv lists no limit: an empty list is indistinguishable from an unchecked tree"

# 2. every target_compatible_with is declared
grep_tree -n 'target_compatible_with' | grep -v 'komira-limit:' | while IFS= read -r line; do
    echo "FAIL  limits: undeclared limit (a \`target_compatible_with\` with no \`komira-limit:<id>\` marker): $(echo "$line" | cut -d: -f1,2)"
done > "$T/undeclared"
if [ -s "$T/undeclared" ]; then cat "$T/undeclared"; rc=1; fi

# 3. markers against rows: $T/sites is `<id> <file>:<line>`
grep_tree -n -o -E 'komira-limit:[a-z0-9]+(-[a-z0-9]+)*' | sed -E 's/^([^:]+:[0-9]+):komira-limit:(.*)$/\2 \1/' > "$T/sites"
while read -r id where; do
    grep -q "^$id " "$T/rows" || fail "marker \`komira-limit:$id\` at $where has no row in limits.tsv"
done < "$T/sites"
while read -r id by; do
    grep -q "^$id " "$T/sites" || fail "row \`$id\` has no marker in the tree: its limit is gone, delete the row"
done < "$T/rows"

# 4. a merged retiring PR leaves no marker
while read -r id by; do
    [ "$by" = never ] && continue
    where=$(grep "^$id " "$T/sites" | cut -d' ' -f2 | paste -sd' ' -)
    [ -n "$where" ] || continue
    pr=${by#native-pr:}
    if grep -Eq "native-pr:${pr}([^0-9a-z]|\$)" "$SUBJECTS"; then
        fail "limit \`$id\` is retired by $by, whose PR has merged (a commit subject names it), but it is still declared at $where"
    fi
done < "$T/rows"

[ "$rc" = 0 ] && echo "PASS  limits: $nrows limits, each declared at its site, none outliving its retiring PR"
exit "$rc"
