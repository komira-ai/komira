#!/bin/sh
# The cases of cov_branch_classify (README.md), run as a build action by the
# `cov_branch_classify_cases` target (kcov/defs.bzl, kcov_tool_cases):
#   sh cov_branch_classify_cases.sh <busybox> <result.json> <cov_branch_classify> <dir>
# <dir> holds fixtures/case.ll, fixtures/rules.ll and fixtures/try.ll,
# annotated IR made by hand in the form cov_branch_annotate.sh writes it
# (made-up paths and counts; rules.ll holds the shapes of README.md's String
# lifetime, raising call, loop head and short-circuit rules, each excerpted
# from a library's IR; try.ll those of a `try:` body), their outputs
# fixtures/{case,rules,try}.golden.info, which they must give byte for
# byte, and fixtures/{a,b,c,d,gen,t}.src, the library sources the IR names
# as a.mojo, b.mojo, c.mojo, d.mojo, gen.mojo and t.mojo, staged
# here under the made-up [src] name the IR gives them (kept as .src so no
# lint of the cell reads them as Mojo). Each case says the defect
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
RX="$DIR/fixtures/rules.ll"
RGOLDEN="$DIR/fixtures/rules.golden.info"
TX="$DIR/fixtures/try.ll"
TGOLDEN="$DIR/fixtures/try.golden.info"

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
for f in a b c d gen t; do cp "$DIR/fixtures/$f.src" "$W/$SRC/$f.mojo"; done
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
STD="--stdlib oss/modular/"
EXC="$STD --exclude oss/modular/ --exclude buck-out/ --exclude-file tests/test_a.mojo --exclude-file <unknown> --gen gen.mojo"

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
want="3 measured file(s): 23 source decision(s) (if 13, elif 1, while 2, and 2, or 3, for-in 2, try 0; 5 right operand(s) derived, 0 and/or result(s) no test reads, 2 a second test of one decision), 5 compiler-made (String lifetime 0, + 1, call( 2, [ 0, // 1, % 1) not written; 6 branch(es) outside the measured sources"
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
variant 's/^!26 = !DILocation(line: 11, column: 19,/!26 = !DILocation(line: 20, column: 31,/'
refused "for, off the head" "src/pkg/a.mojo:20:31: a br at 'sep(' is neither" "$W/v.ll"
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
run "$TOOL" --ir "$FX" --out "$W/out.info" $MAP $STD --exclude oss/modular/ --exclude-file tests/test_a.mojo --exclude-file "<unknown>" --gen gen.mojo
[ "$RC" -eq 1 ] || red "unmapped dependency: exit $RC, want 1"
grep -qF "unmapped file name 'buck-out/v2/art/cell/src/dep/__dep__/fedcba9876543210/src/dep/d.mojo'" "$W/err" || red "unmapped dependency: not named"
pass
run "$TOOL" --ir "$FX" --out "$W/out.info" $MAP $STD --exclude oss/modular/ --exclude buck-out/ --exclude-file "<unknown>" --gen gen.mojo
[ "$RC" -eq 1 ] || red "unmapped test: exit $RC, want 1"
grep -qF "unmapped file name 'tests/test_a.mojo'" "$W/err" || red "unmapped test: not named"
pass

# 6. Without --gen, the generated source is measured: case 1's drop is the
# --gen's doing (the map is checked before the exclusions, so a [src] under
# buck-out/ is measured).
run "$TOOL" --ir "$FX" --out "$W/out.info" $MAP $STD --exclude oss/modular/ --exclude buck-out/ --exclude-file tests/test_a.mojo --exclude-file "<unknown>"
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

# 9c. An and/or whose result cannot be read is refused, naming it. Kills:
# an and/or taken on its token alone (a branch no and/or shape shows).
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
# classifier does not read (no such IR has been seen): the phi does not join
# one value under each target (the branch's own block is under neither), so
# it is not taken as the or's, and the or is refused, not guessed.
awk '/^define .*@"pkg::c::spend"/ { s = 1 } s && /^}$/ { s = 0 } s && /^  br i1 %3, label %4, label %5, !dbg !111/ { print "  br i1 %3, label %7, label %5, !dbg !111, !prof !130"; next } s && /^4:  / { skip = 3 } skip > 0 { skip--; next } s { sub(/\[ true, %4 \]/, "[ true, %2 ]"); sub(/preds = %4, %5$/, "preds = %2, %5") } { print }' "$FX" >"$W/v.ll"
! cmp -s "$W/v.ll" "$FX" || red "or straight edge: the edit changed nothing"
grep -qF '%8 = phi i1 [ %6, %5 ], [ true, %2 ]' "$W/v.ll" || red "or straight edge: the phi was not rewritten"
refused "or straight edge" "src/pkg/c.mojo:3:17: a short-circuit 'or' (a br) whose result is not a phi at its location: its right operand cannot be counted (IR line 119: the phi at this 'or' does not join one value arriving under the branch's true target %7 and one under its false target %5" "$W/v.ll"

# 9j. An and/or whose result no source decision tests (README.md, "and,
# or": returned, stored or passed on) is a decision of its own two arms,
# its left operand's (the right operand evaluated or skipped), with no
# `rhs`; so is one whose test ran another number of times than its left
# operand (that test is not this result's: it reads the value elsewhere,
# or on some paths only). Each case says the mutant it kills.
# accepted <name> <ir> <stderr substring>: exit 0, the substring said.
accepted() {
    run "$TOOL" --ir "$2" --out "$W/out.info" $MAP $EXC
    [ "$RC" -eq 0 ] || red "$1: exit $RC, want 0"
    grep -qF -- "$3" "$W/err" || red "$1: stderr does not say '$3'"
}
# both(): c.mojo 7,14's `and` with the `if` (7,5) testing another value,
# a forward of the result (one incoming value) at the `and` between.
# `$1` names what the `if` tests: %80 (another value) or %87 (the forward).
both_untested() {
    awk -v c="$1" '
        /^define .*@"pkg::c::both"/ { s = 1 }
        s && /^}$/ { s = 0 }
        s && /^  br i1 %8, label %9, label %10, !dbg !119, !prof !133$/ {
            print "  br label %86, !dbg !119"
            print ""
            print "86:                                               ; preds = %7"
            print "  %87 = phi i1 [ %8, %7 ], !dbg !117"
            if (c == "%80") print "  %80 = icmp eq i64 %0, 7, !dbg !119"
            print "  br i1 " c ", label %9, label %10, !dbg !119, !prof !133"
            next
        }
        s { sub(/preds = %7$/, "preds = %86") }
        { print }' "$FX" >"$W/b.ll"
    ! cmp -s "$W/b.ll" "$FX" || red "both_untested $1: the edit changed nothing"
}
# A select at `or` whose result is stored (`var r = a or b`, c.mojo 13).
# Kills: the old refusal ("the right operand ... is not counted"); the
# untested and/or's own record dropped.
awk '{ print } /^  %4 = xor i1 %3, true, !dbg !123$/ { print "  %7 = select i1 %0, i1 true, i1 %1, !dbg !127, !prof !134" }' "$FX" >"$W/v.ll"
accepted "or not tested" "$W/v.ll" "5 right operand(s) derived, 1 and/or result(s) no test reads"
grep -qx 'BRDA:13,15:select:0/1,0,3' "$W/out.info" || red "or not tested: 13,15's select is not a decision of 3 (left true, the right operand skipped)"
grep -qx 'BRDA:13,15:select:0/1,1,4' "$W/out.info" || red "or not tested: 13,15's select is not a decision of 4 (the right operand evaluated)"
! grep -q '^BRDA:13,15:rhs' "$W/out.info" || red "or not tested: a right operand was written with no test of the result"
pass
# A short-circuit `and` whose result is passed on (both() with the `if`
# testing another value), a forward of it at its token. Kills: the
# untested br refused; a forward phi (one incoming value) at the token
# taken for an odd one.
both_untested %80
accepted "and not tested" "$W/b.ll" "4 right operand(s) derived, 1 and/or result(s) no test reads"
grep -qx 'BRDA:7,14:br:0/1,0,4' "$W/out.info" || red "and not tested: 7,14 is not a decision of 4 (the right operand evaluated)"
grep -qx 'BRDA:7,14:br:0/1,1,2' "$W/out.info" || red "and not tested: 7,14 is not a decision of 2 (the right operand skipped)"
! grep -q '^BRDA:7,14:rhs' "$W/out.info" || red "and not tested: a right operand was written with no test of the result"
pass
# The `if` testing the forward: the result's test, read through it. Kills:
# a phi forwarding an awaited value not awaited (no rhs: the and/or alone).
both_untested %87
accepted "forward tested" "$W/b.ll" "5 right operand(s) derived, 0 and/or result(s) no test reads"
grep -qx 'BRDA:7,14:rhs:0/1,0,3' "$W/out.info" || red "forward tested: 7,14's right operand is not 3 true (the test through the forward not read)"
grep -qx 'BRDA:7,14:rhs:0/1,1,1' "$W/out.info" || red "forward tested: 7,14's right operand is not 4-3 false"
pass
# An `i1` phi at the token that is neither a result nor an error flag (the
# `true` arrives under the and's false target): with no test of the result,
# which phi the result is cannot be told. Refused; so is one that does not
# join the branch's targets (arriving from the branch's own block). Kills:
# an untested and/or accepted whatever phis its token holds; one not
# joining the targets left unchecked.
both_untested %80
awk '{ print } /^  %8 = phi i1 \[ %5, %4 \], \[ false, %6 \], !dbg !117$/ { print "  %81 = phi i1 [ %5, %4 ], [ true, %6 ], !dbg !117" }' "$W/b.ll" >"$W/v.ll"
! cmp -s "$W/v.ll" "$W/b.ll" || red "odd phi: the edit changed nothing"
refused "odd phi" "src/pkg/c.mojo:7:14: the right operand of this 'and' is not counted (no test in this function reads its result), and a phi at its location is neither its result nor an error flag" "$W/v.ll"
grep -qF "the value arriving under the branch's false target %6 is 'true'" "$W/err" || red "odd phi: the phi is not named"
awk '{ print } /^  %8 = phi i1 \[ %5, %4 \], \[ false, %6 \], !dbg !117$/ { print "  %81 = phi i1 [ %5, %4 ], [ %3, %2 ], !dbg !117" }' "$W/b.ll" >"$W/v.ll"
! cmp -s "$W/v.ll" "$W/b.ll" || red "odd phi, not joining: the edit changed nothing"
refused "odd phi, not joining" "src/pkg/c.mojo:7:14: the right operand of this 'and' is not counted (no test in this function reads its result), and a phi at its location is neither its result nor an error flag" "$W/v.ll"
grep -qF "does not join one value arriving under the branch's false target %6 and one under its true target %4" "$W/err" || red "odd phi, not joining: the phi is not named"
# A test of the result that ran another number of times than the left
# operand (6), or not at all, is not this result's: the and/or alone, no
# rhs. Kills: the old refusals; a right operand derived from such a test.
variant 's/^!133 = .*/!133 = !{!"branch_weights", i32 3, i32 2}/'
accepted "test ran 5 of 6" "$W/v.ll" "4 right operand(s) derived, 1 and/or result(s) no test reads"
grep -qx 'BRDA:7,14:br:0/1,0,4' "$W/out.info" || red "test ran 5 of 6: 7,14's own record is not written"
! grep -q '^BRDA:7,14:rhs' "$W/out.info" || red "test ran 5 of 6: a right operand was derived from a test of other counts"
pass
variant 's/^!64 = .*/!64 = !{!"branch_weights", i32 1, i32 5}/'
accepted "derive totals" "$W/v.ll" "4 right operand(s) derived, 1 and/or result(s) no test reads"
! grep -q '^BRDA:13,14:rhs' "$W/out.info" || red "derive totals: 13,14's right operand derived from a test of 5 (its left operand ran 6)"
pass
variant 's/^!64 = .*/!64 = !{!"branch_weights", i32 4, i32 1}/'
accepted "or below its operand" "$W/v.ll" "4 right operand(s) derived, 1 and/or result(s) no test reads"
! grep -q '^BRDA:13,14:rhs' "$W/out.info" || red "or below its operand: 13,14's right operand derived from a test true 3 times (its left operand 4)"
pass
variant 's/, !dbg !28, !prof !65/, !dbg !28/'
accepted "derive one never ran" "$W/v.ll" "4 right operand(s) derived, 1 and/or result(s) no test reads"
! grep -q '^BRDA:13,14:rhs' "$W/out.info" || red "derive one never ran: 13,14's right operand derived from a test that never ran"
grep -qx 'BRDA:13,14:select:0/1,1,4' "$W/out.info" || red "derive one never ran: 13,14's own record is not written"
pass
variant 's/^!66 = .*/!66 = !{!"branch_weights", i32 2, i32 3}/'
accepted "and above its operand" "$W/v.ll" "4 right operand(s) derived, 1 and/or result(s) no test reads"
! grep -q '^BRDA:15,14:rhs' "$W/out.info" || red "and above its operand: 15,14's right operand derived from a test true 3 times (its left operand 2)"
pass
# The same with an odd phi at the token: refused, saying why the test was
# not taken. Kills: the odd check skipped for an and/or a test was refused for.
awk '/^!133 = / { print "!133 = !{!\"branch_weights\", i32 3, i32 2}"; next } { print } /^  %8 = phi i1 \[ %5, %4 \], \[ false, %6 \], !dbg !117$/ { print "  %81 = phi i1 [ %5, %4 ], [ true, %6 ], !dbg !117" }' "$FX" >"$W/v.ll"
grep -qF '%81 = phi i1 [ %5, %4 ], [ true, %6 ]' "$W/v.ll" || red "odd phi, test of other counts: the phi was not added"
refused "odd phi, test of other counts" "src/pkg/c.mojo:7:14: the right operand of this 'and' is not counted (src/pkg/c.mojo:7:14: the left operand ran 6 times and the test of the result 5: the right operand cannot be derived), and a phi at its location" "$W/v.ll"
# A raising right operand's error flag beside the result of an `or` whose
# result is passed on (spend(), c.mojo 3,17: `false` under the or's true
# target, field 0 of the `{ i1, ... }` the right operand's call returns
# under the other): no result, not odd. Kills: an error flag taken for an
# odd phi (refused); any value under the other target taken for a flag.
spend_flag() {
    awk -v flag="$1" '
        /^define .*@"pkg::c::spend"/ { s = 1 }
        s && /^}$/ { s = 0 }
        s && /^  %6 = icmp sgt i64 %0, %1, !dbg !112$/ {
            print
            print "  %84 = call { i1, i1 } @\"pkg::c::check\"(i64 %0), !dbg !112"
            print "  %83 = " flag ", !dbg !112"
            next
        }
        s && /^  %8 = phi i1 \[ %6, %5 \], \[ true, %4 \], !dbg !111$/ {
            print
            print "  %82 = phi i1 [ %83, %5 ], [ false, %4 ], !dbg !111"
            print "  %80 = icmp eq i64 %1, 7, !dbg !113"
            next
        }
        s { sub(/select i1 %8, /, "select i1 %80, "); sub(/br i1 %8, /, "br i1 %80, ") }
        { print }' "$FX" >"$W/v.ll"
    grep -qF '%82 = phi i1 [ %83, %5 ], [ false, %4 ]' "$W/v.ll" || red "spend_flag: the flag phi was not added"
}
spend_flag 'extractvalue { i1, i1 } %84, 0'
accepted "or, raising right operand" "$W/v.ll" "4 right operand(s) derived, 1 and/or result(s) no test reads"
grep -qx 'BRDA:3,17:br:0/1,0,1' "$W/out.info" || red "or, raising right operand: 3,17's own record is not written"
! grep -q '^BRDA:3,17:rhs' "$W/out.info" || red "or, raising right operand: a right operand was written with no test of the result"
pass
spend_flag 'icmp eq i64 %0, 3'
refused "or, not a flag" "src/pkg/c.mojo:3:17: the right operand of this 'or' is not counted (no test in this function reads its result), and a phi at its location is neither its result nor an error flag" "$W/v.ll"
# The flag's orientation: the call's flag under the or's true target (the
# right operand skipped) and `false` under the other is no error flag (a
# skipped call has no flag), and is odd. Kills: the flag exemption taken
# in either orientation.
spend_flag 'extractvalue { i1, i1 } %84, 0'
sed 's/%82 = phi i1 \[ %83, %5 \], \[ false, %4 \]/%82 = phi i1 [ false, %5 ], [ %83, %4 ]/' "$W/v.ll" >"$W/v2.ll"
! cmp -s "$W/v2.ll" "$W/v.ll" || red "or, flag under the skip target: the edit changed nothing"
refused "or, flag under the skip target" "src/pkg/c.mojo:3:17: the right operand of this 'or' is not counted (no test in this function reads its result), and a phi at its location is neither its result nor an error flag" "$W/v2.ll"
# An odd phi with three incoming values (not a forward) at an untested
# and's token is refused like one with two. Kills: only two-incoming phis
# marked odd.
both_untested %80
awk '{ print } /^  %8 = phi i1 \[ %5, %4 \], \[ false, %6 \], !dbg !117$/ { print "  %81 = phi i1 [ %5, %4 ], [ false, %6 ], [ true, %2 ], !dbg !117" }' "$W/b.ll" >"$W/v.ll"
! cmp -s "$W/v.ll" "$W/b.ll" || red "odd phi, three incoming: the edit changed nothing"
refused "odd phi, three incoming" "src/pkg/c.mojo:7:14: the right operand of this 'and' is not counted (no test in this function reads its result), and a phi at its location is neither its result nor an error flag" "$W/v.ll"
# A phi of two constants at a tested `or`, the deciding `true` under its
# true target and `false` under the other, is no result (the right
# operand's value would be a constant): refused, as no candidate is.
# Kills: a constant under the other target accepted (a right operand
# derived from a phi that does not carry it).
variant 's/%8 = phi i1 \[ %6, %5 \], \[ true, %4 \]/%8 = phi i1 [ false, %5 ], [ true, %4 ]/'
refused "or, two constants" "src/pkg/c.mojo:3:17: IR line" "$W/v.ll"
grep -qF "the phi at this 'or' is not that of a short-circuit one" "$W/err" || red "or, two constants: not named as such"

# 9k. Three short-circuit and/or on one line (`if (a or b) and (c or e):`,
# c.mojo 19, a function added to case.ll): each phi is its own and/or's,
# told by its column, and each right operand is derived (the inner `or`'s
# through the `and`'s). Kills: a phi matched to an and/or by its line alone
# (the `and`'s phi taken for the second `or`'s: the `and` refused).
printf '%s\n' 'def two(a: Bool, b: Bool, c: Bool, e: Bool) -> Int:' '    if (a or b) and (c or e):' '        return 1' '    return 0' >>"$W/$SRC/c.mojo"
cat >"$W/two.ll" <<'TWO'
define internal i64 @"pkg::c::two"(i1 %0, i1 %1, i1 %2, i1 %3) #0 !dbg !170 !prof !73 {
4:
  br i1 %0, label %5, label %6, !dbg !171, !prof !180

5:                                                ; preds = %4
  br label %7, !dbg !171

6:                                                ; preds = %4
  br label %7, !dbg !171

7:                                                ; preds = %5, %6
  %8 = phi i1 [ true, %5 ], [ %1, %6 ], !dbg !171
  br i1 %8, label %9, label %15, !dbg !172, !prof !181

9:                                                ; preds = %7
  br i1 %2, label %10, label %11, !dbg !173, !prof !182

10:                                               ; preds = %9
  br label %12, !dbg !173

11:                                               ; preds = %9
  br label %12, !dbg !173

12:                                               ; preds = %10, %11
  %13 = phi i1 [ true, %10 ], [ %3, %11 ], !dbg !173
  br label %14, !dbg !172

14:                                               ; preds = %12
  br label %16, !dbg !172

15:                                               ; preds = %7
  br label %16, !dbg !172

16:                                               ; preds = %14, %15
  %17 = phi i1 [ %13, %14 ], [ false, %15 ], !dbg !172
  br i1 %17, label %18, label %19, !dbg !174, !prof !183

18:                                               ; preds = %16
  ret i64 1, !dbg !175

19:                                               ; preds = %16
  ret i64 0, !dbg !176
}

TWO
cat >"$W/two.meta" <<'TWO'
!170 = distinct !DISubprogram(name: "two", linkageName: "pkg::c::two", scope: !8, file: !8, line: 18, type: !9, scopeLine: 18, spFlags: DISPFlagDefinition, unit: !0)
!171 = !DILocation(line: 19, column: 11, scope: !170)
!172 = !DILocation(line: 19, column: 17, scope: !170)
!173 = !DILocation(line: 19, column: 24, scope: !170)
!174 = !DILocation(line: 19, column: 5, scope: !170)
!175 = !DILocation(line: 20, column: 9, scope: !170)
!176 = !DILocation(line: 21, column: 5, scope: !170)
!180 = !{!"branch_weights", i32 2, i32 4}
!181 = !{!"branch_weights", i32 3, i32 3}
!182 = !{!"branch_weights", i32 1, i32 2}
!183 = !{!"branch_weights", i32 2, i32 4}
TWO
awk -v f="$W/two.ll" '/^attributes #0/ { while ((getline l < f) > 0) print l } { print }' "$FX" >"$W/v.ll"
cat "$W/two.meta" >>"$W/v.ll"
grep -qF '@"pkg::c::two"' "$W/v.ll" || red "one line: the function was not added"
run "$TOOL" --ir "$W/v.ll" --out "$W/out.info" $MAP $EXC
[ "$RC" -eq 0 ] || red "one line: exit $RC, want 0"
for r in 19,5:br:0/1,0,2 19,5:br:0/1,1,4 19,11:br:0/1,0,2 19,11:rhs:0/1,0,1 19,11:rhs:0/1,1,3 19,17:br:0/1,0,3 19,17:rhs:0/1,0,2 19,17:rhs:0/1,1,1 19,24:br:0/1,0,1 19,24:rhs:0/1,0,1 19,24:rhs:0/1,1,1; do
    grep -qx "BRDA:$r" "$W/out.info" || red "one line: BRDA:$r is not in the output"
done
cp "$DIR/fixtures/c.src" "$W/$SRC/c.mojo"
pass


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

# 9h. A measured file whose code the IR holds, with no decision in it, is
# named with no record (`SF:` then `end_of_record`) in its sorted place:
# bb.mojo between b.mojo's and c.mojo's records, e.mojo after the last. So
# covcheck counts its package's branches as measured, with none to take.
# Kills: a decision-free file left out (its package BranchNotMeasured in
# covcheck whatever its tests run), or written out of order.
printf '# made up\ndef one() -> Int:\n    return 1\n' >"$SRC/bb.mojo"
printf '# made up\ndef two() -> Int:\n    return 2\n' >"$SRC/e.mojo"
awk '/^attributes #0/ { print "define internal i64 @\"pkg::bb::one\"() #0 !dbg !141 {"; print "1:"; print "  ret i64 1, !dbg !142"; print "}"; print ""; print "define internal i64 @\"pkg::e::two\"() #0 !dbg !144 {"; print "1:"; print "  ret i64 2, !dbg !145"; print "}"; print "" } { print } END { print "!140 = !DIFile(filename: \"'"$SRC"'/bb.mojo\", directory: \"\")"; print "!141 = distinct !DISubprogram(name: \"one\", scope: !140, file: !140, line: 2, type: !9, unit: !0)"; print "!142 = !DILocation(line: 3, column: 5, scope: !141)"; print "!143 = !DIFile(filename: \"'"$SRC"'/e.mojo\", directory: \"\")"; print "!144 = distinct !DISubprogram(name: \"two\", scope: !143, file: !143, line: 2, type: !9, unit: !0)"; print "!145 = !DILocation(line: 3, column: 5, scope: !144)" }' "$FX" >"$W/v.ll"
run "$TOOL" --ir "$W/v.ll" --out "$W/out.info" $MAP $EXC
[ "$RC" -eq 0 ] || red "no decision: exit $RC, want 0"
awk '{ print } $0 == "end_of_record" && f == "SF:src/pkg/b.mojo" { print "SF:src/pkg/bb.mojo"; print "end_of_record" } /^SF:/ { f = $0 } END { print "SF:src/pkg/e.mojo"; print "end_of_record" }' "$GOLDEN" >"$W/want.info"
if ! cmp -s "$W/out.info" "$W/want.info"; then
    diff -u "$W/want.info" "$W/out.info" >&2 || true
    red "no decision: bb.mojo and e.mojo are not each named with no record in their sorted place"
fi
grep -qF "5 measured file(s)" "$W/err" || red "no decision: stderr does not count 5 measured files"
rm "$SRC/bb.mojo" "$SRC/e.mojo"
pass

# 9i. Two debug-info spellings of one file (b.mojo as `filename` alone and as
# `directory` + `filename`, two DIFile nodes) are one measured file: one
# `SF:` in its sorted place, the golden output byte for byte, 3 measured
# files. A file is keyed by its joined name and --map's PREFIX is one string,
# so one repository path has one name. Kills: files keyed by the DIFile node
# (or any raw spelling), which names b.mojo twice and covcheck refuses the
# duplicate `SF:`.
awk '/^attributes #0/ { print "define internal i64 @\"pkg::b::tail\"() #0 !dbg !151 {"; print "1:"; print "  ret i64 3, !dbg !152"; print "}"; print "" } { print } END { print "!150 = !DIFile(filename: \"b.mojo\", directory: \"'"$SRC"'\")"; print "!151 = distinct !DISubprogram(name: \"tail\", scope: !150, file: !150, line: 2, type: !9, unit: !0)"; print "!152 = !DILocation(line: 7, column: 5, scope: !151)" }' "$FX" >"$W/v.ll"
run "$TOOL" --ir "$W/v.ll" --out "$W/out.info" $MAP $EXC
[ "$RC" -eq 0 ] || red "two spellings: exit $RC, want 0"
if ! cmp -s "$W/out.info" "$GOLDEN"; then
    diff -u "$GOLDEN" "$W/out.info" >&2 || true
    red "two spellings: b.mojo under two DIFile spellings is not one SF (the output differs from the golden)"
fi
[ "$(grep -cx 'SF:src/pkg/b.mojo' "$W/out.info")" = 1 ] || red "two spellings: SF:src/pkg/b.mojo is not written once"
grep -qF "3 measured file(s)" "$W/err" || red "two spellings: stderr does not count 3 measured files"
pass

# 11. The shape rules (README.md: String lifetime, a raising call, the loop
# head, short-circuit forms, copies that folded part of a header), on
# rules.ll and d.mojo: the golden output, byte for byte. Each shape is an
# excerpt of a library's IR (README.md names where). Kills, each named
# below: a String destructor or copy at a decision's token recorded as the
# decision (d.mojo 3,5: the `if flag` with four more branches, bits 62 and
# 63, the last-reference test, the negated bit-62 test, all at 3:5, which
# the classifier before this rule wrote as 3,5:br:0/5 to 4/5); a test at a
# decision's token computed elsewhere taken as a String's (16,5 stays a
# decision); a user mask taken as a String's (14,5); a loop head taken at
# another column (23,18 the attribute's `.`, 27,28 a call's `(`); a raising
# call at a loop head dropped (27,28 holds two decisions); a short-circuit
# `and` whose left operand is reloaded (36,17), whose constant arrives
# through a String destructor's diamond (38,16), or whose right operand is
# a nested `and` (40,39 derived from 40,21's right operand through the
# `not`); two copies of `at` (44,5), one of which folded `index < 0` away,
# not summed; in `more`, loop heads on a list literal running over lines
# (54,14), a string literal's method (59,27) and an attribute after a call
# (61,22); a call `p.run[...](` over three lines (65:6, compiler-made); a
# select at an inlined raising call on the flag its error check tests
# (69:17), and one on a call's `i1` its error check tests (71:18); a String carried in phis of an
# inlined callee (71:28); an `or` and an `and` whose raising right operand's
# error flag is a phi beside the result (72,12 and 74,12: the and's error
# flag has the result's shape and is tested by the call's error check, not
# by the `if`); a reload with a destructor call after it (76,26).
run "$TOOL" --ir "$RX" --out "$W/out.info" $MAP $EXC
[ "$RC" -eq 0 ] || red "rules golden: exit $RC, want 0"
if ! cmp -s "$W/out.info" "$RGOLDEN"; then
    diff -u "$RGOLDEN" "$W/out.info" >&2 || true
    red "rules golden: the output differs from fixtures/rules.golden.info"
fi
want="1 measured file(s): 33 source decision(s) (if 15, elif 0, while 0, and 6, or 2, for-in 10, try 0; 8 right operand(s) derived, 0 and/or result(s) no test reads, 1 a second test of one decision), 26 compiler-made (String lifetime 15, + 0, call( 9, [ 1, // 1, % 0) not written; 0 branch(es) outside the measured sources"
grep -qF "$want" "$W/err" || red "rules golden: stderr does not say '$want'"
[ "$(grep -c '^BRDA:3,5:' "$W/out.info")" = 2 ] || red "String at a decision: 3,5 is not one decision of two arms (a destructor's branch recorded as the if's)"
grep -qx 'BRDA:16,5:br:0/1,0,2' "$W/out.info" || red "String strictness: 16,5 (a flags test computed at 5:10, tested at the if) is not a decision"
grep -qx 'BRDA:14,5:br:0/1,0,1' "$W/out.info" || red "user mask: 14,5 is not a decision"
grep -qx 'BRDA:27,28:br:1/2,1,6' "$W/out.info" || red "loop head: 27,28 does not hold the raising call and the iteration"
grep -qx 'BRDA:36,17:rhs:0/1,0,2' "$W/out.info" || red "reload: 36,17's right operand is not 2 true"
grep -qx 'BRDA:38,16:rhs:0/1,1,3' "$W/out.info" || red "dominated constant: 38,16's right operand is not 3 false"
grep -qx 'BRDA:40,39:rhs:0/1,0,1' "$W/out.info" || red "nested and: 40,39's right operand is not 1 true (derived through the not)"
grep -qx 'BRDA:44,5:br:0/2,0,3' "$W/out.info" || red "folded copies: 44,5:br:0/2 is not 2+1 true"
grep -qx 'BRDA:72,12:rhs:0/1,0,1' "$W/out.info" || red "error flag beside the result: 72,12's right operand is not 4-3 true"
grep -qx 'BRDA:74,12:rhs:0/1,1,3' "$W/out.info" || red "and-shaped error flag: 74,12's right operand is not 4-1 false (derived from the call's error check)"
grep -qx 'BRDA:76,26:rhs:0/1,0,2' "$W/out.info" || red "reload before a destructor: 76,26's right operand is not 2 true"
pass

# rvariant <sed expression>: rules.ll edited, in $W/v.ll; the edit must change it.
rvariant() {
    sed -e "$1" "$RX" >"$W/v.ll"
    ! cmp -s "$W/v.ll" "$RX" || red "variant '$1' does not change rules.ll, so its case checks nothing"
}
# rinsert <line of rules.ll> <line>...: rules.ll with the lines after that one.
rinsert() {
    at=$1
    shift
    awk -v at="$at" -v add="$(printf '%s\n' "$@")" '{ print } $0 == at { print add }' "$RX" >"$W/v.ll"
    ! cmp -s "$W/v.ll" "$RX" || red "insert after '$at' changes nothing, so its case checks nothing"
}

# 11a. A String's shapes, read strictly. Kills: the `and` and `icmp` of the
# flags test allowed at two locations (a made-up `icmp ne` at the `!=` of
# `(w.c & M) != 0`, refused there; Mojo's own `!= 0` is an `icmp eq` and a
# `xor`, test 47's mask.mojo); any mask (bit 60); the last reference
# not inlined at the branch, or not the standard library's (--stdlib); the
# shape taken at a call of a measured nodebug function (still refused).
rinsert '  %83 = icmp ne i64 %82, 0, !dbg !225' '  br i1 %83, label %62, label %63, !dbg !225, !prof !288'
refused "user mask" "src/pkg/d.mojo:14:26: a br at '!= ' is neither" "$W/v.ll"
rvariant 's/^  %34 = and i64 %33, 4611686018427387904/  %34 = and i64 %33, 1152921504606846976/'
refused "mask bit 60" "src/pkg/d.mojo:5:10: a br at '== ' is neither" "$W/v.ll"
rvariant 's/^!217 = !DILocation(line: 492, column: 10, scope: !208, inlinedAt: !216)/!217 = !DILocation(line: 492, column: 10, scope: !208, inlinedAt: !210)/'
refused "last reference elsewhere" "src/pkg/d.mojo:6:11: a br at '+=' is neither" "$W/v.ll"
run "$TOOL" --ir "$RX" --out "$W/out.info" $MAP --stdlib oss/other/ --exclude oss/modular/ --exclude buck-out/ --exclude-file tests/test_a.mojo
[ "$RC" -eq 1 ] || red "last reference outside --stdlib: exit $RC, want 1"
grep -qF "src/pkg/d.mojo:6:11: a br at '+=' is neither" "$W/err" || red "last reference outside --stdlib: 6:11 not refused"
pass
rinsert '  %35 = icmp ne i64 %34, 0, !dbg !213' '  br i1 %35, label %36, label %41, !dbg !229, !prof !283'
refused "String at a nodebug call" "src/pkg/d.mojo:9:32: a br at 'gn[Int](' may be a decision of gn, which src/pkg/d.mojo:50 declares" "$W/v.ll"

# 11b. A subscript's `[` and a call's select take only a raising call's error
# flag; `name[...](` is a call of `name`. Kills: a `[` taking any br; a call
# taking any select; `%=` taken as `//=` is. (The nodebug check keyed on the
# text before `(`, `]`, is killed by 11a's last case.)
rinsert '  %61 = extractvalue { i1, ptr } %60, 0, !dbg !219' '  %900 = icmp slt i64 %43, 0, !dbg !219' '  br i1 %900, label %62, label %63, !dbg !219, !prof !285'
refused "subscript, not raising" "src/pkg/d.mojo:8:14: a br at '[' that is not on a raising call's error flag" "$W/v.ll"
rinsert '  %72 = select i1 %71, i64 1, i64 2, !dbg !221, !prof !283' '  %901 = icmp slt i64 %43, 0, !dbg !221' '  %902 = select i1 %901, i64 1, i64 2, !dbg !221, !prof !283'
refused "call select, not raising" "src/pkg/d.mojo:10:14: a select at 'h(' that is not on a raising call's error flag" "$W/v.ll"
rvariant 's/^!222 = !DILocation(line: 12, column: 7,/!222 = !DILocation(line: 13, column: 7,/'
refused "%=" "src/pkg/d.mojo:13:7: a select at '%=' is neither" "$W/v.ll"

# 11c. An iterable with no head (a subscript) is no loop decision. Kills: a
# head computed for any iterable.
rinsert '  %22 = icmp eq i8 %21, 0, !dbg !234' '  br i1 %22, label %23, label %23, !dbg !237, !prof !290'
refused "no head" "src/pkg/d.mojo:31:14: a br at 'xs' is neither" "$W/v.ll"

# 11d. A reload of another pointer than the left operand's, or one in a
# block doing more, is not the deciding value; a constant arriving through a
# block both targets reach is not under the deciding target. Kills: any
# non-constant from the deciding block taken; "reachable from" taken for
# "dominated by".
rvariant 's/^  %10 = load i1, ptr %5, align 1, !dbg !242/  %10 = load i1, ptr %3, align 1, !dbg !242/'
refused "reload, other pointer" "src/pkg/d.mojo:36:17: IR line 157: the phi at this 'and' is not that of a short-circuit one" "$W/v.ll"
rinsert '9:                                                ; preds = %4' '  store i1 false, ptr %5, align 1, !dbg !242'
refused "reload, a store before it" "src/pkg/d.mojo:36:17: IR line 158: the phi at this 'and' is not that of a short-circuit one" "$W/v.ll"
rinsert '  %57 = load i1, ptr %56, align 1, !dbg !328' '  store i1 false, ptr %56, align 1, !dbg !328'
refused "reload, a store after the left operand" "src/pkg/d.mojo:76:26: IR line 344: the phi at this 'and' is not that of a short-circuit one" "$W/v.ll"
rvariant 's/^31:  *; preds = %28, %29$/31:                                                ; preds = %28, %29, %21/'
refused "constant under both" "src/pkg/d.mojo:38:16: a short-circuit 'and' (a br) whose result is not a phi at its location: its right operand cannot be counted (IR line 184: the phi at this 'and' does not join" "$W/v.ll"

# 11f. A call `name[...](` over lines is a call of `name` (a nodebug one
# refused); a select at a call on a value a br at the call tests is that
# br's only with the same weights; a String's flags carried in phis needs
# a leaf that is a String's (a field-2 load, or a static String's flags).
# Kills: the nodebug check missing a call over lines, or naming the callee
# from a bracket in a string literal or a comment; a select taken on any value some br
# tests; phis of constants taken as a String's.
rinsert '  br i1 %14, label %15, label %15, !dbg !314, !prof !285' '  br i1 %14, label %15, label %15, !dbg !315, !prof !285'
refused "nodebug call over lines" "src/pkg/d.mojo:68:6: a br at 'gn[' may be a decision of gn" "$W/v.ll"
# The same call with a string literal holding a `[`, or a comment holding
# a `]`, in its parameters is still a call of gn. Kills: brackets in string
# literals (the name would be `a`, no nodebug function) or comments counted
# when the name before `[` is looked for.
for e in '67s/^        Int,$/        Int, "a[b",/' '67s/^        Int,$/        Int,  # a]/'; do
    sed -e "$e" "$DIR/fixtures/d.src" >"$W/$SRC/d.mojo"
    ! cmp -s "$W/$SRC/d.mojo" "$DIR/fixtures/d.src" || red "variant '$e' does not change d.mojo"
    refused "bracket in a literal: $e" "src/pkg/d.mojo:68:6: a br at 'gn[' may be a decision of gn" "$W/v.ll"
done
# A triple-quoted string running over lines in its parameters refuses the
# branch: read line by line, `gn["""` then `x[""", Int,` names the call `x`
# (no nodebug function), and the br would be taken as a call's. Kills: the
# refusal dropped (a `"""` or `'''` read as one-line literals).
for q in '"""' "'''"; do
    sed -e "66s/^    v += gn\[\$/    v += gn[$q/" -e "67s/^        Int,\$/        x[$q, Int,/" "$DIR/fixtures/d.src" >"$W/$SRC/d.mojo"
    [ "$(sed -n 66,67p "$W/$SRC/d.mojo")" = "    v += gn[$q
        x[$q, Int," ] || red "triple quote $q: d.mojo lines 66-67 not changed"
    refused "triple-quoted string over lines: $q" "src/pkg/d.mojo:68:6: a br at '(v)': the name of the call whose parameters close here is not read: line 67 holds a triple-quoted string's quotes" "$W/v.ll"
done
cp "$DIR/fixtures/d.src" "$W/$SRC/d.mojo"
rvariant 's/^  %21 = select i1 %19, i1 true, i1 %20, !dbg !316, !prof !292/  %21 = select i1 %19, i1 true, i1 %20, !dbg !316, !prof !293/'
refused "select, other weights than the br" "src/pkg/d.mojo:69:17: a select at 'overflows(' that is not on a raising call's error flag" "$W/v.ll"
rvariant 's/^  %30 = phi i64 \[ %28, %27 \], \[ 2305843009213693952, %26 \]/  %30 = phi i64 [ %28, %27 ], [ 5, %26 ]/'
refused "flags phis, no String leaf" "src/pkg/d.mojo:71:28: a select at 'read(' that is not on a raising call's error flag" "$W/v.ll"

# 11e. Copies of a function whose n-th conditions are computed in one
# header are summed (44,5, case 11); one computed on the `elif` line is
# not in the `if`'s header. Kills: the header check dropped (any two
# positions taken).
rvariant 's/^  br i1 %3, label %4, label %5, !dbg !266, !prof !273/  br i1 %6, label %4, label %5, !dbg !266, !prof !273/; s/^  br i1 %6, label %4, label %4, !dbg !266, !prof !274/  br i1 %3, label %4, label %4, !dbg !266, !prof !274/'
refused "copies, elif line" "src/pkg/d.mojo:44:5 (br): two copies of its function hold different branches here" "$W/v.ll"

# 12. A `try:` body (README.md, "try"), on try.ll and t.mojo: the golden
# output, byte for byte. Each raising call's error check in a `try:` body of
# its function is a decision of two arms, arm 0 the call returned (LLVM's
# false), arm 1 it raised into the handler (true): a call's `i1` (6,14), the
# field 0 of its `{ i1, ... }` (5,14), a Dict subscript's `[` (7,15), an
# inlined raising callee's flag, a phi of its `if`'s condition (8,17), a
# phi of a call's flag (9,17), a call in a nested `try:` (11,19), one in
# the `except` body of a `try` inside another's body (13,19), a one-line
# `try: return f(x)` (35,18), one that never ran (28,22: `-`), and the
# raising right operand of an `and` (49,23), whose error check tests a phi
# of the and's result shape: the `if` (49,9) is the and's test, not the
# `try` decision (as rules.ll's 74,12, in a `try:` body), and a callee
# inlined from another file whose flag is a phi of `true` and `false`
# arriving from its raise path and its return (56,30, as
# `komira_parquet`'s rle.mojo 226:54, `read_uleb128`). A
# String's destructor and a select at 5,14 stay compiler-made, so does the
# error check of a call in an `except` (17), an `else` (19) or after the
# `try` (22), in a `def` nested in a `try:` body (27), in a `with` body
# (33), and after a triple-quoted string holding `try:` (41). Kills, named
# below: the rule removed (no `try` record); the scope ignored (a call
# outside a `try:` body recorded); the arms in LLVM's order (5,14 is 5,2);
# the clause rule (an `except`/`else` body read as the `try`'s); the `def`
# boundary; the triple-quoted lines, or a signature's continuation lines
# (64: `) raises -> Int:` has the `def`'s indentation), read as statements; a `try` decision
# taken as an and/or's test (49,16's right operand derived from 49,23).
run "$TOOL" --ir "$TX" --out "$W/out.info" $MAP $EXC
[ "$RC" -eq 0 ] || red "try golden: exit $RC, want 0"
if ! cmp -s "$W/out.info" "$TGOLDEN"; then
    diff -u "$TGOLDEN" "$W/out.info" >&2 || true
    red "try golden: the output differs from fixtures/try.golden.info"
fi
want="1 measured file(s): 16 source decision(s) (if 3, elif 0, while 0, and 1, or 0, for-in 0, try 12; 1 right operand(s) derived, 0 and/or result(s) no test reads, 0 a second test of one decision), 9 compiler-made (String lifetime 1, + 0, call( 8, [ 0, // 0, % 0) not written; 1 branch(es) outside the measured sources"
grep -qF "$want" "$W/err" || red "try golden: stderr does not say '$want'"
[ "$(grep -c ':try:' "$W/out.info")" = 24 ] || red "try: not twelve try decisions of two arms (the rule removed, or the scope ignored)"
grep -qx 'BRDA:49,16:rhs:0/1,0,1' "$W/out.info" || red "try and and: 49,16's right operand is not 1 true (derived from the call's try decision, not the if)"
grep -qx 'BRDA:5,14:try:0/1,0,5' "$W/out.info" || red "try arms: 5,14 arm 0 (the call returned) is not 5 (arms in LLVM's order)"
grep -qx 'BRDA:13,19:try:0/1,1,0' "$W/out.info" || red "nested try: 13,19 (an inner except body, in the outer try body) is not a try decision"
! grep -qE '^BRDA:(17|19|22|27|33|41|64),' "$W/out.info" || red "try scope: a call outside a try body (except, else, after, nested def, with, after a quoted try:, a nested def whose signature runs over lines) was recorded"
pass

# tinsert <line of try.ll> <line>...: try.ll with the lines after that one.
tinsert() {
    at=$1
    shift
    awk -v at="$at" -v add="$(printf '%s\n' "$@")" '{ print } $0 == at { print add }' "$TX" >"$W/v.ll"
    ! cmp -s "$W/v.ll" "$TX" || red "insert after '$at' changes nothing, so its case checks nothing"
}

# 12a. In a `try:` body a br at a call, `[` or `+` that is not a raising
# call's error flag is refused (whether it is the call's error check is not
# known); so is a phi whose value is not inlined at the call, or whose
# constants arrive from no block of a callee inlined there (kills: such a
# phi accepted without that evidence), or say `true` from a block that is
# not the callee's raise path; `try` and
# `with` keep no branch of their own. Kills: the refusal dropped (any br at
# a call in a try body dropped or taken); the inlined-at check of the phi
# dropped; `try` or `with` taken as a token.
tinsert '  %6 = extractvalue { i1, i64 } %5, 0, !dbg !410' '  %900 = icmp slt i64 %0, 0, !dbg !410' '  br i1 %900, label %9, label %14, !dbg !410, !prof !480'
refused "try, a call's br not on its flag" "src/pkg/t.mojo:5:14: a br at 'f(' in a try body that is not a raising call's error flag" "$W/v.ll"
tinsert '  %32 = extractvalue { i1, i64 } %31, 0, !dbg !418' '  %900 = icmp slt i64 %0, 0, !dbg !439' '  br i1 %900, label %33, label %36, !dbg !439, !prof !480' '!439 = !DILocation(line: 11, column: 22, scope: !403)'
sed -e '/^!439 = /d' "$W/v.ll" >"$W/v2.ll"
printf '%s\n' '!439 = !DILocation(line: 11, column: 22, scope: !403)' >>"$W/v2.ll"
refused "try, a br at '+'" "src/pkg/t.mojo:11:22: a br at '+' in a try body that is not a raising call's error flag" "$W/v2.ll"
sed -e 's/^!414 = !DILocation(line: 44, column: 10, scope: !409, inlinedAt: !413)/!414 = !DILocation(line: 44, column: 10, scope: !409, inlinedAt: !421)/' "$TX" >"$W/v.ll"
! cmp -s "$W/v.ll" "$TX" || red "variant: the inlinedAt edit changed nothing"
refused "try, a phi of code inlined elsewhere" "src/pkg/t.mojo:8:17: a br at 'inl(' in a try body that is not a raising call's error flag" "$W/v.ll"
sed -e 's/^!455 = !DILocation(line: 283, column: 17, scope: !459, inlinedAt: !452)/!455 = !DILocation(line: 57, column: 5, scope: !451)/' \
    -e 's/^!456 = !DILocation(line: 292, column: 9, scope: !459, inlinedAt: !452)/!456 = !DILocation(line: 56, column: 9, scope: !451)/' "$TX" >"$W/v.ll"
grep -qx '!455 = !DILocation(line: 57, column: 5, scope: !451)' "$W/v.ll" && grep -qx '!456 = !DILocation(line: 56, column: 9, scope: !451)' "$W/v.ll" || red "variant: the two block locations were not both changed"
refused "try, constants from no callee block" "src/pkg/t.mojo:56:30: a br at 'read_uleb128(' in a try body that is not a raising call's error flag" "$W/v.ll"
# The constants swapped: `true` arrives from the callee's return, `false`
# from its raise path (the block calling the raise hook). Read as a flag,
# its arms would swap; it is refused. Kills: the polarity check dropped.
sed -e 's/^  %7 = phi i1 \[ false, %5 \], \[ true, %4 \], !dbg !452$/  %7 = phi i1 [ true, %5 ], [ false, %4 ], !dbg !452/' "$TX" >"$W/v.ll"
! cmp -s "$W/v.ll" "$TX" || red "variant: the constant swap changed nothing"
refused "try, constants of the wrong polarity" "src/pkg/t.mojo:56:30: a br at 'read_uleb128(' in a try body that is not a raising call's error flag" "$W/v.ll"
# Both constants `true`, one from the raise path and one from the return:
# the raise block's `true` is there, but the return's says raised too.
# Kills: the polarity check dropped alone (the `true` from the raise block
# still required).
sed -e 's/^  %7 = phi i1 \[ false, %5 \], \[ true, %4 \], !dbg !452$/  %7 = phi i1 [ true, %5 ], [ true, %4 ], !dbg !452/' "$TX" >"$W/v.ll"
! cmp -s "$W/v.ll" "$TX" || red "variant: the true/true edit changed nothing"
refused "try, true from the return too" "src/pkg/t.mojo:56:30: a br at 'read_uleb128(' in a try body that is not a raising call's error flag" "$W/v.ll"
# 12b. Brackets that do not balance in a measured file: which lines are
# continuations cannot be told, so whether a call is in a `try:` body
# cannot either; refused once, naming the file and the line. Kills: the
# refusal removed (every later line skipped, inTry false: the calls in
# `try:` bodies read as the compiler's, silently).
printf '    v = f(\n' >>"$W/$SRC/t.mojo"
refused "unbalanced, never closed" "src/pkg/t.mojo: the brackets of the file do not balance (a bracket line 68 opens is never closed)" "$TX"
cp "$DIR/fixtures/t.src" "$W/$SRC/t.mojo"
printf '    )\n' >>"$W/$SRC/t.mojo"
refused "unbalanced, closed twice" "src/pkg/t.mojo: the brackets of the file do not balance (line 68 closes a bracket no line opened)" "$TX"
cp "$DIR/fixtures/t.src" "$W/$SRC/t.mojo"
tinsert '  %15 = call i1 @"pkg::t::touch"(i64 %0, ptr %3), !dbg !411' '  br i1 %15, label %90, label %16, !dbg !440, !prof !482' '!440 = !DILocation(line: 4, column: 5, scope: !403)'
sed -e '/^!440 = /d' "$W/v.ll" >"$W/v2.ll"
printf '%s\n' '!440 = !DILocation(line: 4, column: 5, scope: !403)' >>"$W/v2.ll"
refused "try keyword" "src/pkg/t.mojo:4:5: a br at 'try' is neither" "$W/v2.ll"
sed -e 's/^  br i1 %4, label %5, label %5, !dbg !432, !prof !489/  br i1 %4, label %5, label %5, !dbg !433, !prof !489/' "$TX" >"$W/v.ll"
! cmp -s "$W/v.ll" "$TX" || red "variant: the with edit changed nothing"
refused "with keyword" "src/pkg/t.mojo:32:5: a br at 'with' is neither" "$W/v.ll"

# 12c. A `try` decision is no test of an and/or's result (README.md, "try"),
# even one that ran as many times as the left operand: in `ands` (49,16)
# the call's error check tests the flag phi beside the result, here given
# the counts of a br after the join (7, as the left operand's 4 + 3), and
# the `if` (49,9) is the test. Kills: a `try` decision taken as a test (the
# right operand derived from the error check: 0 true, 4 false).
sed -e 's/^!492 = .*/!492 = !{!"branch_weights", i32 0, i32 7}/' "$TX" >"$W/v.ll"
! cmp -s "$W/v.ll" "$TX" || red "try, no test: the edit changed nothing"
run "$TOOL" --ir "$W/v.ll" --out "$W/out.info" $MAP $EXC
[ "$RC" -eq 0 ] || red "try, no test: exit $RC, want 0"
grep -qx 'BRDA:49,16:rhs:0/1,0,1' "$W/out.info" || red "try, no test: 49,16's right operand is not the if's 1 true (derived from the try's error check)"
grep -qx 'BRDA:49,16:rhs:0/1,1,3' "$W/out.info" || red "try, no test: 49,16's right operand is not 4-1 false"
pass

# 10. Bad usage exits 2.
for args in "--out $W/out.info $MAP $STD" "--ir $FX $MAP $STD" "--ir $FX --out $W/out.info $STD" \
    "--ir $FX --out $W/out.info --map $SRC=src/pkg/ $STD" "--ir $FX --out $W/out.info --map $SRC/=/abs/ $STD" \
    "--ir $FX --out $W/out.info $MAP $MAP $STD" "--ir $FX --out $W/out.info $MAP $STD --frobnicate x" \
    "--ir $FX --out $W/out.info $MAP $STD --exclude oss" "--ir $FX --out $W/out.info $MAP $STD --gen /abs" \
    "--ir $FX --out $W/out.info $MAP" "--ir $FX --out $W/out.info $MAP $STD $STD" "--ir $FX --out $W/out.info $MAP --stdlib oss"; do
    run "$TOOL" $args
    [ "$RC" -eq 2 ] || red "usage '$args': exit $RC, want 2"
    grep -q '^usage: cov_branch_classify' "$W/err" || red "usage '$args': no usage line"
done
pass

cd /
rm -rf "$T"
printf '{"version": 1, "data": {"status": "success", "message": "cov_branch_classify: %s cases passed"}}\n' "$N" >"$RESULT"
echo "cov_branch_classify_cases GREEN: $N cases"
