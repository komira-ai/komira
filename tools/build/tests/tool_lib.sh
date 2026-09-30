# shellcheck shell=bash
# tool_lib.sh -- helpers the check scripts source (bash). Structured files
# (JSON, tar, Mach-O) are read by //tools/build/inspect:inspect, a Mojo tool
# built on the farm like everything else; these functions only drive it.
#
#   inspect_init           build the tool once (from this checkout, whatever
#                          the caller's directory) and export INSPECT_BIN
#   inspect_tool <cmd> ... run it (see tools/build/inspect/inspect.mojo)
#   cfg_value <sec.key>    one buckconfig value of the current directory's
#                          project; empty when unset
#   props_norm <a=b,c=d>   a property set, pieces trimmed and sorted, so two
#                          spellings of one set compare equal
#   whatran_actions <file> `buck2 log what-ran --format json` as one line per
#                          action: category, executor, sorted properties (-)

TOOL_LIB_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)

inspect_init() {
    [ -n "${INSPECT_BIN:-}" ] && [ -x "$INSPECT_BIN" ] && return 0
    local dir
    dir=$(cd "$TOOL_LIB_ROOT" && "${BUCK2:-$TOOL_LIB_ROOT/buck2}" build '//tools/build/inspect:inspect[runnable]' \
        --materializations all --show-full-simple-output 2> "${INSPECT_LOG:-/dev/null}" | tail -n 1)
    if [ -z "$dir" ] || [ ! -x "$dir/inspect" ]; then
        echo "tool_lib: cannot build //tools/build/inspect:inspect[runnable]${INSPECT_LOG:+ (see $INSPECT_LOG)}" >&2
        return 2
    fi
    INSPECT_BIN="$dir/inspect"
    export INSPECT_BIN
}

inspect_tool() {
    inspect_init || return 2
    "$INSPECT_BIN" "$@"
}

cfg_value() {
    local key=${1#*.}
    "${BUCK2:-$TOOL_LIB_ROOT/buck2}" audit config "$1" --style simple 2> /dev/null |
        sed -n "s/^    $key = //p" | head -n 1
}

props_norm() {
    printf '%s\n' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | LC_ALL=C sort | paste -sd, -
}

whatran_actions() {
    local t
    t=$(mktemp "${TMPDIR:-/tmp}/komira_whatran.XXXXXX") || return 2
    if ! inspect_tool json-lines "$1" > "$t"; then
        cat "$t" >&2
        rm -f "$t"
        return 2
    fi
    awk -F '\t' '$2 == "reproducer" && $3 == "details" && $4 == "platform_properties" && NF == 6 { print $1 "\t" $5 "=" $6 }' "$t" |
        LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2,2 |
        awk -F '\t' -v T="$t" '
            { if ($1 in props) props[$1] = props[$1] "," $2; else props[$1] = $2 }
            END {
                while ((getline line < T) > 0) {
                    split(line, f, "\t")
                    if (f[2] == "identity") id[f[1]] = f[3]
                    else if (f[2] == "reproducer" && f[3] == "executor") ex[f[1]] = f[4]
                }
                for (n in id) {
                    c = id[n]; s = c; cut = 0
                    while ((k = index(s, " (")) > 0) { cut += k + 1; s = substr(s, k + 2) }
                    if (cut > 0) c = substr(c, cut + 1)
                    sub(/\)+$/, "", c)
                    print c "\t" ((n in ex) ? ex[n] : "-") "\t" ((n in props) ? props[n] : "-")
                }
            }'
    rm -f "$t"
}
