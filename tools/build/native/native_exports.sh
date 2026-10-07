#!/bin/sh
# The export list and version script of libkomira_native.so.1 (README.md,
# "One shared library"), written by a build action of a `komira_native`
# target (komira_native.bzl):
#   sh native_exports.sh <busybox> <elfsyms> <exports.txt> <version.map> <report.txt> \
#       [--shared <label> <lib.a>]... [--per-library <label> <lib.a>]... [--caller <label> <src dir>]...
# The exports are the names the callers' Mojo sources pass to
# `external_call["..."]` that a --shared archive defines with default
# visibility: exactly what Mojo code calls, so everything else in the library
# (aws-lc's and s2n-tls's internals, snappy's C++, the C++ runtime) is local.
# <version.map> exports them and makes every other symbol local.
#
# A call site is `external_call[` then, on that line or a later one, the
# quoted name. Triple-quoted strings (docstrings) are dropped, and so is a
# `#` comment on every line, so a name written only in prose is no call site.
# native_callsite_check.sh reads the call sites again with a tokenizer
# (callsites.c) and holds the library's exports to its reading.
#
# Fails (exit 1, naming each offender) when
#   - a symbol is defined (global, weak or common) by two --shared archives:
#     one owner per C symbol. A strong pair fails the link; a weak or common
#     pair would link, the linker keeping one of them silently, so it is
#     refused too;
#   - a called name is defined by a --shared archive only with hidden
#     visibility: the library could not export it;
#   - a called komira_* name is defined by no --shared and no --per-library
#     archive, or by both kinds;
#   - a --shared archive defines none of the exports (nothing calls it), or a
#     --caller calls none of them (it is not a caller).
set -eu
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail
set -o pipefail

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
BB=$(abs "$1")
TOOL=$(abs "$2")
EXPORTS=$(abs "$3")
MAP=$(abs "$4")
REPORT=$(abs "$5")
shift 5

case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.native_exports" ;;
    /*) T="$BUCK_SCRATCH_PATH/native_exports" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/native_exports" ;;
esac
"$BB" mkdir -p "$T/bin" "$T/shared" "$T/perlib" "$T/callers"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
export PATH LC_ALL=C

red=0
fail() { # file, what
    if [ -s "$1" ]; then
        red=1
        echo "native_exports RED: $2:" >&2
        sed 's/^/  /' "$1" | head -n 50 >&2
    fi
}

# Every call site name in the .mojo files under a directory, one per line.
# Per file: docstrings ("""...""" or '''...''', across lines) are dropped,
# then each line's `#` comment, then a line ending in `external_call[` (with
# nothing after it but space) is joined to the next line.
calls_in() {
    find "$1" -name '*.mojo' -type f | sort | while IFS= read -r f; do
        awk '
            function strip(s,    out, i, q) {
                out = ""
                while (s != "") {
                    if (doc != "") {
                        i = index(s, doc)
                        if (i == 0) return out
                        s = substr(s, i + 3); doc = ""
                        continue
                    }
                    i = match(s, /"""|\047\047\047/)
                    if (i == 0) { out = out s; break }
                    out = out substr(s, 1, i - 1); doc = substr(s, i, 3); s = substr(s, i + 3)
                }
                sub(/#.*/, "", out)
                return out
            }
            {
                line = pending strip($0)
                if (line ~ /external_call\[[ \t]*$/) { pending = line; next }
                pending = ""
                while (match(line, /external_call\[[ \t]*"[A-Za-z0-9_]+"/)) {
                    m = substr(line, RSTART, RLENGTH)
                    sub(/^[^"]*"/, "", m); sub(/"$/, "", m)
                    print m
                    line = substr(line, RSTART + RLENGTH)
                }
            }' "$f"
    done | sort -u
}

ns=0
np=0
nc=0
while [ $# -gt 0 ]; do
    [ $# -ge 3 ] || { echo "native_exports: '$1' needs a label and a path" >&2; exit 2; }
    kind=$1
    label=$2
    path=$(abs "$3")
    shift 3
    case "$kind" in
        --shared)
            ns=$((ns + 1))
            d="$T/shared/$(printf %03d "$ns")"
            mkdir "$d"
            echo "$label" > "$d/label"
            "$TOOL" symtab "$path" > "$d/symtab.txt"
            # Field 1 DEF|UND, 2 binding, 3 type, 4 visibility, 5 name.
            awk '$1 == "DEF" { print $5 }' "$d/symtab.txt" | sort -u > "$d/def.txt"
            awk '$1 == "DEF" && ($4 == "DEFAULT" || $4 == "PROTECTED") { print $5 }' "$d/symtab.txt" | sort -u > "$d/visible.txt"
            awk '$1 == "DEF" && $2 != "LOCAL" { print $5 }' "$d/symtab.txt" | sort -u > "$d/owned.txt"
            ;;
        --per-library)
            np=$((np + 1))
            d="$T/perlib/$(printf %03d "$np")"
            mkdir "$d"
            echo "$label" > "$d/label"
            "$TOOL" symtab "$path" | awk '$1 == "DEF" { print $5 }' | sort -u > "$d/def.txt"
            ;;
        --caller)
            [ -d "$path" ] || { echo "native_exports: $label: $path is not a directory" >&2; exit 2; }
            nc=$((nc + 1))
            d="$T/callers/$(printf %03d "$nc")"
            mkdir "$d"
            echo "$label" > "$d/label"
            calls_in "$path" > "$d/calls.txt"
            ;;
        *)
            echo "native_exports: unknown argument '$kind'" >&2
            exit 2
            ;;
    esac
done
[ "$ns" -gt 0 ] || { echo "native_exports: no --shared archive" >&2; exit 2; }
[ "$nc" -gt 0 ] || { echo "native_exports: no --caller" >&2; exit 2; }

cat "$T"/shared/*/def.txt | sort -u > "$T/def.txt"
cat "$T"/shared/*/visible.txt | sort -u > "$T/visible.txt"
cat "$T"/callers/*/calls.txt | sort -u > "$T/calls.txt"
: > "$T/perlib_def.txt"
if [ "$np" -gt 0 ]; then
    cat "$T"/perlib/*/def.txt | sort -u > "$T/perlib_def.txt"
fi

# One owner per C symbol: a definition (strong, weak or common) in two archives.
: > "$T/dup.txt"
for d in "$T"/shared/*; do
    sed "s|\$| $(cat "$d/label")|" "$d/owned.txt"
done | sort > "$T/owners.txt"
awk '{ n[$1]++; o[$1] = o[$1] " " $2 } END { for (s in n) if (n[s] > 1) print s ":" o[s] }' "$T/owners.txt" | sort > "$T/dup.txt"
fail "$T/dup.txt" "symbols defined by more than one archive (one owner per C symbol)"

comm -12 "$T/calls.txt" "$T/visible.txt" > "$EXPORTS"

# Called, defined, but hidden: the library cannot export it.
comm -23 "$T/def.txt" "$T/visible.txt" | comm -12 "$T/calls.txt" - > "$T/hidden.txt"
fail "$T/hidden.txt" "called names a --shared archive defines only with hidden visibility"

# Every komira_* call site is answered: by the library or by a per-library archive.
grep '^komira_' "$T/calls.txt" | comm -23 - "$T/def.txt" | comm -23 - "$T/perlib_def.txt" > "$T/unowned.txt" || true
fail "$T/unowned.txt" "komira_* names Mojo code calls that no --shared and no --per-library archive defines"
comm -12 "$T/def.txt" "$T/perlib_def.txt" > "$T/both.txt"
fail "$T/both.txt" "names defined by a --shared and a --per-library archive"

{
    echo "libkomira_native exports: $(wc -l < "$EXPORTS") names, from $nc callers and $ns shared archives"
    echo "shared archives (exports each defines, of its defined symbols):"
    for d in "$T"/shared/*; do
        n=$(comm -12 "$EXPORTS" "$d/def.txt" | wc -l)
        echo "  $(cat "$d/label"): $n of $(wc -l < "$d/def.txt")"
        [ "$n" -gt 0 ] || echo "$(cat "$d/label")" >> "$T/uncalled.txt"
    done
    echo "per-library archives, kept out:"
    for d in "$T"/perlib/*; do
        [ -f "$d/label" ] || continue
        echo "  $(cat "$d/label"): $(comm -12 "$T/calls.txt" "$d/def.txt" | wc -l) called names, left to the caller's own link"
    done
    echo "callers (exports each calls, of its call-site names):"
    for d in "$T"/callers/*; do
        n=$(comm -12 "$EXPORTS" "$d/calls.txt" | wc -l)
        echo "  $(cat "$d/label"): $n of $(wc -l < "$d/calls.txt")"
        [ "$n" -gt 0 ] || echo "$(cat "$d/label")" >> "$T/nocalls.txt"
    done
} > "$REPORT"
[ -f "$T/uncalled.txt" ] && fail "$T/uncalled.txt" "--shared archives that define none of the exports (nothing calls them)"
[ -f "$T/nocalls.txt" ] && fail "$T/nocalls.txt" "--callers that call none of the exports"
[ "$red" = 0 ] || exit 1

{
    echo "/* libkomira_native.so.1: generated by tools/build/native/native_exports.sh."
    echo "   The external_call names of the callers that the library defines; every other symbol is local. */"
    echo "{"
    echo "  global:"
    sed 's/^/    /; s/$/;/' "$EXPORTS"
    echo "  local:"
    echo "    *;"
    echo "};"
} > "$MAP"
cat "$REPORT"
