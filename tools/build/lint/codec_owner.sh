# codec_owner.sh -- the action behind codec_owner.bzl.
# shellcheck shell=busybox
#
# usage: busybox sh codec_owner.sh <busybox> <result.json> <tree> <prefix> <root> <owner>...
#
# Every codec library has one owner. No .mojo file under <tree>/<root>
# (<tree>: a doc_tree output, or a fixture's staged files; findings are named
# <prefix><path>) outside the <owner> directories (paths in the tree) holds:
#   * a snappy C symbol as a whole string literal, in double or single quotes
#     (so triple quotes too): `"snappy_<a-z, 0-9, _>"`, or with the komira_
#     prefix the vendored snappy exports once its symbols are prefixed,
#     `"komira_snappy_..."`; the name `external_call` declares, on its line
#     or the next;
#   * a codec library soname at the start of a string literal, either quote:
#     `"libz.so`, `"libzstd.so`, `"liblz4.so`, `"libbz2.so`, `"liblzma.so`,
#     `"libsnappy.so`, or the same names with `.dylib`;
#   * an import of the owners' implementation layers, `komira_zlib` or
#     `komira_lz4`: `from komira_zlib[.x] import ...`, `import komira_lz4[.x]`
#     (with or without `as`), and either name anywhere in an `import a, b`
#     list, first or not, with or without a space after the comma.
# A line whose first non-blank character is `#` is a comment, not a site; a
# site with a trailing comment is a site. Not covered: a name built from
# pieces (adjacent literals, `+`, formatting), a soname with a directory
# before it, and an import continued with a backslash.
# The owners must hold a snappy declaration (`"snappy_uncompress"` or
# `"komira_snappy_uncompress"`) and each of the five sonames between them,
# so the snappy arm and the soname arms cannot stop matching unnoticed: a
# missing one is a finding. The import arm and libsnappy have no such check
# (no owner declares libsnappy; it is linked); tests//negative/codec_owner
# pins them. Writes <result.json>, the validation
# result Buck2 reads (ValidationInfo): status "failure" with the findings as
# the message, else "success". Only the pinned busybox runs: PATH is its
# applets.
set -eu
BB=$1 RESULT=$2 TREE=$3 PREFIX=$4 ROOT=$5
shift 5
[ $# -gt 0 ] || { echo "codec_owner.sh: no owner" >&2; exit 2; }
OWNERS="$*"
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
: > "$T/files"
[ -d "$TREE/$ROOT" ] && (cd "$TREE" && find "$ROOT" -name '*.mojo' \( -type f -o -type l \) | sort) > "$T/files"
checked=$(wc -l < "$T/files" | tr -d ' ')
: > "$T/hits"
# The site patterns. Q is either quote.
Q="[\"']"
SITES="$Q(komira_)?snappy_[a-z0-9_]+$Q|${Q}lib(z|zstd|lz4|bz2|lzma|snappy)\\.(so|dylib)"
SITES="$SITES|^[[:space:]]*(from|import)[[:space:]]+komira_(zlib|lz4)([.[:space:],]|\$)"
SITES="$SITES|^[[:space:]]*import[[:space:]][^#]*[[:space:],]komira_(zlib|lz4)([.[:space:],]|\$)"
if [ "$checked" -gt 0 ]; then
    (cd "$TREE" && xargs grep -nE "$SITES" /dev/null < "$T/files" || true) > "$T/hits"
fi
awk -v OWNERS="$OWNERS" -v P="$PREFIX" -v SQ="'" '
    BEGIN {
        n = split(OWNERS, own, " ")
        q = "[\"" SQ "]"
        need["snappy"] = q "(komira_)?snappy_uncompress" q
        shown["snappy"] = "the snappy declarations (\"snappy_uncompress\" or \"komira_snappy_uncompress\")"
        split("libzstd libz liblz4 libbz2 liblzma", libs, " ")
        for (k in libs) {
            need[libs[k]] = q libs[k] "\\.so"
            shown[libs[k]] = "the " libs[k] " soname (\"" libs[k] ".so)"
        }
    }
    {
        i = index($0, ":"); f = substr($0, 1, i - 1); rest = substr($0, i + 1)
        j = index(rest, ":"); ln = substr(rest, 1, j - 1); text = substr(rest, j + 1)
        if (text ~ /^[[:space:]]*#/) next
        owned = 0
        for (k = 1; k <= n; k++) if (index(f, own[k] "/") == 1) owned = 1
        if (owned) {
            for (w in need) if (text ~ need[w]) found[w] = 1
            next
        }
        gsub(/[\t ]+/, " ", text); sub(/^ /, "", text)
        print P f ":" ln ": " text " -- codec FFI outside its owners (" OWNERS "): call komira_compression'"'"'s codec API"
    }
    END {
        for (w in need)
            if (!(w in found)) print "codec_owner: no owner file holds " shown[w] ", so the patterns match nothing"
    }' "$T/hits" | sort > "$T/report"
[ "$checked" -gt 0 ] || echo "codec_owner: checked nothing (no .mojo file under $ROOT)" >> "$T/report"
if [ -s "$T/report" ]; then
    msg=$(head -200 "$T/report" | tr -d '\000-\010\013-\037' |
        awk '{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); printf "%s\\n", $0 }')
    printf '{"version": 1, "data": {"status": "failure", "message": "codec_owner: %s finding line(s)\\n%s"}}\n' \
        "$(wc -l < "$T/report" | tr -d ' ')" "$msg" > "$RESULT"
else
    printf '{"version": 1, "data": {"status": "success", "message": "codec_owner: %s files checked"}}\n' "$checked" > "$RESULT"
fi
rm -rf "$T"
