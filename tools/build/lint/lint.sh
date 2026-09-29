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
#       Every `uses:` names an action by a full 40-hex commit SHA, not a tag.
#   kind "no_endpoint", args <.buckconfig> <.gitignore> <file>...
#       The committed .buckconfig configures no remote-execution endpoint or
#       instance, .gitignore ignores /.buckconfig.local, and no <file> names a
#       grpc:// or grpcs:// address outside the example.* domains.
set -eu

BB=$1 RESULT=$2 KIND=$3 STAGE=$4 PREFIX=$5
shift 5
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
T="$PWD/.komira_action"
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
            grep -vE 'uses:[[:space:]]*[^@[:space:]]+@[0-9a-f]{40}([[:space:]]|$)' |
            sed "s#^#$f:#;s#\$# -- not pinned to a full commit SHA#" >> "$REPORT" || true
    done
    ;;
no_endpoint)
    [ "$1" = -- ] && shift
    buckconfig=$1 gitignore=$2
    checked=$#
    grep -nE '^[[:space:]]*(engine_address|action_cache_address|cas_address|address|instance_name|tls_ca_certs|http_headers)[[:space:]]*=' "$buckconfig" |
        sed "s#^#$buckconfig:#;s#\$# -- an endpoint belongs in .buckconfig.local or the machine's buckconfig#" >> "$REPORT" || true
    grep -qxF /.buckconfig.local "$gitignore" ||
        echo "$gitignore: does not ignore /.buckconfig.local" >> "$REPORT"
    for f in "$@"; do
        grep -noE 'grpcs?://[^[:space:]"'"'"'/]+' "$f" | grep -vE '://[^:]*example\.[a-z]+(:[0-9]+)?$' |
            sed "s#^#$f:#;s#\$# -- a remote-execution address is committed#" >> "$REPORT" || true
    done
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
