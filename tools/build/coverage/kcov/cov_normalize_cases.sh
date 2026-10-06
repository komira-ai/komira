#!/bin/sh
# The cases of cov_normalize (README.md), run as a build action by the
# `cov_normalize_cases` target (defs.bzl, kcov_tool_cases):
#   sh cov_normalize_cases.sh <busybox> <result.json> <cov_normalize> <dir>
# <dir> holds fixtures/kcov_full_paths.xml, a kcov report with absolute file
# names (made up), and fixtures/kcov_full_paths.golden.xml, the output it must
# give byte for byte. Exits 1 on the first wrong result, naming it; writes the
# validation result and exits 0 when every case holds.
# The flag variables ($M1, $EX, $MUST, ...) are word lists, split on purpose.
# shellcheck disable=SC2086
set -eu

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
BB=$(abs "$1")
RESULT=$(abs "$2")
TOOL=$(abs "$3")
DIR=$(abs "$4")
FX="$DIR/fixtures/kcov_full_paths.xml"
GOLDEN="$DIR/fixtures/kcov_full_paths.golden.xml"

# Private scratch (as in tools/build/mojo/toolchain.bzl): a local action runs
# in the checkout root, so it takes the directory buck2 names for it.
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.kcov_cases" ;;
    /*) T="$BUCK_SCRATCH_PATH/kcov_cases" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/kcov_cases" ;;
esac
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
export PATH LC_ALL=C
W="$T/work"
mkdir -p "$W"

N=0
red() {
    echo "cov_normalize_cases RED: $*" >&2
    if [ -f "$W/err" ]; then
        echo "--- stderr:" >&2
        cat "$W/err" >&2
    fi
    exit 1
}
pass() { N=$((N + 1)); }

# mk <classes>: a small report holding <classes> in $W/bad.xml.
mk() { printf '<?xml version="1.0" ?>\n<coverage>\n<packages><package name=""><classes>\n%s\n</classes></package></packages>\n</coverage>\n' "$1" >"$W/bad.xml"; }

# run <cmd>...: runs it with stderr in $W/err, status in RC.
run() {
    rm -f "$W/out.xml"
    set +e
    "$@" 2>"$W/err"
    RC=$?
    set -e
}

# refused <name> <substring of the message> <cmd>...: exit 1, the message, and no output.
refused() {
    name=$1
    msg=$2
    shift 2
    run "$@"
    [ "$RC" -eq 1 ] || red "$name: exit $RC, want 1"
    grep -qF -- "$msg" "$W/err" || red "$name: stderr does not say '$msg'"
    [ ! -e "$W/out.xml" ] || red "$name: an output was written"
    pass
}

D=/worker/build/0123456789abcdef/root
P=/__________________________________
ART=buck-out/v2/art/komira/src/komira_retry/__komira_retry__/fedcba9876543210/src/komira_retry/
PKG=src/komira_retry/
# The maps of a kcov run: the library's sources under the copied source root
# (longest prefix), the rest of that root (the tests), and the library's
# sources under the placeholder, as an unrelocated report would hold them.
M1="--map $D/srcroot/$ART=$PKG"
M2="--map $D/srcroot/=$PKG"
M3="--map $P/$ART=$PKG"
EX="--exclude $D/srcroot/buck-out/v2/gen/"
MUST="--must-contain ${PKG}tests/test_refusals.mojo --must-contain ${PKG}policy.mojo"

# 1. The golden output, byte for byte. It proves: longest-prefix mapping (the
# library's files take M1, not M2, which is given first); the placeholder
# form mapped (M3); the two policy.mojo classes merged into one (hits summed
# then clamped, the larger k of two branch lines with the same n); a line number given twice in one class
# merged; lines and classes sorted; hits clamped to 0/1; a <method>'s lines not
# read; the excluded generated file dropped although M2 covers it; a
# self-closing <class> kept with no lines; the XML entities of a file name
# decoded and written back escaped; the sandbox path and this action's own
# directory absent (--forbid passes).
run "$TOOL" --in "$FX" --out "$W/out.xml" $M2 $M1 $M3 $EX $MUST --forbid "$D" --forbid "$PWD"
[ "$RC" -eq 0 ] || red "golden: exit $RC, want 0"
if ! cmp -s "$W/out.xml" "$GOLDEN"; then
    diff -u "$GOLDEN" "$W/out.xml" >&2 || true
    red "golden: the output differs from fixtures/kcov_full_paths.golden.xml"
fi
grep -qF "7 class(es) read, 1 excluded, 5 written" "$W/err" || red "golden: the counts on stderr are not '7 class(es) read, 1 excluded, 5 written'"
pass

# 2. The output does not depend on the run: other hit counts above 0, another
# timestamp and other rates and <source> give the same bytes.
cp "$W/out.xml" "$W/first.xml"
sed -e 's/hits="3"/hits="41"/g' -e 's/timestamp="[0-9]*"/timestamp="1790000999"/' \
    -e 's/line-rate="[0-9.]*"/line-rate="0.5"/g' -e "s|<source>.*</source>|<source>$P/</source>|" "$FX" >"$W/rerun.xml"
cmp -s "$W/rerun.xml" "$FX" && red "rerun: the edited report equals the fixture, so this case checks nothing"
run "$TOOL" --in "$W/rerun.xml" --out "$W/out.xml" $M1 $M2 $M3 $EX $MUST
[ "$RC" -eq 0 ] || red "rerun: exit $RC, want 0"
cmp -s "$W/out.xml" "$W/first.xml" || red "rerun: a report differing only in hit counts, timestamp, rates and <source> gave other bytes"
pass

# 3. Without the exclusion, the generated file is mapped by M2 and kept:
# case 1's drop is the exclusion's doing, and an exclusion wins over a map.
run "$TOOL" --in "$FX" --out "$W/out.xml" $M1 $M2 $M3 $MUST
[ "$RC" -eq 0 ] || red "no exclusion: exit $RC, want 0"
grep -qF "filename=\"${PKG}buck-out/v2/gen/komira/0123456789abcdef/gen.mojo\"" "$W/out.xml" || red "no exclusion: the generated file is not in the output"
pass

# 3b. An exclusion wins over a longer map: everything under the source root is
# excluded although a longer map covers the generated file; only the
# placeholder form's file is left.
run "$TOOL" --in "$FX" --out "$W/out.xml" $M3 --map "$D/srcroot/buck-out/v2/gen/=x/" --exclude "$D/srcroot/" --must-contain "${PKG}policy.mojo"
[ "$RC" -eq 0 ] || red "exclusion over a longer map: exit $RC, want 0"
grep -qF "7 class(es) read, 6 excluded, 1 written" "$W/err" || red "exclusion over a longer map: the counts on stderr are not '7 class(es) read, 6 excluded, 1 written'"
! grep -qF "gen.mojo" "$W/out.xml" || red "exclusion over a longer map: the generated file was written"
pass

# 3c. Merging branch lines of two classes that map to one path: true wins over
# false (either order), false over none, and two true with the same n keep the
# larger k.
mk "<class filename=\"$D/srcroot/tests/m.mojo\"><lines><line number=\"5\" hits=\"0\" branch=\"false\"/><line number=\"6\" hits=\"0\"/><line number=\"7\" hits=\"1\" branch=\"true\" condition-coverage=\"100% (2/2)\"/></lines></class>
<class filename=\"$D/srcroot/tests/m.mojo\"><lines><line number=\"5\" hits=\"1\" branch=\"true\" condition-coverage=\"50% (1/2)\"/><line number=\"6\" hits=\"0\" branch=\"false\"/><line number=\"7\" hits=\"0\" branch=\"false\"/></lines></class>"
run "$TOOL" --in "$W/bad.xml" --out "$W/out.xml" $M2 --must-contain "${PKG}tests/m.mojo"
[ "$RC" -eq 0 ] || red "branch merge: exit $RC, want 0"
for want in '<line number="5" hits="1" branch="true" condition-coverage="50% (1/2)"/>' \
    '<line number="6" hits="0" branch="false"/>' \
    '<line number="7" hits="1" branch="true" condition-coverage="100% (2/2)"/>'; do
    grep -qF "$want" "$W/out.xml" || red "branch merge: the output has no '$want'"
done
pass

# 3d. Two true branch lines with different n are refused.
mk "<class filename=\"$D/srcroot/tests/m.mojo\"><lines><line number=\"5\" hits=\"1\" branch=\"true\" condition-coverage=\"50% (1/2)\"/></lines></class>
<class filename=\"$D/srcroot/tests/m.mojo\"><lines><line number=\"5\" hits=\"1\" branch=\"true\" condition-coverage=\"25% (1/4)\"/></lines></class>"
refused "branch count mismatch" "${PKG}tests/m.mojo:5: two reports of the line give 2 and 4 branches" \
    "$TOOL" --in "$W/bad.xml" --out "$W/out.xml" $M2 --must-contain "${PKG}tests/m.mojo"

# 4. A file name no map covers is refused, named, and nothing is written:
# without M2 the three test files are unmapped. Only a mapped file is
# required, so the refusal is the unmapped names' alone. Each of the three is
# named and counted (the check is not left to the clean-path backstop, which
# would refuse an absolute path passed through with another message).
refused "unmapped" "unmapped file name '$D/srcroot/tests/test_refusals.mojo'" \
    "$TOOL" --in "$FX" --out "$W/out.xml" $M1 $M3 $EX --must-contain "${PKG}policy.mojo"
for want in "unmapped file name '$D/srcroot/tests/test_empty.mojo'" "3 unmapped file name(s) in $FX; nothing written"; do
    grep -qF -- "$want" "$W/err" || red "unmapped: stderr does not say '$want'"
done

# 5. A --must-contain path with no class (a test whose own source kcov
# dropped) is refused.
refused "must-contain" "no class for ${PKG}tests/test_missing.mojo" \
    "$TOOL" --in "$FX" --out "$W/out.xml" $M1 $M2 $M3 $EX $MUST --must-contain "${PKG}tests/test_missing.mojo"

# 5b. A --must-contain path whose class has no line is refused: an empty class
# is no evidence that kcov read the source.
refused "must-contain, no line" "the class for ${PKG}tests/test_empty.mojo has no line" \
    "$TOOL" --in "$FX" --out "$W/out.xml" $M1 $M2 $M3 $EX $MUST --must-contain "${PKG}tests/test_empty.mojo"

# 6. An output holding a --forbid string is refused, whether the string is
# given as the path holds it (a&b) or as the output bytes hold it (a&amp;b).
refused "forbid" "would hold 'a&b'" \
    "$TOOL" --in "$FX" --out "$W/out.xml" $M1 $M2 $M3 $EX $MUST --forbid "a&b"
refused "forbid, escaped" "would hold 'a&amp;b'" \
    "$TOOL" --in "$FX" --out "$W/out.xml" $M1 $M2 $M3 $EX $MUST --forbid "a&amp;b"

# 7. A map whose result is not a clean relative path is refused.
refused "dot-dot" "which has an empty, '.' or '..' segment" \
    "$TOOL" --in "$FX" --out "$W/out.xml" --map "$D/srcroot/=../" --map "$P/=x/" --must-contain x

# 7b. A mapped path that is not UTF-8 is refused: covcheck would decode it
# lossily and look for a file of another name.
mk "<class filename=\"$D/srcroot/tests/a$(printf '\377').mojo\"><lines><line number=\"1\" hits=\"1\"/></lines></class>
<class filename=\"$D/srcroot/tests/b.mojo\"><lines><line number=\"1\" hits=\"1\"/></lines></class>"
refused "not UTF-8" "which is not UTF-8" \
    "$TOOL" --in "$W/bad.xml" --out "$W/out.xml" $M2 --must-contain "${PKG}tests/b.mojo"

# 8. Malformed reports are refused, naming the line.
mk "<class filename=\"$D/srcroot/tests/a&nbsp;.mojo\"><lines></lines></class>"
refused "unknown entity" "bad.xml:4: unknown entity '&nbsp;'" \
    "$TOOL" --in "$W/bad.xml" --out "$W/out.xml" $M2 --must-contain x
mk "<class filename=\"$D/srcroot/tests/a.mojo\"><lines><line number=\"0\" hits=\"1\"/></lines></class>"
refused "line 0" "<line> number 0" "$TOOL" --in "$W/bad.xml" --out "$W/out.xml" $M2 --must-contain x
mk "<class filename=\"$D/srcroot/tests/a.mojo\"><lines></class>"
refused "mismatched tag" "</class> closes <lines>" "$TOOL" --in "$W/bad.xml" --out "$W/out.xml" $M2 --must-contain x
mk "<class filename=\"$D/srcroot/tests/a.mojo\"><lines><line number=\"3\" hits=\"1\" branch=\"true\"/></lines></class>"
refused "branch without condition" "a branch line has no condition-coverage" "$TOOL" --in "$W/bad.xml" --out "$W/out.xml" $M2 --must-contain x

# 9. Bad usage exits 2: no --must-contain, a map without '=' or whose ABS does
# not end with '/', an unknown flag.
for args in "$M2" "--map $D/srcroot $MUST" "--map $D/srcroot=$PKG $MUST" "$M2 $MUST --frobnicate x" \
    "$M2 $M2 $MUST" "--in $FX $M2 $MUST" "--out $W/out.xml $M2 $MUST"; do
    run "$TOOL" --in "$FX" --out "$W/out.xml" $args
    [ "$RC" -eq 2 ] || red "usage '$args': exit $RC, want 2"
    grep -q '^usage: cov_normalize' "$W/err" || red "usage '$args': no usage line"
done
pass

# 10. A write of the output that fails part way (EFBIG: a file size limit,
# ulimit -f in blocks of 512 or 1024 bytes, with SIGXFSZ ignored) leaves no
# file, partial or temporary: exit 1, the output's directory empty. The
# output is 1.4 KiB; the probe checks the shell can limit it.
mkdir -p "$W/o"
set +e
(trap '' XFSZ; ulimit -f 1; exec cat "$GOLDEN" "$GOLDEN") >"$W/probe" 2>"$W/err"
RC=$?
set -e
[ "$RC" -ne 0 ] && [ "$RC" -lt 128 ] || red "probe: cat over the size limit exited $RC, want an error status (not a signal)"
[ "$(wc -c <"$W/probe")" -lt "$(($(wc -c <"$GOLDEN") * 2))" ] || red "probe: the size limit did not stop the write"
set +e
(trap '' XFSZ; ulimit -f 1; exec "$TOOL" --in "$FX" --out "$W/o/out.xml" $M1 $M2 $M3 $EX $MUST) 2>"$W/err"
RC=$?
set -e
[ "$RC" -eq 1 ] || red "failed write: exit $RC, want 1"
[ -z "$(ls -A "$W/o")" ] || red "failed write: the output's directory holds '$(ls -A "$W/o" | tr '\n' ' ')'"
pass

rm -rf "$T"
printf '{"version": 1, "data": {"status": "success", "message": "cov_normalize: %s cases passed"}}\n' "$N" >"$RESULT"
echo "cov_normalize_cases GREEN: $N cases"
