#!/bin/sh
# The cases of cov_branch_classify (README.md), run as a build action by the
# `cov_branch_classify_cases` target (kcov/defs.bzl, kcov_tool_cases):
#   sh cov_branch_classify_cases.sh <busybox> <result.json> <cov_branch_classify> <dir>
# <dir> holds fixtures/case.ll, an annotated IR made by hand in the form
# cov_branch_annotate.sh writes it (made-up paths and counts),
# fixtures/case.golden.info, the output it must give byte for byte, and
# fixtures/{a,b,c,gen}.src, the library sources the IR names as a.mojo,
# b.mojo, c.mojo and gen.mojo, staged here under the made-up [src] name the IR gives
# them (kept as .src so no lint of the cell reads them as Mojo). Each case says the defect
# (mutant) it kills. Exits 1 on the first wrong result, naming it; writes the
# validation result and exits 0 when every case holds.
# The flag variables ($MAP, $EXC, ...) are word lists, split on purpose.
# shellcheck disable=SC2086
set -eu

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
BB=$(abs "$1")
RESULT=$(abs "$2")
TOOL=$(abs "$3")
DIR=$(abs "$4")
FX="$DIR/fixtures/case.ll"
GOLDEN="$DIR/fixtures/case.golden.info"

case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.cov_branch_classify_cases" ;;
    /*) T="$BUCK_SCRATCH_PATH/cov_branch_classify_cases" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/cov_branch_classify_cases" ;;
esac
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
export PATH LC_ALL=C
W="$T/work"
SRC=buck-out/v2/art/cell/src/pkg/__pkg__/0123456789abcdef/src/pkg
mkdir -p "$W/$SRC"
for f in a b c gen; do cp "$DIR/fixtures/$f.src" "$W/$SRC/$f.mojo"; done
# The tool reads the sources at the names the IR gives them, relative to its
# working directory, as the action runs it from the root holding [src].
cd "$W"

N=0
red() {
    echo "cov_branch_classify_cases RED: $*" >&2
    if [ -f "$W/err" ]; then
        echo "--- stderr:" >&2
        cat "$W/err" >&2
    fi
    exit 1
}
pass() { N=$((N + 1)); }

MAP="--map $SRC/=src/pkg/"
EXC="--exclude oss/modular/ --exclude buck-out/ --exclude-file tests/test_a.mojo --exclude-file <unknown> --gen gen.mojo"

# run <cmd>...: runs it with stderr in $W/err, status in RC.
run() {
    rm -f "$W/out.info"
    set +e
    "$@" 2>"$W/err"
    RC=$?
    set -e
}

# refused <name> <substring of the message> <ir>: exit 1, the message, no output.
refused() {
    name=$1
    msg=$2
    run "$TOOL" --ir "$3" --out "$W/out.info" $MAP $EXC
    [ "$RC" -eq 1 ] || red "$name: exit $RC, want 1"
    grep -qF -- "$msg" "$W/err" || red "$name: stderr does not say '$msg'"
    [ ! -e "$W/out.info" ] || red "$name: an output was written"
    pass
}

# variant <sed expression>: case.ll edited, in $W/v.ll; the edit must change it.
variant() {
    sed -e "$1" "$FX" >"$W/v.ll"
    ! cmp -s "$W/v.ll" "$FX" || red "variant '$1' does not change case.ll, so its case checks nothing"
}

# 1. The golden output, byte for byte. Kills: an instance not summed (3,5 is
# 2,10 + 1,1 of the other generic instance + 0,1 of a copy inlined into the
# test: 3,12, one record per arm); a never-ran count written as 0 (9,5 never
# ran in either instance: `-`); arms swapped (5,5 is 1,9: true first, as the
# weights are); a compiler-made branch written (no record on lines 4, 17, 18,
# 19: `+`, `String(`, `//`, `%`, `check(`); an inlined branch put on its call
# site (11,19 is 5,1, not 5,1 + the 9,9 of range.mojo inlined there); the
# [src] hash left in the path (SF:src/pkg/...); the right operands of `or`
# (13,14:rhs = 3-1, 2) and `and` (15,14:rhs = 3, 4-3) as selects, of a
# short-circuit `or` and `and` (a br at the token, a phi, a branch on it:
# c.mojo 3,17:rhs = 3-1, 3; 7,14:rhs = 3, 4-3) and of an `or` under `not`
# (11,15:rhs through `xor ..., true`: the branch's arms swapped, 5-3, 2);
# two distinct branches of one function at one location (b.mojo 3,5:br:0/2 =
# 1,4 and 1/2 = 1,3, as Mojo gives an `elif` its `if`'s location) summed
# into one; one decision tested twice (a.mojo 11,19's two branches on one
# value with one weights node, as a `range(` loop has; c.mojo 3,5's select
# and branch on the phi) written twice; a switch's three arms; files and
# records sorted. Not in the output: the test, the standard library, the
# dependency, the generated source, `<unknown>`. c.mojo declares `quick`
# @always_inline("nodebug") and no branch is at a call of it: not refused.
run "$TOOL" --ir "$FX" --out "$W/out.info" $MAP $EXC
[ "$RC" -eq 0 ] || red "golden: exit $RC, want 0"
if ! cmp -s "$W/out.info" "$GOLDEN"; then
    diff -u "$GOLDEN" "$W/out.info" >&2 || true
    red "golden: the output differs from fixtures/case.golden.info"
fi
want="3 measured file(s): 23 source decision(s) (if 13, elif 1, while 2, and 2, or 3, for-range( 2; 5 right operand(s) derived, 2 a second test of one decision), 5 compiler-made (+ 1, call( 2, // 1, % 1) not written; 6 branch(es) outside the measured sources"
grep -qF "$want" "$W/err" || red "golden: stderr does not say '$want'"
pass

# 1b. The mutants of case 1, each named (the golden diff alone would not say
# which): a NONE written as 0, an instance not summed, a compiler-made row
# written, the hash kept, a short-circuit or negated operand not derived,
# one decision tested twice written twice.
grep -qx 'BRDA:9,5:br:0/1,0,-' "$W/out.info" || red "never ran: 9,5 arm 0 is not '-' (NONE written as a count)"
grep -qx 'BRDA:3,5:br:0/1,1,12' "$W/out.info" || red "instances: 3,5 arm 1 is not 10+1+1 (instances or inlined copies not summed)"
[ "$(grep -c '^BRDA:3,5:br:0/1,1,' "$W/out.info")" = 2 ] || red "instances: 3,5 arm 1 is not written once in a.mojo and once in c.mojo"
grep -qx 'BRDA:3,5:br:1/2,1,3' "$W/out.info" || red "one location, two branches: b.mojo's second branch at 3,5 is not its own record"
grep -qx 'BRDA:3,17:rhs:0/1,0,2' "$W/out.info" || red "short-circuit or: c.mojo 3,17's right operand is not 3-1 true"
grep -qx 'BRDA:7,14:rhs:0/1,1,1' "$W/out.info" || red "short-circuit and: c.mojo 7,14's right operand is not 4-3 false"
grep -qx 'BRDA:11,15:rhs:0/1,0,2' "$W/out.info" || red "not (a or b): c.mojo 11,15's right operand is not 5-3 true (the xor's arms not swapped)"
[ "$(grep -c '^BRDA:11,19:' "$W/out.info")" = 2 ] || red "one decision tested twice: 11,19 (two branches on one value and weights) is not one record of two arms"
! grep -q '^BRDA:3,5:select:' "$W/out.info" || red "one decision tested twice: c.mojo 3,5's select on the value its branch tests was written"
! grep -qE '^BRDA:(4|17|18|19),' "$W/out.info" || red "compiler-made: a branch on line 4, 17, 18 or 19 was written"
! grep -q '0123456789abcdef' "$W/out.info" || red "path: the [src] hash is in the output"
pass

# 2. The order of the metadata does not matter: the same IR with its
# metadata lines reversed gives the same bytes. Kills: a node resolved only
# when it was read before its user.
{ grep -v '^![0-9]' "$FX"; grep '^![0-9]' "$FX" | sed -n '1!G;h;$p'; } >"$W/rev.ll"
! cmp -s "$W/rev.ll" "$FX" || red "reversed: the edit changed nothing"
run "$TOOL" --ir "$W/rev.ll" --out "$W/out.info" $MAP $EXC
[ "$RC" -eq 0 ] || red "reversed: exit $RC, want 0"
cmp -s "$W/out.info" "$GOLDEN" || red "reversed metadata: other bytes than the golden"
pass

# 3. Another test's run of the same code (other counts) gives the same
# records but for the counts: the id `<line>,<col>:<kind>:<n>/<N>,<arm>` is what
# covcheck sums by across tests. Kills: an id holding a count, an order or
# an IR line number.
variant 's/^!60 = .*/!60 = !{!"branch_weights", i32 0, i32 4}/; s/^!64 = .*/!64 = !{!"branch_weights", i32 2, i32 3}/'
run "$TOOL" --ir "$W/v.ll" --out "$W/out.info" $MAP $EXC
[ "$RC" -eq 0 ] || red "second test: exit $RC, want 0"
cut -d, -f1-3 "$W/out.info" >"$W/ids2"
cut -d, -f1-3 "$GOLDEN" >"$W/ids1"
cmp -s "$W/ids1" "$W/ids2" || red "second test: the ids differ from the golden's"
grep -qx 'BRDA:3,5:br:0/1,1,6' "$W/out.info" || red "second test: 3,5 arm 1 is not 4+1+1"
grep -qx 'BRDA:13,14:rhs:0/1,0,1' "$W/out.info" || red "second test: 13,14:rhs arm 0 is not 3-2"
pass

# 4. Tokens that are neither a source decision nor a known compiler-made
# branch fail the action, naming file:line:col and the token. Kills: an
# allowlist that accepts an unknown token (a fall-through to "decision" or to
# "compiler-made").
variant 's/^!25 = !DILocation(line: 9, column: 5,/!25 = !DILocation(line: 10, column: 11,/'
refused "+=" "src/pkg/a.mojo:10:11: a br at '+=' is neither a source decision nor a known compiler-made branch: i += 1" "$W/v.ll"
variant 's/^!23 = !DILocation(line: 5, column: 5,/!23 = !DILocation(line: 6, column: 9,/'
refused "a word" "src/pkg/a.mojo:6:9: a br at 'return' is neither" "$W/v.ll"
variant 's/^!26 = !DILocation(line: 11, column: 19,/!26 = !DILocation(line: 20, column: 27,/'
refused "for, not range(" "src/pkg/a.mojo:20:27: a br at 'split(' is neither" "$W/v.ll"
variant 's/^!31 = !DILocation(line: 17, column: 18,/!31 = !DILocation(line: 17, column: 19,/'
refused "one slash" "src/pkg/a.mojo:17:19: a select at '/ 2' is neither" "$W/v.ll"
variant 's/^!20 = !DILocation(line: 3, column: 5,/!20 = !DILocation(line: 3, column: 99,/'
refused "column outside" "src/pkg/a.mojo:3:99: a br at '<column outside the line>'" "$W/v.ll"
variant 's/^!20 = !DILocation(line: 3, column: 5,/!20 = !DILocation(line: 3, column: 6,/'
refused "inside a word" "src/pkg/a.mojo:3:6: a br at 'f' is neither" "$W/v.ll"
# Every unclassified branch is named, not only the first.
variant 's/^!23 = !DILocation(line: 5, column: 5,/!23 = !DILocation(line: 6, column: 9,/; s/^!25 = !DILocation(line: 9, column: 5,/!25 = !DILocation(line: 10, column: 11,/'
refused "two unknown" "src/pkg/a.mojo:6:9: a br at 'return'" "$W/v.ll"
grep -qF "src/pkg/a.mojo:10:11: a br at '+='" "$W/err" || red "two unknown: the second is not named"

# 5. File names: without `--exclude buck-out/` the dependency's source is
# unmapped and refused (so case 1 dropped it by the exclusion, not by
# accident); without the test's --exclude-file, the test is.
run "$TOOL" --ir "$FX" --out "$W/out.info" $MAP --exclude oss/modular/ --exclude-file tests/test_a.mojo --exclude-file "<unknown>" --gen gen.mojo
[ "$RC" -eq 1 ] || red "unmapped dependency: exit $RC, want 1"
grep -qF "unmapped file name 'buck-out/v2/art/cell/src/dep/__dep__/fedcba9876543210/src/dep/d.mojo'" "$W/err" || red "unmapped dependency: not named"
pass
run "$TOOL" --ir "$FX" --out "$W/out.info" $MAP --exclude oss/modular/ --exclude buck-out/ --exclude-file "<unknown>" --gen gen.mojo
[ "$RC" -eq 1 ] || red "unmapped test: exit $RC, want 1"
grep -qF "unmapped file name 'tests/test_a.mojo'" "$W/err" || red "unmapped test: not named"
pass

# 6. Without --gen, the generated source is measured: case 1's drop is the
# --gen's doing (the map is checked before the exclusions, so a [src] under
# buck-out/ is measured).
run "$TOOL" --ir "$FX" --out "$W/out.info" $MAP --exclude oss/modular/ --exclude buck-out/ --exclude-file tests/test_a.mojo --exclude-file "<unknown>"
[ "$RC" -eq 0 ] || red "no --gen: exit $RC, want 0"
grep -qx 'SF:src/pkg/gen.mojo' "$W/out.info" || red "no --gen: the generated source is not in the output"
grep -qx 'BRDA:3,5:br:0/1,0,9' "$W/out.info" || red "no --gen: its branch is not written"
pass

# 7. Zero branches parsed in a measured file whose IR has code on an `if`
# line is refused (the branches were not read); b.mojo, whose only code left
# is on `return 3`, is not. Kills: a parser that silently reads no branch.
grep -vE ' br i1 | = select i1 |^  switch |^  \], |^    i64 [01], label |!dbg !50$' "$FX" >"$W/v.ll"
refused "zero branches" "src/pkg/a.mojo: zero branches parsed, yet the IR has code on its decision line 3" "$W/v.ll"
! grep -qF "src/pkg/b.mojo" "$W/err" || red "zero branches: b.mojo, with code on no decision line, was refused too"

# 8. The library's [src] under another content hash in the IR than --map's
# is refused, naming the file, although `--exclude buck-out/` covers it.
# Kills: a [src] the IR was not compiled from (a hash that does not match)
# falling through to the exclusion unseen, leaving nothing measured. The
# dependency (another library under buck-out/, case 5) is not refused.
mkdir -p buck-out/v2/art/cell/src/pkg/__pkg__/ffffffffffffffff/src/pkg
run "$TOOL" --ir "$FX" --out "$W/out.info" --map buck-out/v2/art/cell/src/pkg/__pkg__/ffffffffffffffff/src/pkg/=src/pkg/ $EXC
[ "$RC" -eq 1 ] || red "other hash: exit $RC, want 1"
grep -qF "'$SRC/a.mojo' is the library's source under another [src] than --map's ('buck-out/v2/art/cell/src/pkg/__pkg__/ffffffffffffffff/src/pkg/')" "$W/err" || red "other hash: a.mojo not named"
! grep -qF "dep/d.mojo" "$W/err" || red "other hash: the dependency was refused too"
[ ! -e "$W/out.info" ] || red "other hash: an output was written"
pass
# 8b. So is the library's [src] under another target or configuration
# directory (`/<hash>/src/pkg/` in another place), which `--exclude
# buck-out/` would drop unseen. Kills: a check of the hash segment alone.
variant 's|^!6 = !DIFile(filename: "buck-out/v2/art/cell/src/dep/__dep__/fedcba9876543210/src/dep/d.mojo"|!6 = !DIFile(filename: "buck-out/v2/art/cfg/other/__pkg2__/fedcba9876543210/src/pkg/d.mojo"|'
refused "other [src]" "'buck-out/v2/art/cfg/other/__pkg2__/fedcba9876543210/src/pkg/d.mojo' is the library's source under another [src]" "$W/v.ll"
# 8c. A --map PREFIX with no `/<16 hex>/` segment is refused: with no hash
# to look for, a library source under another [src] (8, 8b) could not be
# told and `--exclude buck-out/` would drop it unseen. Kills: the check of 8
# skipped silently when the prefix has no hash.
mkdir -p srcroot/pkg
cp "$SRC"/*.mojo srcroot/pkg/
run "$TOOL" --ir "$FX" --out "$W/out.info" --map srcroot/pkg/=src/pkg/ $EXC
[ "$RC" -eq 2 ] || red "no hash: exit $RC, want 2"
grep -qF "the --map PREFIX 'srcroot/pkg/' holds no '/<16 hex>/' segment" "$W/err" || red "no hash: not named"
[ ! -e "$W/out.info" ] || red "no hash: an output was written"
pass

# 9. Malformed or inconsistent IR is refused.
sed 1d "$FX" >"$W/v.ll"
refused "no header" "does not start with '; *** IR Dump After PGOInstrumentationUse on [module] ***'" "$W/v.ll"
variant 's/^!64 = .*/!64 = !{!"branch_weights", i32 1, i32 5}/'
refused "derive totals" "src/pkg/a.mojo:13:14: the left operand ran 6 times and the test of the result 5" "$W/v.ll"
variant 's/^!64 = .*/!64 = !{!"branch_weights", i32 4, i32 1}/'
refused "or below its operand" "src/pkg/a.mojo:13:14: 'or' is true 3 times but its left operand 4" "$W/v.ll"
variant 's/, !dbg !28, !prof !65/, !dbg !28/'
refused "derive one never ran" "src/pkg/a.mojo:13:14: the 'or' ran but the test of its result never did" "$W/v.ll"
variant 's/^!66 = .*/!66 = !{!"branch_weights", i32 2, i32 3}/'
refused "and above its operand" "src/pkg/a.mojo:15:14: 'and' is true 3 times but its left operand 2" "$W/v.ll"
variant 's/^!61 = .*/!61 = !{!"branch_weights", i32 1, i32 9, i32 2}/'
refused "arms" "src/pkg/a.mojo:5:5: 3 branch weights for 2 arms" "$W/v.ll"
variant 's/^!61 = .*/!61 = !{!"branch_weights", !"expected", i32 1, i32 9}/'
refused "expected" "src/pkg/a.mojo:5:5: !prof is not branch weights of counts" "$W/v.ll"
variant 's/, !dbg !23, !prof !61/, !prof !61/'
refused "no dbg" "a br with no !dbg location" "$W/v.ll"
variant 's/^!50 = !DILocation(line: 3, column: 5, scope: !12)/!50 = !DILocation(line: 3, column: 5, scope: !9)/'
refused "scope with no file" "of a switch is not a DILocation whose scope names a DIFile" "$W/v.ll"
# Two instances of one switch with 3 and 2 arms.
awk '/^attributes #0/ { print "define internal i64 @\"pkg::b::f2\"(i64 %0) #0 !dbg !12 {"; print "1:"; print "  switch i64 %0, label %4 ["; print "    i64 0, label %2"; print "  ], !dbg !50"; print "}"; print "" } { print }' "$FX" >"$W/v.ll"
refused "arms of two instances" "src/pkg/b.mojo:3:5: two instances of one switch have 3 and 2 arms" "$W/v.ll"

# 9b. A copy of a function holding another number of branches of a kind at
# a location than another copy is refused: its n-th is not theirs. Kills:
# ordinals summed across copies that do not match (a branch one generic
# instance folded away shifting the others'). The second branch has other
# weights: with the same, it would be one decision tested twice.
awk '{ print } /, !dbg !40, !prof !70$/ { sub(/!prof !70$/, "!prof !72"); print }' "$FX" >"$W/v.ll"
refused "copies differ" "src/pkg/a.mojo:3:5 (br): one copy of its function has 1 branch(es) of this kind here and another 2" "$W/v.ll"
# So is one holding as many whose conditions are computed elsewhere (each
# instance folded away another of its branches there). Kills: copies matched
# by their number alone.
variant 's/^  %3 = icmp slt i64 %0, 0, !dbg !40$/  %3 = icmp slt i64 %0, 0, !dbg !41/'
refused "copies' conditions" "src/pkg/a.mojo:3:5 (br): two copies of its function hold different branches here: the condition of the one numbered 0 is computed at" "$W/v.ll"

# 9c. An and/or whose right operand cannot be counted is refused, naming
# it. Kills: a right operand dropped unseen (a false 100%).
# A select at `or` whose result is not tested (`var r = a or b`).
awk '{ print } /^  %4 = xor i1 %3, true, !dbg !123$/ { print "  %7 = select i1 %0, i1 true, i1 %1, !dbg !127, !prof !134" }' "$FX" >"$W/v.ll"
refused "or not tested" "src/pkg/c.mojo:13:15: the right operand of this 'or' is not counted" "$W/v.ll"
# A select at `or` of another form.
variant 's/^  %3 = select i1 %0, i1 true, i1 %1, !dbg !122/  %3 = select i1 %0, i1 %1, i1 true, !dbg !122/'
refused "or select form" "src/pkg/c.mojo:11:15: IR line" "$W/v.ll"
grep -qF "the select at this 'or' is not that of one" "$W/err" || red "or select form: not named as such"
# A short-circuit `or` whose phi is missing, or is not an `or`'s.
grep -vF '%8 = phi i1 [ %6, %5 ], [ true, %4 ], !dbg !111' "$FX" >"$W/v.ll"
refused "or no phi" "src/pkg/c.mojo:3:17: a short-circuit 'or' (a br) whose result is not a phi at its location" "$W/v.ll"
variant 's/%8 = phi i1 \[ %6, %5 \], \[ true, %4 \]/%8 = phi i1 [ %6, %5 ], [ false, %4 ]/'
refused "or phi form" "src/pkg/c.mojo:3:17: IR line" "$W/v.ll"
grep -qF "the phi at this 'or' is not that of a short-circuit one" "$W/err" || red "or phi form: not named as such"
# A short-circuit whose deciding constant arrives from the branch's other
# target: the phi has the and/or shape, but the constant is the result when
# the left operand is the other value (`not a or b` under an `or` token), so
# the derived right operand would be wrong. Refused, not derived. Kills: a
# phi read by its shape alone, the targets of its branch not compared.
variant 's/br i1 %3, label %4, label %5, !dbg !111/br i1 %3, label %5, label %4, !dbg !111/'
refused "or constant from the false target" "src/pkg/c.mojo:3:17: IR line 122: the 'true' of the phi at this 'or' arrives from %4, the branch's false target, not its true target (%5)" "$W/v.ll"
variant 's/br i1 %3, label %4, label %6, !dbg !117/br i1 %3, label %6, label %4, !dbg !117/'
refused "and constant from the true target" "src/pkg/c.mojo:7:14: IR line 146: the 'false' of the phi at this 'and' arrives from %6, the branch's true target, not its false target (%4)" "$W/v.ll"
# The constant arriving straight from the branch's own block (the phi in the
# deciding target, with no forwarding block between) is a correct shape the
# classifier does not read (no such IR has been seen): refused, not guessed.
awk '/^define .*@"pkg::c::spend"/ { s = 1 } s && /^}$/ { s = 0 } s && /^  br i1 %3, label %4, label %5, !dbg !111/ { print "  br i1 %3, label %7, label %5, !dbg !111, !prof !130"; next } s && /^4:  / { skip = 3 } skip > 0 { skip--; next } s { sub(/\[ true, %4 \]/, "[ true, %2 ]"); sub(/preds = %4, %5$/, "preds = %2, %5") } { print }' "$FX" >"$W/v.ll"
! cmp -s "$W/v.ll" "$FX" || red "or straight edge: the edit changed nothing"
grep -qF '%8 = phi i1 [ %6, %5 ], [ true, %2 ]' "$W/v.ll" || red "or straight edge: the phi was not rewritten"
refused "or straight edge" "src/pkg/c.mojo:3:17: IR line 119: the 'true' of the phi at this 'or' arrives from %2, which is not one of the branch's targets (%7, %5)" "$W/v.ll"

# 9d. A branch at the call of a function a measured source declares
# @always_inline("nodebug") is refused (it may be that function's own
# decision, given the call's location); a nodebug operator, constructor or
# destructor refuses the run. Kills: the call class taken for any callee.
awk '{ print } /^  %4 = xor i1 %3, true, !dbg !123$/ { print "  br i1 %4, label %5, label %6, !dbg !128, !prof !135" }' "$FX" >"$W/v.ll"
refused "nodebug call" "src/pkg/c.mojo:12:21: a br at 'quick(' may be a decision of quick, which src/pkg/c.mojo:16 declares @always_inline(\"nodebug\")" "$W/v.ll"
printf '# made up\nstruct S:\n    @always_inline("nodebug")\n    def __add__(self, o: S) -> S:\n        return o\n' >"$SRC/n.mojo"
refused "nodebug dunder" "src/pkg/n.mojo:4: __add__ is declared @always_inline(\"nodebug\")" "$FX"
rm "$SRC/n.mojo"

# 9e. A compiler-made token with an instruction kind it has not shown is
# refused. Kills: a class accepting any kind (a select at `+`).
variant 's/^!31 = !DILocation(line: 17, column: 18,/!31 = !DILocation(line: 4, column: 42,/'
refused "kind" "src/pkg/a.mojo:4:42: a select at '+': no select has been seen at this token" "$W/v.ll"

# 9f. Branch forms the classifier does not read, in a measured file, are
# refused. Kills: an invoke (or indirectbr, callbr) skipped unseen.
awk '{ print } /^  %3 = icmp slt i64 %0, 0, !dbg !20$/ { print "  invoke void @\"x\"() to label %4 unwind label %7, !dbg !20" }' "$FX" >"$W/v.ll"
refused "invoke" "src/pkg/a.mojo:3:5: an invoke in a measured file" "$W/v.ll"

# 9g. A measured file with zero branches parsed and code on a line whose
# decision is an `and`, `or` or ternary `if` (not its first word) is
# refused. Kills: a zero-branch check that reads only the first word.
printf '# made up\ndef pick(a: Bool, b: Bool) -> Bool:\n    return a and b\n' >"$SRC/e.mojo"
awk '/^attributes #0/ { print "define internal i1 @\"pkg::e::pick\"(i1 %0, i1 %1) #0 !dbg !141 {"; print "2:"; print "  %3 = and i1 %0, %1, !dbg !142"; print "  ret i1 %3, !dbg !142"; print "}"; print "" } { print } END { print "!140 = !DIFile(filename: \"'"$SRC"'/e.mojo\", directory: \"\")"; print "!141 = distinct !DISubprogram(name: \"pick\", scope: !140, file: !140, line: 2, type: !9, unit: !0)"; print "!142 = !DILocation(line: 3, column: 5, scope: !141)" }' "$FX" >"$W/v.ll"
refused "zero branches, and" "src/pkg/e.mojo: zero branches parsed, yet the IR has code on its decision line 3" "$W/v.ll"
rm "$SRC/e.mojo"

# 10. Bad usage exits 2.
for args in "--out $W/out.info $MAP" "--ir $FX $MAP" "--ir $FX --out $W/out.info" \
    "--ir $FX --out $W/out.info --map $SRC=src/pkg/" "--ir $FX --out $W/out.info --map $SRC/=/abs/" \
    "--ir $FX --out $W/out.info $MAP $MAP" "--ir $FX --out $W/out.info $MAP --frobnicate x" \
    "--ir $FX --out $W/out.info $MAP --exclude oss" "--ir $FX --out $W/out.info $MAP --gen /abs"; do
    run "$TOOL" $args
    [ "$RC" -eq 2 ] || red "usage '$args': exit $RC, want 2"
    grep -q '^usage: cov_branch_classify' "$W/err" || red "usage '$args': no usage line"
done
pass

cd /
rm -rf "$T"
printf '{"version": 1, "data": {"status": "success", "message": "cov_branch_classify: %s cases passed"}}\n' "$N" >"$RESULT"
echo "cov_branch_classify_cases GREEN: $N cases"
