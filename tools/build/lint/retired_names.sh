# retired_names.sh -- the action behind retired_names.bzl.
# shellcheck shell=busybox
#
# usage: busybox sh retired_names.sh <busybox> <result.json> <tree> <prefix> <name>... -- <file>...
#
# No file under <tree> (a doc_tree output: the root one holds every file of
# the cell; findings are named <prefix><path>) and no <file> (the dotfiles a
# glob skips) holds a <name>, a fixed string, on a line that carries no
# YYYY-MM-DD date: a renamed package or type keeps its old name only in a
# dated history note. Writes <result.json>, the validation result Buck2 reads
# (ValidationInfo): status "failure" with the findings as the message, else
# "success". Checks nothing, so fails, when the tree holds no file. Only the
# pinned busybox runs: PATH is its applets.
set -eu
BB=$1 RESULT=$2 TREE=$3 PREFIX=$4
shift 4
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
# Scratch is per action, as in lint.sh: BUCK_SCRATCH_PATH, unset on a remote
# worker, whose root is the action's own.
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.komira_action" ;;
    /*) T="$BUCK_SCRATCH_PATH/komira" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/komira" ;;
esac
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
export PATH
: > "$T/names"
while [ $# -gt 0 ] && [ "$1" != -- ]; do
    printf '%s\n' "$1" >> "$T/names"
    shift
done
[ $# -gt 0 ] && shift
[ -s "$T/names" ] || { echo "retired_names.sh: no names" >&2; exit 2; }
checked=$( (cd "$TREE" && find . \( -type f -o -type l \) -print) | wc -l | tr -d ' ')
checked=$((checked + $#))
(cd "$TREE" && grep -rnF -f "$T/names" . || true) | sed "s#^\./#$PREFIX#" > "$T/hits"
for f in "$@"; do
    grep -nF -f "$T/names" "$f" | sed "s#^#$f:#" >> "$T/hits" || true
done
grep -vE '[0-9]{4}-[0-9]{2}-[0-9]{2}' "$T/hits" |
    sed 's#$# -- a retired name; only a dated history note may keep it#' > "$T/report" || true
[ "$checked" -gt 0 ] || echo "retired_names: checked nothing (an empty tree)" >> "$T/report"
if [ -s "$T/report" ]; then
    msg=$(head -200 "$T/report" | tr -d '\000-\010\013-\037' |
        awk '{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); printf "%s\\n", $0 }')
    printf '{"version": 1, "data": {"status": "failure", "message": "retired_names: %s finding line(s)\\n%s"}}\n' \
        "$(wc -l < "$T/report" | tr -d ' ')" "$msg" > "$RESULT"
else
    printf '{"version": 1, "data": {"status": "success", "message": "retired_names: %s files checked"}}\n' "$checked" > "$RESULT"
fi
rm -rf "$T"
