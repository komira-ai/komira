//! cov_branch_classify's `try:` cases on fixtures/try.ll and t.mojo
//! (README.md#tests, "try"), the numbers those of the shell cases they
//! replace (12 to 12c). Each runs the shipped executable
//! (cov_branch_classify_harness.zig) and says the defect (mutant) it kills.

const std = @import("std");
const h = @import("cov_branch_classify_harness.zig");

/// try.ll with `add` after each line `at` (the shell's tinsert).
fn tinsert(c: *h.Case, at: []const u8, add: []const []const u8) !h.Ir {
    var e = try h.Ir.of(c.a(), h.try_ll);
    try e.insertAfter(at, add);
    return e;
}

/// try.ll with the prefix `old` of a line replaced (sed 's/^old/new/').
fn tvariant(c: *h.Case, old: []const u8, new: []const u8) !h.Ir {
    var e = try h.Ir.of(c.a(), h.try_ll);
    try e.subStart(old, new);
    return e;
}

/// The lines starting with `prefix` moved to the end (sed '/^prefix/d'
/// then the line appended): metadata inserted mid-function by tinsert.
fn metaLast(e: *h.Ir, prefix: []const u8, line: []const u8) ![]const u8 {
    try e.drop(prefix, .prefix);
    try e.append(&.{line});
    return e.text();
}

// 12. A `try:` body (README.md, "try"), on try.ll and t.mojo: the golden
// output, byte for byte. Each raising call's error check in a `try:` body
// of its function is a decision of two arms, arm 0 the call returned
// (LLVM's false), arm 1 it raised into the handler (true): a call's `i1`
// (6,14), the field 0 of its `{ i1, ... }` (5,14), a Dict subscript's `[`
// (7,15), an inlined raising callee's flag, a phi of its `if`'s condition
// (8,17), a phi of a call's flag (9,17), a call in a nested `try:` (11,19),
// one in the `except` body of a `try` inside another's body (13,19), a
// one-line `try: return f(x)` (35,18), one that never ran (28,22: `-`), and
// the raising right operand of an `and` (49,23), whose error check tests a
// phi of the and's result shape: the `if` (49,9) is the and's test, not the
// `try` decision (as rules.ll's 74,12, in a `try:` body), and a callee
// inlined from another file whose flag is a phi of `true` and `false`
// arriving from its raise path and its return (56,30, as `komira_parquet`'s
// rle.mojo 226:54, `read_uleb128`). A String's destructor and a select at
// 5,14 stay compiler-made, so does the error check of a call in an
// `except` (17), an `else` (19) or after the `try` (22), in a `def` nested
// in a `try:` body (27), in a `with` body (33), and after a triple-quoted
// string holding `try:` (41). Kills, named below: the rule removed (no
// `try` record); the scope ignored (a call outside a `try:` body recorded);
// the arms in LLVM's order (5,14 is 5,2); the clause rule (an
// `except`/`else` body read as the `try`'s); the `def` boundary; the
// triple-quoted lines, or a signature's continuation lines (64: `) raises
// -> Int:` has the `def`'s indentation), read as statements; a `try`
// decision taken as an and/or's test (49,16's right operand derived from
// 49,23).
test "12 try golden: try.ll gives try.golden.info byte for byte" {
    var c = try h.Case.init("try golden");
    defer c.deinit();
    const r = try c.run(h.try_ll);
    try r.exits(0);
    try r.golden(h.try_golden, "the output differs from fixtures/try.golden.info");
    try r.says("1 measured file(s): 16 source decision(s) (if 3, elif 0, while 0, and 1, or 0, for-in 0, try 12; 1 right operand(s) derived, 0 and/or result(s) no test reads, 0 a second test of one decision), 9 compiler-made (String lifetime 1, + 0, call( 8, [ 0, // 0, % 0) not written; 1 branch(es) outside the measured sources");
    try std.testing.expectEqual(@as(usize, 24), h.count(try r.output(), ":try:", .contains)); // not twelve try decisions of two arms (the rule removed, or the scope ignored)
    try r.has("BRDA:49,16:rhs:0/1,0,1", "try and and: 49,16's right operand is not 1 true (derived from the call's try decision, not the if)");
    try r.has("BRDA:5,14:try:0/1,0,5", "try arms: 5,14 arm 0 (the call returned) is not 5 (arms in LLVM's order)");
    try r.has("BRDA:13,19:try:0/1,1,0", "nested try: 13,19 (an inner except body, in the outer try body) is not a try decision");
    for ([_][]const u8{ "BRDA:17,", "BRDA:19,", "BRDA:22,", "BRDA:27,", "BRDA:33,", "BRDA:41,", "BRDA:64," }) |p| {
        try r.lacks(p, "try scope: a call outside a try body (except, else, after, nested def, with, after a quoted try:, a nested def whose signature runs over lines) was recorded");
    }
}

// 12a. In a `try:` body a br at a call, `[` or `+` that is not a raising
// call's error flag is refused (whether it is the call's error check is not
// known); so is a phi whose value is not inlined at the call, or whose
// constants arrive from no block of a callee inlined there (kills: such a
// phi accepted without that evidence), or say `true` from a block that is
// not the callee's raise path; `try` and `with` keep no branch of their
// own. Kills: the refusal dropped (any br at a call in a try body dropped
// or taken); the inlined-at check of the phi dropped; `try` or `with` taken
// as a token.
test "12a a br at a call in a try body not on its flag: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    const e = try tinsert(&c, "  %6 = extractvalue { i1, i64 } %5, 0, !dbg !410", &.{ "  %900 = icmp slt i64 %0, 0, !dbg !410", "  br i1 %900, label %9, label %14, !dbg !410, !prof !480" });
    _ = try c.refused("try, a call's br not on its flag", "src/pkg/t.mojo:5:14: a br at 'f(' in a try body that is not a raising call's error flag", try e.text());
}

test "12a a br at '+' in a try body: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    const loc = "!439 = !DILocation(line: 11, column: 22, scope: !403)";
    var e = try tinsert(&c, "  %32 = extractvalue { i1, i64 } %31, 0, !dbg !418", &.{ "  %900 = icmp slt i64 %0, 0, !dbg !439", "  br i1 %900, label %33, label %36, !dbg !439, !prof !480", loc });
    _ = try c.refused("try, a br at '+'", "src/pkg/t.mojo:11:22: a br at '+' in a try body that is not a raising call's error flag", try metaLast(&e, "!439 = ", loc));
}

test "12a a phi of code inlined elsewhere: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    const e = try tvariant(&c, "!414 = !DILocation(line: 44, column: 10, scope: !409, inlinedAt: !413)", "!414 = !DILocation(line: 44, column: 10, scope: !409, inlinedAt: !421)");
    _ = try c.refused("try, a phi of code inlined elsewhere", "src/pkg/t.mojo:8:17: a br at 'inl(' in a try body that is not a raising call's error flag", try e.text());
}

test "12a constants from no block of the inlined callee: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try tvariant(&c, "!455 = !DILocation(line: 283, column: 17, scope: !459, inlinedAt: !452)", "!455 = !DILocation(line: 57, column: 5, scope: !451)");
    try e.subStart("!456 = !DILocation(line: 292, column: 9, scope: !459, inlinedAt: !452)", "!456 = !DILocation(line: 56, column: 9, scope: !451)");
    _ = try e.find(0, e.lines.items.len, "!455 = !DILocation(line: 57, column: 5, scope: !451)");
    _ = try e.find(0, e.lines.items.len, "!456 = !DILocation(line: 56, column: 9, scope: !451)");
    _ = try c.refused("try, constants from no callee block", "src/pkg/t.mojo:56:30: a br at 'read_uleb128(' in a try body that is not a raising call's error flag", try e.text());
}

// The constants swapped: `true` arrives from the callee's return, `false`
// from its raise path (the block calling the raise hook). Read as a flag,
// its arms would swap; it is refused. Kills: the polarity check dropped.
test "12a constants of the wrong polarity: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.try_ll);
    try e.subExact("  %7 = phi i1 [ false, %5 ], [ true, %4 ], !dbg !452", "  %7 = phi i1 [ true, %5 ], [ false, %4 ], !dbg !452");
    _ = try c.refused("try, constants of the wrong polarity", "src/pkg/t.mojo:56:30: a br at 'read_uleb128(' in a try body that is not a raising call's error flag", try e.text());
}

// Both constants `true`, one from the raise path and one from the return:
// the raise block's `true` is there, but the return's says raised too.
// Kills: the polarity check dropped alone (the `true` from the raise block
// still required).
test "12a true from the return too: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.try_ll);
    try e.subExact("  %7 = phi i1 [ false, %5 ], [ true, %4 ], !dbg !452", "  %7 = phi i1 [ true, %5 ], [ true, %4 ], !dbg !452");
    _ = try c.refused("try, true from the return too", "src/pkg/t.mojo:56:30: a br at 'read_uleb128(' in a try body that is not a raising call's error flag", try e.text());
}

// 12b. Brackets that do not balance in a measured file: which lines are
// continuations cannot be told, so whether a call is in a `try:` body
// cannot either; refused once, naming the file and the line. Kills: the
// refusal removed (every later line skipped, inTry false: the calls in
// `try:` bodies read as the compiler's, silently).
test "12b brackets never closed: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    try c.source("t", h.t_src ++ "    v = f(\n");
    _ = try c.refused("unbalanced, never closed", "src/pkg/t.mojo: the brackets of the file do not balance (a bracket line 68 opens is never closed)", h.try_ll);
}

test "12b a bracket closed twice: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    try c.source("t", h.t_src ++ "    )\n");
    _ = try c.refused("unbalanced, closed twice", "src/pkg/t.mojo: the brackets of the file do not balance (line 68 closes a bracket no line opened)", h.try_ll);
}

test "12b a br at 'try': refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    const loc = "!440 = !DILocation(line: 4, column: 5, scope: !403)";
    var e = try tinsert(&c, "  %15 = call i1 @\"pkg::t::touch\"(i64 %0, ptr %3), !dbg !411", &.{ "  br i1 %15, label %90, label %16, !dbg !440, !prof !482", loc });
    _ = try c.refused("try keyword", "src/pkg/t.mojo:4:5: a br at 'try' is neither", try metaLast(&e, "!440 = ", loc));
}

test "12b a br at 'with': refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    const e = try tvariant(&c, "  br i1 %4, label %5, label %5, !dbg !432, !prof !489", "  br i1 %4, label %5, label %5, !dbg !433, !prof !489");
    _ = try c.refused("with keyword", "src/pkg/t.mojo:32:5: a br at 'with' is neither", try e.text());
}

// 12c. A `try` decision is no test of an and/or's result (README.md,
// "try"), even one that ran as many times as the left operand: in `ands`
// (49,16) the call's error check tests the flag phi beside the result, here
// given the counts of a br after the join (7, as the left operand's 4 + 3),
// and the `if` (49,9) is the test. Kills: a `try` decision taken as a test
// (the right operand derived from the error check: 0 true, 4 false).
test "12c a try decision is no test of an and's result" {
    var c = try h.Case.init("try, no test");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.try_ll);
    try e.subLine("!492 = ", "!492 = !{!\"branch_weights\", i32 0, i32 7}");
    const r = try c.run(try e.text());
    try r.exits(0);
    try r.has("BRDA:49,16:rhs:0/1,0,1", "try, no test: 49,16's right operand is not the if's 1 true (derived from the try's error check)");
    try r.has("BRDA:49,16:rhs:0/1,1,3", "try, no test: 49,16's right operand is not 4-1 false");
}
