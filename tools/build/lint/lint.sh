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
#   kind "pointer_lint", tools <pointer_lint.awk>, args <public root> <ffi> <ffi name> <holds> <holds name>
#       The Mojo pointer rules over every .mojo file under <stage> (the tree;
#       pointer_lint.awk reads them and names the rules): no wildcard origin
#       outside a module's FFI internals (wildcard_origin), no
#       `unsafe_from_address=` (from_address), no partial move through a
#       pointer (partial_move), no `parallelize[` (parallelize), no second
#       declaration of libc read/open (libc_redeclare), no public function of
#       a library file under <public root> taking or returning a pointer
#       (public_pointer). Two ledgers, `#` lines and blank lines comments:
#       <ffi>, rows `<file> <reason>` tab-separated: the FFI modules, whose
#       wildcard origins are not sites; a row's file must hold a comment
#       line starting `# FFI-BOUNDARY:` and name a wildcard origin. <holds>, rows
#       `<rule> <file> <count> <reason>`: the sites that predate the lint. A
#       held file must have exactly <count> sites of that rule: more is a new
#       site, fewer is a row to lower or delete, so the holds only shrink. A
#       row naming no .mojo file of the tree, a repeated row, an unknown rule,
#       a bad count or an empty reason is a finding, in either ledger. The
#       <name>s are what findings call the ledgers. File names hold no
#       whitespace.
#   kind "public_boundary", tools <public_boundary.awk>, args <holds> <holds name> <hosts> <hosts name> <deny> <from> <public>
#       What a public repository may not hold, read from every file under
#       <stage> but binary data (by suffix: .arrow, .orc, .parquet, .avro,
#       .tensor, .frame, .request, .whl, .conda and archive, image and object
#       formats) and upstream bytes (third_party/ but its BUCK and .bzl
#       files, which are this repository's; tools/build/third_party_srcs/
#       testdata/, trimmed upstream trees): no date from the year <from> up to
#       <public>, the first day of the public history (date), home directory naming a person (home_path),
#       private or written-out network address (ip), URL host outside the
#       reserved example names and <hosts> (host), email address outside the
#       reserved example domains (email), commit id in prose (commit_sha), or
#       word of <deny> (deny). public_boundary.awk, the reader, says what each
#       rule matches. <holds>, rows `<rule> <file> <count> <reason>`, holds
#       the findings a file must keep (fixtures, test vectors), at an exact
#       count, so it only shrinks; <hosts>, rows `<domain> <reason>`, the
#       domains whose hosts a URL may name, each used by the tree; `#` lines
#       and blank lines are comments in both. <deny> is `-` or a list of
#       words kept outside the repository (one per line), which no row may
#       hold. The <name>s are what findings call the ledgers.
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
pointer_lint)
    AWK=$(abs "$1"); shift
    [ "$1" = -- ] && shift
    pubroot=$1 ffi=$2 ffi_name=$3 holds=$4 holds_name=$5
    (cd "$STAGE" && find . -name '*.mojo' \( -type f -o -type l \) | sed 's#^\./##' | sort) > "$T/files"
    checked=$(wc -l < "$T/files" | tr -d ' ')
    : > "$T/sites"
    : > "$T/marked"
    if [ "$checked" -gt 0 ]; then
        (cd "$STAGE" && xargs awk -v PUBLIC_ROOT="$pubroot/" -f "$AWK" < "$T/files") > "$T/sites"
        (cd "$STAGE" && xargs grep -l '^[[:space:]]*#[[:space:]]*FFI-BOUNDARY:' < "$T/files" || true) > "$T/marked"
    fi
    awk -F '\t' -v P="$STAGE/" -v FN="$ffi_name" -v HN="$holds_name" '
        BEGIN {
            rule["wildcard_origin"] = "a wildcard origin outside a module'"'"'s FFI internals"
            rule["from_address"] = "a pointer made from an integer (unsafe_from_address=)"
            rule["partial_move"] = "a partial move through a pointer: move the field out with Optional.take(), OwnedPointer.take(), swap or List.pop()"
            rule["parallelize"] = "the standard library'"'"'s parallelize[: run the work on a ParallelDispatch"
            rule["libc_redeclare"] = "a second declaration of libc read or open, which the standard library binds"
            rule["public_pointer"] = "a public function takes or returns a pointer"
            kinds = "wildcard_origin, from_address, partial_move, parallelize, libc_redeclare, public_pointer"
        }
        FILENAME == ARGV[1] { known[$0] = 1; next }
        FILENAME == ARGV[2] { marked[$0] = 1; next }
        FILENAME == ARGV[3] {
            if ($0 ~ /^[[:space:]]*(#|$)/) next
            where = FN ":" FNR ": "
            if (NF != 2) { print where "a row has 2 tab-separated fields (file, reason), not " NF; next }
            if (!($1 in known)) { print where $1 " is not a .mojo file of the tree; delete the row"; next }
            if ($2 !~ /[^[:space:]]/) { print where "empty reason: say which foreign resource the module owns"; next }
            if ($1 in ffi) { print where "a second row for " $1; next }
            if (!($1 in marked)) { print where $1 " carries no `# FFI-BOUNDARY:` comment line, so it is not an FFI module"; next }
            ffi[$1] = FNR
            next
        }
        FILENAME == ARGV[4] {
            if ($0 ~ /^[[:space:]]*(#|$)/) next
            where = HN ":" FNR ": "
            if (NF != 4) { print where "a row has 4 tab-separated fields (rule, file, count, reason), not " NF; next }
            if (!($1 in rule)) { print where "unknown rule `" $1 "` (rules: " kinds ")"; next }
            if (!($2 in known)) { print where $2 " is not a .mojo file of the tree; delete the row"; next }
            if ($3 !~ /^[1-9][0-9]*$/) { print where "count `" $3 "` is not a positive whole number"; next }
            if ($4 !~ /[^[:space:]]/) { print where "empty reason: say why this file still holds the sites"; next }
            k = $1 SUBSEP $2
            if (k in held) { print where "a second row for " $1 " in " $2; next }
            held[k] = $3; hrow[k] = FNR
            next
        }
        {
            if ($1 == "wildcard_origin" && ($2 in ffi)) { fsites[$2]++; next }
            k = $1 SUBSEP $2
            n[k]++
            site[k, n[k]] = P $2 ":" $3 ": " $1 ": " $4
        }
        END {
            for (k in n) {
                h = (k in held) ? held[k] : 0
                if (n[k] <= h) continue
                split(k, kf, SUBSEP)
                for (i = 1; i <= n[k]; i++)
                    print site[k, i] " -- " rule[kf[1]] (h ? " (" n[k] " sites, held " h ")" : "")
            }
            for (k in held) {
                c = (k in n) ? n[k] : 0
                if (c >= held[k]) continue
                split(k, kf, SUBSEP)
                print HN ":" hrow[k] ": " kf[1] " in " kf[2] " is held at " held[k] " and has " c ": " (c ? "lower the count to " c : "delete the row")
            }
            for (f in ffi)
                if (!(f in fsites)) print FN ":" ffi[f] ": " f " names no wildcard origin; delete the row"
        }' "$T/files" "$T/marked" "$ffi" "$holds" "$T/sites" | sort >> "$REPORT"
    ;;
public_boundary)
    AWK=$(abs "$1"); shift
    [ "$1" = -- ] && shift
    holds=$(abs "$1") holds_name=$2 hosts=$(abs "$3") hosts_name=$4 deny=$5 from=$6 public=$7
    if [ "$deny" = - ]; then deny=/dev/null; else deny=$(abs "$deny"); fi
    # Every file but binary data and upstream bytes (see the kind's note).
    (cd "$STAGE" && find . \( -type f -o -type l \) | sed 's#^\./##') |
        grep -vE '^tools/build/third_party_srcs/testdata/|\.(arrow|orc|parquet|avro|tensor|frame|request|whl|conda|gz|tgz|xz|zst|bz2|tar|zip|jar|png|jpg|jpeg|gif|ico|pdf|der|so|a|o|dylib|wasm|mojoc|mojopkg)$' |
        grep -vE '^third_party/' > "$T/files" || true
    (cd "$STAGE" && find third_party \( -type f -o -type l \) 2>/dev/null | grep -E '(^|/)BUCK$|\.bzl$' >> "$T/files" || true)
    sort -o "$T/files" "$T/files"
    checked=$(wc -l < "$T/files" | tr -d ' ')
    # A reader that fails is a finding, never a pass.
    if ! (cd "$STAGE" && awk -F '\t' -v P="$STAGE/" -v HN="$holds_name" -v AN="$hosts_name" -v FROM="$from" -v PUBLIC="$public" -f "$AWK" "$T/files" "$hosts" "$deny" "$holds") > "$T/pb.txt" 2> "$T/pb.err"; then
        echo "public_boundary: the reader failed: $(head -3 "$T/pb.err")" >> "$REPORT"
    fi
    sort "$T/pb.txt" >> "$REPORT"
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
