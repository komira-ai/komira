#!/bin/sh
# The export check of libkomira_native.so.1 (README.md, "One shared
# library"), run as a build action by a `komira_native` target
# (komira_native.bzl):
#   sh native_check.sh <busybox> <result.json> <elfsyms> <lib.so> <soname> <exports.txt> <version.map> <needed>
# Reads the shared object's dynamic section and dynamic symbol table and
# fails (exit 1, naming each offender) when
#   - an exported symbol (defined, not local) does not start with komira_:
#     a name another library of the process could also define;
#   - the exported symbols are not exactly <exports.txt>, the generated list
#     (a name Mojo code calls that the library does not export, or one it
#     exports that no Mojo code calls), or the version script's global names
#     are not exactly that list;
#   - a (strong) undefined symbol starts with komira_ (its definition was
#     left out); a weak one is a hook nothing need define (aws-lc's
#     komira_awslc_OPENSSL_memory_* allocator hooks);
#   - the SONAME is not <soname>; a NEEDED library is not one of <needed>
#     (an extended regular expression), or libc.so.6 is not NEEDED; the
#     library carries a run path; or it was not linked -Bsymbolic.
# Writes the validation result and exits 0 otherwise.
set -eu
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail
set -o pipefail

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
BB=$(abs "$1")
RESULT=$(abs "$2")
TOOL=$(abs "$3")
SO=$(abs "$4")
SONAME=$5
EXPORTS=$(abs "$6")
MAP=$(abs "$7")
NEEDED=$8

case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.native_check" ;;
    /*) T="$BUCK_SCRATCH_PATH/native_check" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/native_check" ;;
esac
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
export PATH LC_ALL=C

"$TOOL" dynsym "$SO" > "$T/dyn.txt"
awk '$1 == "DEF" && $2 != "LOCAL" { print $5 }' "$T/dyn.txt" | sort -u > "$T/exported.txt"
awk '$1 == "UND" && $2 != "WEAK" { print $5 }' "$T/dyn.txt" | sort -u > "$T/und.txt"
awk '$1 == "UND" && $2 == "WEAK" { print $5 }' "$T/dyn.txt" | sort -u > "$T/weak_und.txt"
sort -u "$EXPORTS" > "$T/listed.txt"
# The version script's global names: the lines between `global:` and `local:`.
awk '/^ *local:/ { g = 0 } g { sub(/^ */, ""); sub(/;$/, ""); if ($0 != "") print } /^ *global:/ { g = 1 }' "$MAP" | sort -u > "$T/script.txt"

red=0
report() { # file, what
    if [ -s "$1" ]; then
        red=1
        echo "native_check RED: $(wc -l < "$1") $2:" >&2
        sed 's/^/  /' "$1" | head -n 50 >&2
    fi
}
grep -v '^komira_' "$T/exported.txt" > "$T/bad_prefix.txt" || true
report "$T/bad_prefix.txt" "exported symbols without the komira_ prefix"
comm -13 "$T/exported.txt" "$T/listed.txt" > "$T/missing.txt"
report "$T/missing.txt" "names Mojo code calls that the library does not export"
comm -23 "$T/exported.txt" "$T/listed.txt" > "$T/extra.txt"
report "$T/extra.txt" "exported symbols no Mojo code calls"
comm -3 "$T/script.txt" "$T/listed.txt" | awk -F '\t' '{ if ($1 == "") print "list only: " $2; else print "script only: " $1 }' > "$T/script_diff.txt"
report "$T/script_diff.txt" "differences between the version script and the generated list"
grep '^komira_' "$T/und.txt" > "$T/bad_und.txt" || true
report "$T/bad_und.txt" "strong undefined komira_ symbols"

grep '^SONAME ' "$T/dyn.txt" | cut -d' ' -f2- > "$T/soname.txt" || true
if [ "$(cat "$T/soname.txt")" != "$SONAME" ]; then
    red=1
    echo "native_check RED: SONAME is '$(cat "$T/soname.txt")', not $SONAME" >&2
fi
grep '^NEEDED ' "$T/dyn.txt" | cut -d' ' -f2- | sort > "$T/needed.txt" || true
grep -v -x -E "$NEEDED" "$T/needed.txt" > "$T/bad_needed.txt" || true
report "$T/bad_needed.txt" "NEEDED libraries outside $NEEDED"
if ! grep -q -x 'libc.so.6' "$T/needed.txt"; then
    red=1
    echo "native_check RED: libc.so.6 is not NEEDED (not a glibc shared object?)" >&2
fi
grep -E '^(RUNPATH|RPATH) ' "$T/dyn.txt" > "$T/runpath.txt" || true
report "$T/runpath.txt" "run paths (the library finds nothing but the system's own)"
# DF_SYMBOLIC is bit 0x2 of DT_FLAGS; lld also writes DT_SYMBOLIC.
# The last hex digit of FLAGS has that bit set when it is one of 2367abef.
sym=$(awk '$1 == "SYMBOLIC" { s = 1 } $1 == "FLAGS" && index("2367abef", tolower(substr($2, length($2), 1))) > 0 { s = 1 } END { print s + 0 }' "$T/dyn.txt")
if [ "$sym" != 1 ]; then
    red=1
    echo "native_check RED: not linked -Bsymbolic (no DT_SYMBOLIC, no DF_SYMBOLIC)" >&2
fi
n=$(wc -l < "$T/exported.txt")
if [ "$n" -lt 1 ]; then
    red=1
    echo "native_check RED: the library exports nothing" >&2
fi
[ "$red" = 0 ] || exit 1

msg="$n exported symbols, all komira_ and exactly the generated list; SONAME $SONAME; NEEDED $(tr '\n' ' ' < "$T/needed.txt"); Bsymbolic; no run path; no strong undefined komira_ symbol ($(wc -l < "$T/weak_und.txt") weak hooks undefined)"
echo "native_check GREEN: $msg"
printf '{"version": 1, "data": {"status": "success", "message": "%s"}}\n' "$msg" > "$RESULT"
