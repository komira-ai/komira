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

if [ -z "$SUBJECTS" ]; then
    SUBJECTS=$(mktemp "${TMPDIR:-/tmp}/komira_limits.XXXXXX")
    trap 'rm -f "$SUBJECTS"' EXIT
    ref=HEAD
    git -C "$ROOT" rev-parse --verify -q origin/main > /dev/null && ref=origin/main
    git -C "$ROOT" log --format=%s "$ref" > "$SUBJECTS" 2> /dev/null || true
fi

# The sites, excluding this check, its data, the check's own tests and prose.
EXCL=(':!tools/build/platforms/limits.tsv' ':!tools/build/tests/functional/platform_table' ':!*.md')
grep_tree() { git -C "$ROOT" grep --no-index --exclude-standard "$@" -- . "${EXCL[@]}" 2> /dev/null; }

# 1. the rows
declare -A retired_by
ids=()
n=0
while IFS=$'\t' read -r id by reason extra; do
    n=$((n + 1))
    case "$id" in '#'* | '') continue ;; id) continue ;; esac
    if [ -n "$extra" ] || [ -z "$reason" ]; then fail "limits.tsv line $n: want exactly three tab-separated columns (id, retired_by, reason)"; continue; fi
    if ! [[ "$id" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then fail "limits.tsv line $n: id \`$id\` is not lowercase words joined by dashes"; continue; fi
    if [ -n "${retired_by[$id]:-}" ]; then fail "limits.tsv line $n: id \`$id\` appears twice"; continue; fi
    if ! [[ "$by" =~ ^(never|native-pr:[0-9]+[a-z]?)$ ]]; then fail "limits.tsv line $n ($id): retired_by \`$by\` is neither \`never\` nor \`native-pr:<n>\`"; continue; fi
    if [ "$by" = never ] && [[ "$reason" != product:* ]]; then fail "limits.tsv line $n ($id): a limit that is never retired needs a reason starting \`product:\`"; continue; fi
    retired_by[$id]=$by
    ids+=("$id")
done < "$TSV"
[ "${#ids[@]}" -gt 0 ] || fail "limits.tsv lists no limit: an empty list is indistinguishable from an unchecked tree"

# 2. every target_compatible_with is declared
while IFS= read -r line; do
    case "$line" in *komira-limit:*) ;; *) fail "undeclared limit (a \`target_compatible_with\` with no \`komira-limit:<id>\` marker): ${line%%:*}:$(echo "$line" | cut -d: -f2)" ;; esac
done < <(grep_tree -n 'target_compatible_with')

# 3. markers against rows
declare -A site
while IFS= read -r hit; do
    where=${hit%%:komira-limit:*}
    id=${hit##*komira-limit:}
    site[$id]="${site[$id]:+${site[$id]} }$where"
done < <(grep_tree -n -o -E 'komira-limit:[a-z0-9]+(-[a-z0-9]+)*' | sed -E 's/^([^:]+):([0-9]+):/\1:\2:/')
for id in "${!site[@]}"; do
    [ -n "${retired_by[$id]:-}" ] || fail "marker \`komira-limit:$id\` at ${site[$id]} has no row in limits.tsv"
done
for id in "${ids[@]}"; do
    [ -n "${site[$id]:-}" ] || fail "row \`$id\` has no marker in the tree: its limit is gone, delete the row"
done

# 4. a merged retiring PR leaves no marker
for id in "${ids[@]}"; do
    by=${retired_by[$id]}
    [ "$by" = never ] && continue
    [ -n "${site[$id]:-}" ] || continue
    pr=${by#native-pr:}
    if grep -Eq "native-pr:${pr}([^0-9a-z]|\$)" "$SUBJECTS"; then
        fail "limit \`$id\` is retired by $by, whose PR has merged (a commit subject names it), but it is still declared at ${site[$id]}"
    fi
done

[ "$rc" = 0 ] && echo "PASS  limits: ${#ids[@]} limits, each declared at its site, none outliving its retiring PR"
exit "$rc"
