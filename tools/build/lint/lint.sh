# lint.sh -- the action behind the lint rules in defs.bzl.
# shellcheck shell=busybox
#
# usage: busybox sh lint.sh <busybox> <result.json> <kind> <stage> <prefix> [tools...] -- <args...>
#
# Runs one lint over its inputs and writes <result.json>, the validation
# result Buck2 reads (ValidationInfo): status
# "failure" with the findings as the message when there are any, "success"
# otherwise. The action itself succeeds either way; Buck2 fails any build or
# test whose graph holds the target. Only the pinned busybox, and the pinned
# tools passed in, run: PATH is busybox's applets and nothing else.
# The files linted are copies under <stage> (a buck-out directory; see _stage
# in defs.bzl); findings name them as <prefix><path in the package> instead,
# e.g. komira//tools/build/mojo/run_check.sh.
#
# kinds:
#   kind "shellcheck", tools <shellcheck>, args <file> <codes>...
#       Every file passes shellcheck at severity warning. A file with a shebang
#       is checked as its shebang says; one without that names its shell in a
#       `# shellcheck shell=` directive, as that shell; any other, which the
#       rules run as `busybox sh <file>`, as busybox. <codes> is `-` or the
#       comma-separated codes excluded for that file.
#   kind "actionlint", tools <actionlint> <shellcheck> <config>, args <workflow>...
#       The workflows pass actionlint (configured by <config>), with shellcheck
#       over their `run:` steps.
#   kind "action_pins", args <workflow>...
#       Every `uses:` names an action by a full 40-hex commit SHA, not a tag. A
#       local action (`uses: ./path`) is part of this checkout, so it has no
#       SHA to pin; its own file is among the <workflow>s, which pins what it uses.
#   kind "no_endpoint", args <.gitignore> <n> <buckconfig>*n <file>...
#       No committed buckconfig sets a remote-execution endpoint or instance
#       key, .gitignore ignores /.buckconfig.local, and no buckconfig or <file>
#       names a grpc:// or grpcs:// address outside the example.* domains.
#   kind "push_verdicts", args <workflow>...
#       A push-triggered workflow with a top-level `concurrency` group names
#       github.sha in it (read as text): GitHub keeps one pending run per
#       group and cancels it for a newer one, so a group shared by pushes
#       loses the middle push's run. Checks nothing, so fails, when no
#       workflow is push-triggered.
#   kind "mojo_deps", args <BUCK file> <.mojo file>...
#       The `deps` of the package's mojo_library name every `komira_*` module
#       the .mojo files import, by target name (`:komira_x`): the deps are a
#       superset of the imports. A library built from the .mojo files of one
#       package compiles only against the packages on its `-I` closure, so a
#       missing dep is a failure at build time, found here in review. The
#       library's own name is not an import to declare. Extra deps are not a
#       finding (a dep may be there for a macro or a link).
#   kind "retired_names", args <tree> <prefix of tree> <name>... -- <file>...
#       No file under <tree> (the cell's doc_tree, findings named <prefix of
#       tree><path>) and no <file> holds a <name> (a fixed string) on a line
#       that carries no YYYY-MM-DD date: a retired name survives only in a
#       dated history note. Checks nothing, so fails, when the tree holds no
#       file.
#   kind "doc_links", tools <inspect runnable dir>, args <tree> <unchecked> [<path> <tree>]...
#       Every relative link and #anchor in every .md file under <tree> resolves
#       to a file, directory or heading under <tree>, with each further tree
#       (another cell's) placed at its <path>. <unchecked> is `-` or a
#       comma-separated list of .md paths left out (planted dead links).
#       The reader is `inspect doc-links` (tools/build/inspect).
set -eu

BB=$1 RESULT=$2 KIND=$3 STAGE=$4 PREFIX=$5
shift 5
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
# Actions that run on this machine share the checkout root as their working
# directory, so scratch is per action: the directory buck2 names in
# BUCK_SCRATCH_PATH (unset on a remote worker, whose root is the action's own).
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.komira_action" ;;
    /*) T="$BUCK_SCRATCH_PATH/komira" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/komira" ;;
esac
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
export PATH
REPORT="$T/report.txt"

abs() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
: > "$REPORT"
checked=0

case "$KIND" in
shellcheck)
    SC=$(abs "$1"); shift
    [ "$1" = -- ] && shift
    while [ $# -ge 2 ]; do
        f=$1 codes=$2
        shift 2
        checked=$((checked + 1))
        opts="-S warning -f gcc"
        [ "$codes" = - ] || opts="$opts -e $codes"
        if ! head -1 "$f" | grep -q '^#!' && ! head -5 "$f" | grep -q '^# shellcheck shell='; then
            opts="$opts -s busybox"
        fi
        # shellcheck disable=SC2086 # opts is a list of words
        "$SC" $opts "$f" >> "$REPORT" 2>&1 || true
    done
    ;;
actionlint)
    AL=$(abs "$1") SC=$(abs "$2") CONF=$3; shift 3
    [ "$1" = -- ] && shift
    checked=$#
    "$AL" -no-color -config-file "$CONF" -shellcheck "$SC" "$@" >> "$REPORT" 2>&1 || true
    ;;
action_pins)
    [ "$1" = -- ] && shift
    for f in "$@"; do
        n=$(grep -cE '^[[:space:]]*(-[[:space:]]+)?uses:' "$f" || true)
        checked=$((checked + n))
        grep -nE '^[[:space:]]*(-[[:space:]]+)?uses:' "$f" |
            grep -vE 'uses:[[:space:]]*([^@[:space:]]+@[0-9a-f]{40}([[:space:]]|$)|\./)' |
            sed "s#^#$f:#;s#\$# -- not pinned to a full commit SHA#" >> "$REPORT" || true
    done
    ;;
no_endpoint)
    [ "$1" = -- ] && shift
    gitignore=$1 n=$2
    shift 2
    checked=$#
    i=0
    for buckconfig in "$@"; do
        i=$((i + 1))
        [ "$i" -le "$n" ] || break
        grep -nE '^[[:space:]]*(engine_address|action_cache_address|cas_address|address|instance_name|tls_ca_certs|http_headers)[[:space:]]*=' "$buckconfig" |
            sed "s#^#$buckconfig:#;s#\$# -- an endpoint belongs in .buckconfig.local or the machine's buckconfig#" >> "$REPORT" || true
    done
    grep -qxF /.buckconfig.local "$gitignore" ||
        echo "$gitignore: does not ignore /.buckconfig.local" >> "$REPORT"
    for f in "$@"; do
        grep -noE 'grpcs?://[^[:space:]"'"'"'/]+' "$f" | grep -vE '://[^:]*example\.[a-z]+(:[0-9]+)?$' |
            sed "s#^#$f:#;s#\$# -- a remote-execution address is committed#" >> "$REPORT" || true
    done
    ;;
push_verdicts)
    [ "$1" = -- ] && shift
    for f in "$@"; do
        # First line "push" when the workflow is push-triggered; then a finding
        # when its top-level concurrency group does not name github.sha.
        awk -v F="$f" '
            /^[^[:space:]#]/ {
                top = $0; sub(/[[:space:]]*:.*/, "", top); gsub(/"/, "", top)
                rest = $0; sub(/^[^:]*:[[:space:]]*/, "", rest)
                blk = top
                if (top == "on" && rest ~ /(^|[^a-z_])push([^a-z_]|$)/) push = 1
                if (top == "concurrency" && rest != "" && rest !~ /^#/) { group = rest; gline = NR; conc = 1 }
                next
            }
            blk == "on" && /^[[:space:]]+(-[[:space:]]+)?push[[:space:]]*(:|$)/ { push = 1 }
            blk == "concurrency" && /^[[:space:]]+group[[:space:]]*:/ { group = $0; gline = NR; conc = 1 }
            END {
                if (!push) exit
                print "push"
                if (conc && group !~ /github\.sha/)
                    print F ":" gline ": the concurrency group of a push-triggered workflow does not name github.sha, so a push can lose its run to a newer one"
            }' "$f" > "$T/pv.txt"
        if [ -s "$T/pv.txt" ]; then
            checked=$((checked + 1))
            sed 1d "$T/pv.txt" >> "$REPORT"
        fi
    done
    ;;
mojo_deps)
    [ "$1" = -- ] && shift
    buck=$1
    shift
    checked=$#
    self=$(sed -n 's/^[[:space:]]*name[[:space:]]*=[[:space:]]*"\([A-Za-z0-9_]*\)",.*/\1/p' "$buck" | head -1)
    # The target names inside `deps = [ ... ]`.
    awk '/^[[:space:]]*deps[[:space:]]*=[[:space:]]*\[/ { on = 1 }
         on { while (match($0, /:[A-Za-z0-9_]+"/)) { print substr($0, RSTART + 1, RLENGTH - 2); $0 = substr($0, RSTART + RLENGTH) } }
         on && /\]/ { on = 0 }' "$buck" | sort -u > "$T/declared"
    [ -n "$self" ] || echo "$buck: no mojo_library name found" >> "$REPORT"
    for f in "$@"; do
        grep -noE '^[[:space:]]*(from|import)[[:space:]]+komira_[A-Za-z0-9_]+' "$f" |
            sed -E 's/^([0-9]+):[[:space:]]*(from|import)[[:space:]]+/\1 /' | sort -k2,2 -u |
            while read -r line mod; do
                [ "$mod" = "$self" ] && continue
                grep -qx "$mod" "$T/declared" ||
                    echo "$f:$line: imports $mod, which the deps of $buck do not name (:$mod)" >> "$REPORT"
            done
    done
    ;;
retired_names)
    [ "$1" = -- ] && shift
    tree=$1 tprefix=$2
    shift 2
    : > "$T/names"
    while [ $# -gt 0 ] && [ "$1" != -- ]; do
        printf '%s\n' "$1" >> "$T/names"
        shift
    done
    [ $# -gt 0 ] && shift
    checked=$( (cd "$tree" && find . \( -type f -o -type l \) -print) | wc -l | tr -d ' ')
    checked=$((checked + $#))
    (cd "$tree" && grep -rnF -f "$T/names" . || true) | sed "s#^\./#$tprefix#" > "$T/rn.txt"
    for f in "$@"; do
        grep -nF -f "$T/names" "$f" | sed "s#^#$f:#" >> "$T/rn.txt" || true
    done
    grep -vE '[0-9]{4}-[0-9]{2}-[0-9]{2}' "$T/rn.txt" |
        sed 's#$# -- a retired name; only a dated history note may keep it#' >> "$REPORT" || true
    ;;
doc_links)
    INSPECT=$(abs "$1"); shift
    [ "$1" = -- ] && shift
    tree=$(cd "$1" && pwd -P)
    unchecked=$2
    shift 2
    if [ $# -gt 0 ]; then
        # Other cells' trees, each at its path: merge them into one copy.
        "$BB" cp -R "$tree" "$T/merged"
        "$BB" chmod -R u+w "$T/merged"
        while [ $# -ge 2 ]; do
            "$BB" mkdir -p "$T/merged/$1"
            "$BB" cp -R "$2/." "$T/merged/$1/"
            shift 2
        done
        tree=$(cd "$T/merged" && pwd -P)
    fi
    # Every file and link staged under the tree, as `git ls-files -z` lists
    # a checkout: the Markdown reader checks each .md among them.
    (cd "$tree" && find . \( -type f -o -type l \) -print) | sed 's#^\./##' |
        awk -v u="$unchecked" 'BEGIN { n = split(u, a, ","); for (i = 1; i <= n; i++) skip[a[i]] = 1 } !($0 in skip)' | tr '\n' '\000' > "$T/tree.list"
    if "$INSPECT/inspect" doc-links "$tree" "$T/tree.list" > "$T/doc_links.txt" 2>&1; then
        checked=$(sed -n 's/^PASS  doc links: all \([0-9]*\) relative links resolve$/\1/p' "$T/doc_links.txt")
    else
        checked=$(sed -n 's/^FAIL  doc links: [0-9]* of \([0-9]*\) .*/\1/p' "$T/doc_links.txt")
        grep -v '^PASS' "$T/doc_links.txt" >> "$REPORT" || true
        [ -s "$REPORT" ] || echo "inspect doc-links failed without a finding" >> "$REPORT"
    fi
    checked=${checked:-0}
    ;;
*)
    echo "lint.sh: unknown kind $KIND" >&2
    exit 2
    ;;
esac

if [ -s "$REPORT" ]; then
    sed "s#$STAGE/#$PREFIX#g" "$REPORT" > "$REPORT.named"
    mv "$REPORT.named" "$REPORT"
fi
[ "$checked" -gt 0 ] || echo "$KIND: checked nothing (no inputs, or no lines to check)" >> "$REPORT"

message() { # the report, as a JSON string body: at most 200 lines, escaped
    head -200 "$REPORT" | tr -d '\000-\010\013-\037' |
        awk '{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); printf "%s\\n", $0 }'
}
if [ -s "$REPORT" ]; then
    printf '{"version": 1, "data": {"status": "failure", "message": "%s: %s finding line(s)\\n%s"}}\n' \
        "$KIND" "$(wc -l < "$REPORT" | tr -d ' ')" "$(message)" > "$RESULT"
else
    printf '{"version": 1, "data": {"status": "success", "message": "%s: %s checked"}}\n' "$KIND" "$checked" > "$RESULT"
fi
rm -rf "$T"
