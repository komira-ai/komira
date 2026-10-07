#!/bin/sh
# The call-site check of libkomira_native.so.1 (README.md, "One shared
# library"), run as a build action by a `komira_native` target
# (komira_native.bzl):
#   sh native_callsite_check.sh <busybox> <result.json> <elfsyms> <callsites> <lib.so> \
#       [--shared <lib.a>]... [--caller <src dir>]...
# The library's exports must be exactly the external_call names of the
# callers' .mojo files that a --shared archive defines with default
# visibility. Unlike native_check.sh, this reads neither the generated list
# nor the version script: it reads the call sites again with `callsites`, a
# tokenizer that shares nothing with native_exports.sh's scan, so a name the
# generator's scan misses (and so leaves out of both the list and the script)
# is a difference here. Fails (exit 1, naming each) on any difference.
set -eu
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail
set -o pipefail

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
BB=$(abs "$1")
RESULT=$(abs "$2")
TOOL=$(abs "$3")
CALLSITES=$(abs "$4")
SO=$(abs "$5")
shift 5

case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.native_callsite_check" ;;
    /*) T="$BUCK_SCRATCH_PATH/native_callsite_check" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/native_callsite_check" ;;
esac
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
export PATH LC_ALL=C

: > "$T/calls.txt"
: > "$T/visible.txt"
nc=0
while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || { echo "native_callsite_check: '$1' needs a path" >&2; exit 2; }
    case "$1" in
        --shared)
            "$TOOL" symtab "$(abs "$2")" |
                awk '$1 == "DEF" && $2 != "LOCAL" && ($4 == "DEFAULT" || $4 == "PROTECTED") { print $5 }' >> "$T/visible.txt"
            ;;
        --caller)
            d=$(abs "$2")
            [ -d "$d" ] || { echo "native_callsite_check: $d is not a directory" >&2; exit 2; }
            find "$d" -type f -name '*.mojo' | sort > "$T/files.txt"
            [ -s "$T/files.txt" ] || { echo "native_callsite_check: no .mojo file under $d" >&2; exit 2; }
            # One file per run: callsites exits 2 on a file it cannot read.
            while IFS= read -r f; do "$CALLSITES" "$f" >> "$T/calls.txt"; done < "$T/files.txt"
            nc=$((nc + 1))
            ;;
        *)
            echo "native_callsite_check: unknown argument '$1'" >&2
            exit 2
            ;;
    esac
    shift 2
done
[ "$nc" -gt 0 ] || { echo "native_callsite_check: no --caller" >&2; exit 2; }

sort -u "$T/calls.txt" -o "$T/calls.txt"
sort -u "$T/visible.txt" -o "$T/visible.txt"
comm -12 "$T/calls.txt" "$T/visible.txt" > "$T/expected.txt"
"$TOOL" dynsym "$SO" | awk '$1 == "DEF" && $2 != "LOCAL" { print $5 }' | sort -u > "$T/exported.txt"

red=0
comm -23 "$T/expected.txt" "$T/exported.txt" > "$T/missing.txt"
comm -13 "$T/expected.txt" "$T/exported.txt" > "$T/extra.txt"
for x in missing extra; do
    if [ -s "$T/$x.txt" ]; then
        red=1
        case "$x" in
            missing) what="names Mojo code calls that a shared archive defines, not exported" ;;
            extra) what="exports that are no call site a shared archive defines" ;;
        esac
        echo "native_callsite_check RED: $(wc -l < "$T/$x.txt") $what:" >&2
        sed 's/^/  /' "$T/$x.txt" | head -n 50 >&2
    fi
done
n=$(wc -l < "$T/expected.txt")
if [ "$n" -lt 1 ]; then
    red=1
    echo "native_callsite_check RED: no call site names a symbol of the archives" >&2
fi
[ "$red" = 0 ] || exit 1

msg="$n exports, exactly the $(wc -l < "$T/calls.txt") call-site names of $nc callers (read by callsites) that the archives define"
echo "native_callsite_check GREEN: $msg"
printf '{"version": 1, "data": {"status": "success", "message": "%s"}}\n' "$msg" > "$RESULT"
