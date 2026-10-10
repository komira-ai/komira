#!/bin/sh
# The symbol check of a prefixed C library (README.md), run as a build action
# by a `prefixed_archive_check` target (defs.bzl):
#   sh archive_check.sh <busybox> <result.json> <elfsyms> <lib.a> <prefix> <min> <allow> [<names>...]
# Reads every non-local symbol of every member of <lib.a> and fails (exit 1,
# naming each offender) when
#   - a defined symbol does not start with <prefix> (unless its whole name
#     matches the extended regular expression <allow>; "-" allows none),
#   - a weak undefined symbol does not start with <prefix> (unless allowed):
#     a hook any other object of the process could define, such as aws-lc's
#     OPENSSL_memory_alloc,
#   - an undefined symbol is one of the library's own unprefixed names (each
#     <names> file lists them, one per line): a reference the renaming missed,
#     which would bind to whatever other copy of the library the process has,
#   - fewer than <min> defined symbols start with <prefix>: an archive the
#     renaming never reached, or one the reader could not read.
# Writes the validation result and exits 0 otherwise.
set -eu
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail
set -o pipefail

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
BB=$(abs "$1")
RESULT=$(abs "$2")
TOOL=$(abs "$3")
ARCHIVE=$(abs "$4")
PREFIX=$5
MIN=$6
ALLOW=$7
shift 7

case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.archive_check" ;;
    /*) T="$BUCK_SCRATCH_PATH/archive_check" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/archive_check" ;;
esac
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
export PATH LC_ALL=C

"$TOOL" symtab "$ARCHIVE" > "$T/symtab.txt"
# Field 5 is the name; DEF|UND and the binding are fields 1 and 2.
awk '$1 == "DEF" { print $5 }' "$T/symtab.txt" | sort -u > "$T/def.txt"
awk '$1 == "UND" { print $5 }' "$T/symtab.txt" | sort -u > "$T/und.txt"
awk '$1 == "UND" && $2 == "WEAK" { print $5 }' "$T/symtab.txt" | sort -u > "$T/weak_und.txt"
cat /dev/null "$@" | sort -u > "$T/names.txt"

unprefixed() { # file: the names in it that neither start with PREFIX nor match ALLOW
    awk -v p="$PREFIX" 'index($0, p) != 1' "$1" > "$T/u.txt"
    if [ "$ALLOW" = "-" ]; then
        cat "$T/u.txt"
    else
        grep -v -x -E "$ALLOW" "$T/u.txt" || true
    fi
}

unprefixed "$T/def.txt" > "$T/bad_def.txt"
unprefixed "$T/weak_und.txt" > "$T/bad_weak.txt"
comm -12 "$T/und.txt" "$T/names.txt" > "$T/bad_und.txt"
ndef=$(awk -v p="$PREFIX" 'index($0, p) == 1' "$T/def.txt" | wc -l)

red=0
report() { # file, what
    if [ -s "$1" ]; then
        red=1
        echo "archive_check RED: $(wc -l < "$1") $2 in $ARCHIVE:" >&2
        sed 's/^/  /' "$1" | head -n 50 >&2
    fi
}
report "$T/bad_def.txt" "defined symbols without the prefix $PREFIX"
report "$T/bad_weak.txt" "weak undefined symbols without the prefix $PREFIX"
report "$T/bad_und.txt" "undefined references to the library's own unprefixed names"
if [ "$ndef" -lt "$MIN" ]; then
    red=1
    echo "archive_check RED: only $ndef defined symbols start with $PREFIX in $ARCHIVE (at least $MIN expected)" >&2
fi
[ "$red" = 0 ] || exit 1

# The message goes into JSON: it holds no quote or backslash (ALLOW may).
msg="$ndef defined symbols start with $PREFIX, $(wc -l < "$T/def.txt") defined in all (the rest allowed); $(wc -l < "$T/weak_und.txt") weak undefined, each prefixed or allowed; no undefined reference among $(wc -l < "$T/names.txt") unprefixed names"
echo "archive_check GREEN: $msg (allowed without the prefix: $ALLOW)"
printf '{"version": 1, "data": {"status": "success", "message": "%s"}}\n' "$msg" > "$RESULT"
