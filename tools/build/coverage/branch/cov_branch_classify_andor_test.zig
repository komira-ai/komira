//! cov_branch_classify's and/or cases on fixtures/case.ll (README.md#tests),
//! the numbers those of the shell cases they replace (9j, 9k): an and/or
//! whose result no source decision tests, the phis at its token, error flags
//! beside the result, and three short-circuits on one line. Each runs the
//! shipped executable (cov_branch_classify_harness.zig) and says the defect
//! (mutant) it kills.

const std = @import("std");
const h = @import("cov_branch_classify_harness.zig");

const untested_and = "src/pkg/c.mojo:7:14: the right operand of this 'and' is not counted (no test in this function reads its result), and a phi at its location is neither its result nor an error flag";
const untested_or = "src/pkg/c.mojo:3:17: the right operand of this 'or' is not counted (no test in this function reads its result), and a phi at its location is neither its result nor an error flag";
const and_phi = "  %8 = phi i1 [ %5, %4 ], [ false, %6 ], !dbg !117";

/// both(): c.mojo 7,14's `and` with the `if` (7,5) testing another value,
/// a forward of the result (one incoming value) at the `and` between.
/// `cond` names what the `if` tests: %80 (another value) or %87 (the
/// forward). The shell's both_untested.
fn bothUntested(c: *h.Case, cond: []const u8) !h.Ir {
    var e = try h.Ir.of(c.a(), h.case_ll);
    const f = try e.function("@\"pkg::c::both\"");
    for (e.lines.items[f[0]..f[1]]) |*l| {
        if (std.mem.endsWith(u8, l.*, "preds = %7")) l.* = try std.mem.concat(c.a(), u8, &.{ l.*[0 .. l.len - "preds = %7".len], "preds = %86" });
    }
    const at = try e.find(f[0], f[1], "  br i1 %8, label %9, label %10, !dbg !119, !prof !133");
    var add = std.ArrayList([]const u8).empty;
    try add.appendSlice(c.a(), &.{ "  br label %86, !dbg !119", "", "86:                                               ; preds = %7", "  %87 = phi i1 [ %8, %7 ], !dbg !117" });
    if (std.mem.eql(u8, cond, "%80")) try add.append(c.a(), "  %80 = icmp eq i64 %0, 7, !dbg !119");
    try add.append(c.a(), try std.mem.concat(c.a(), u8, &.{ "  br i1 ", cond, ", label %9, label %10, !dbg !119, !prof !133" }));
    try e.lines.replaceRange(e.al, at, 1, add.items);
    return e;
}

// A select at `or` whose result is stored (`var r = a or b`, c.mojo 13).
// Kills: the old refusal ("the right operand ... is not counted"); the
// untested and/or's own record dropped.
test "9j or not tested: a stored select at 'or' is its own two arms" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.case_ll);
    try e.insertAfter("  %4 = xor i1 %3, true, !dbg !123", &.{"  %7 = select i1 %0, i1 true, i1 %1, !dbg !127, !prof !134"});
    const r = try c.accepted("or not tested", try e.text(), "5 right operand(s) derived, 1 and/or result(s) no test reads");
    try r.has("BRDA:13,15:select:0/1,0,3", "or not tested: 13,15's select is not a decision of 3 (left true, the right operand skipped)");
    try r.has("BRDA:13,15:select:0/1,1,4", "or not tested: 13,15's select is not a decision of 4 (the right operand evaluated)");
    try r.lacks("BRDA:13,15:rhs", "or not tested: a right operand was written with no test of the result");
}

// A short-circuit `and` whose result is passed on (both() with the `if`
// testing another value), a forward of it at its token. Kills: the untested
// br refused; a forward phi (one incoming value) at the token taken for an
// odd one.
test "9j and not tested: a passed-on short-circuit 'and' is its own two arms" {
    var c = try h.Case.init("");
    defer c.deinit();
    const e = try bothUntested(&c, "%80");
    const r = try c.accepted("and not tested", try e.text(), "4 right operand(s) derived, 1 and/or result(s) no test reads");
    try r.has("BRDA:7,14:br:0/1,0,4", "and not tested: 7,14 is not a decision of 4 (the right operand evaluated)");
    try r.has("BRDA:7,14:br:0/1,1,2", "and not tested: 7,14 is not a decision of 2 (the right operand skipped)");
    try r.lacks("BRDA:7,14:rhs", "and not tested: a right operand was written with no test of the result");
}

// The `if` testing the forward: the result's test, read through it. Kills:
// a phi forwarding an awaited value not awaited (no rhs: the and/or alone).
test "9j forward tested: the test through a forward is the result's" {
    var c = try h.Case.init("");
    defer c.deinit();
    const e = try bothUntested(&c, "%87");
    const r = try c.accepted("forward tested", try e.text(), "5 right operand(s) derived, 0 and/or result(s) no test reads");
    try r.has("BRDA:7,14:rhs:0/1,0,3", "forward tested: 7,14's right operand is not 3 true (the test through the forward not read)");
    try r.has("BRDA:7,14:rhs:0/1,1,1", "forward tested: 7,14's right operand is not 4-3 false");
}

// An `i1` phi at the token that is neither a result nor an error flag (the
// `true` arrives under the and's false target): with no test of the
// result, which phi the result is cannot be told. Refused; so is one that
// does not join the branch's targets (arriving from the branch's own
// block). Kills: an untested and/or accepted whatever phis its token holds;
// one not joining the targets left unchecked.
test "9j odd phi: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try bothUntested(&c, "%80");
    try e.insertAfter(and_phi, &.{"  %81 = phi i1 [ %5, %4 ], [ true, %6 ], !dbg !117"});
    const r = try c.refused("odd phi", untested_and, try e.text());
    try r.says("the value arriving under the branch's false target %6 is 'true'");
}

test "9j odd phi, not joining: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try bothUntested(&c, "%80");
    try e.insertAfter(and_phi, &.{"  %81 = phi i1 [ %5, %4 ], [ %3, %2 ], !dbg !117"});
    const r = try c.refused("odd phi, not joining", untested_and, try e.text());
    try r.says("does not join one value arriving under the branch's false target %6 and one under its true target %4");
}

// A test of the result that ran another number of times than the left
// operand (6), or not at all, is not this result's: the and/or alone, no
// rhs. Kills: the old refusals; a right operand derived from such a test.
test "9j test ran 5 of 6: no right operand" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.case_ll);
    try e.subLine("!133 = ", "!133 = !{!\"branch_weights\", i32 3, i32 2}");
    const r = try c.accepted("test ran 5 of 6", try e.text(), "4 right operand(s) derived, 1 and/or result(s) no test reads");
    try r.has("BRDA:7,14:br:0/1,0,4", "test ran 5 of 6: 7,14's own record is not written");
    try r.lacks("BRDA:7,14:rhs", "test ran 5 of 6: a right operand was derived from a test of other counts");
}

test "9j derive totals: no right operand from a test of 5 (its left operand 6)" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.case_ll);
    try e.subLine("!64 = ", "!64 = !{!\"branch_weights\", i32 1, i32 5}");
    const r = try c.accepted("derive totals", try e.text(), "4 right operand(s) derived, 1 and/or result(s) no test reads");
    try r.lacks("BRDA:13,14:rhs", "derive totals: 13,14's right operand derived from a test of 5 (its left operand ran 6)");
}

test "9j or below its operand: no right operand" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.case_ll);
    try e.subLine("!64 = ", "!64 = !{!\"branch_weights\", i32 4, i32 1}");
    const r = try c.accepted("or below its operand", try e.text(), "4 right operand(s) derived, 1 and/or result(s) no test reads");
    try r.lacks("BRDA:13,14:rhs", "or below its operand: 13,14's right operand derived from a test true 3 times (its left operand 4)");
}

test "9j derive one never ran: no right operand, its own record" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.case_ll);
    try e.sub(", !dbg !28, !prof !65", ", !dbg !28");
    const r = try c.accepted("derive one never ran", try e.text(), "4 right operand(s) derived, 1 and/or result(s) no test reads");
    try r.lacks("BRDA:13,14:rhs", "derive one never ran: 13,14's right operand derived from a test that never ran");
    try r.has("BRDA:13,14:select:0/1,1,4", "derive one never ran: 13,14's own record is not written");
}

test "9j and above its operand: no right operand" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.case_ll);
    try e.subLine("!66 = ", "!66 = !{!\"branch_weights\", i32 2, i32 3}");
    const r = try c.accepted("and above its operand", try e.text(), "4 right operand(s) derived, 1 and/or result(s) no test reads");
    try r.lacks("BRDA:15,14:rhs", "and above its operand: 15,14's right operand derived from a test true 3 times (its left operand 2)");
}

// The same with an odd phi at the token: refused, saying why the test was
// not taken. Kills: the odd check skipped for an and/or a test was refused
// for.
test "9j odd phi, test of other counts: refused, saying why" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.case_ll);
    try e.subLine("!133 = ", "!133 = !{!\"branch_weights\", i32 3, i32 2}");
    try e.insertAfter(and_phi, &.{"  %81 = phi i1 [ %5, %4 ], [ true, %6 ], !dbg !117"});
    _ = try c.refused("odd phi, test of other counts", "src/pkg/c.mojo:7:14: the right operand of this 'and' is not counted (src/pkg/c.mojo:7:14: the left operand ran 6 times and the test of the result 5: the right operand cannot be derived), and a phi at its location", try e.text());
}

/// A raising right operand's error flag beside the result of an `or` whose
/// result is passed on (spend(), c.mojo 3,17: `false` under the or's true
/// target, `flag` under the other). The shell's spend_flag.
fn spendFlag(c: *h.Case, flag: []const u8) !h.Ir {
    var e = try h.Ir.of(c.a(), h.case_ll);
    const f = try e.function("@\"pkg::c::spend\"");
    _ = try e.subIn(f[0], f[1], "select i1 %8, ", "select i1 %80, ");
    _ = try e.subIn(f[0], f[1], "br i1 %8, ", "br i1 %80, ");
    const at = try e.find(f[0], f[1], "  %6 = icmp sgt i64 %0, %1, !dbg !112");
    try e.lines.insertSlice(e.al, at + 1, &.{ "  %84 = call { i1, i1 } @\"pkg::c::check\"(i64 %0), !dbg !112", try std.mem.concat(c.a(), u8, &.{ "  %83 = ", flag, ", !dbg !112" }) });
    const phi = try e.find(f[0], f[1] + 2, "  %8 = phi i1 [ %6, %5 ], [ true, %4 ], !dbg !111");
    try e.lines.insertSlice(e.al, phi + 1, &.{ "  %82 = phi i1 [ %83, %5 ], [ false, %4 ], !dbg !111", "  %80 = icmp eq i64 %1, 7, !dbg !113" });
    return e;
}

// Kills: an error flag taken for an odd phi (refused).
test "9j or, raising right operand: an error flag is no odd phi" {
    var c = try h.Case.init("");
    defer c.deinit();
    const e = try spendFlag(&c, "extractvalue { i1, i1 } %84, 0");
    const r = try c.accepted("or, raising right operand", try e.text(), "4 right operand(s) derived, 1 and/or result(s) no test reads");
    try r.has("BRDA:3,17:br:0/1,0,1", "or, raising right operand: 3,17's own record is not written");
    try r.lacks("BRDA:3,17:rhs", "or, raising right operand: a right operand was written with no test of the result");
}

// Kills: any value under the other target taken for a flag.
test "9j or, not a flag: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    const e = try spendFlag(&c, "icmp eq i64 %0, 3");
    _ = try c.refused("or, not a flag", untested_or, try e.text());
}

// The flag's orientation: the call's flag under the or's true target (the
// right operand skipped) and `false` under the other is no error flag (a
// skipped call has no flag), and is odd. Kills: the flag exemption taken
// in either orientation.
test "9j or, flag under the skip target: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try spendFlag(&c, "extractvalue { i1, i1 } %84, 0");
    try e.sub("%82 = phi i1 [ %83, %5 ], [ false, %4 ]", "%82 = phi i1 [ false, %5 ], [ %83, %4 ]");
    _ = try c.refused("or, flag under the skip target", untested_or, try e.text());
}

// An odd phi with three incoming values (not a forward) at an untested
// and's token is refused like one with two. Kills: only two-incoming phis
// marked odd.
test "9j odd phi, three incoming: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try bothUntested(&c, "%80");
    try e.insertAfter(and_phi, &.{"  %81 = phi i1 [ %5, %4 ], [ false, %6 ], [ true, %2 ], !dbg !117"});
    _ = try c.refused("odd phi, three incoming", untested_and, try e.text());
}

// A phi of two constants at a tested `or`, the deciding `true` under its
// true target and `false` under the other, is no result (the right
// operand's value would be a constant): refused, as no candidate is.
// Kills: a constant under the other target accepted (a right operand
// derived from a phi that does not carry it).
test "9j or, two constants: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.case_ll);
    try e.sub("%8 = phi i1 [ %6, %5 ], [ true, %4 ]", "%8 = phi i1 [ false, %5 ], [ true, %4 ]");
    const r = try c.refused("or, two constants", "src/pkg/c.mojo:3:17: IR line", try e.text());
    try r.says("the phi at this 'or' is not that of a short-circuit one");
}

const two_ll =
    \\define internal i64 @"pkg::c::two"(i1 %0, i1 %1, i1 %2, i1 %3) #0 !dbg !170 !prof !73 {
    \\4:
    \\  br i1 %0, label %5, label %6, !dbg !171, !prof !180
    \\
    \\5:                                                ; preds = %4
    \\  br label %7, !dbg !171
    \\
    \\6:                                                ; preds = %4
    \\  br label %7, !dbg !171
    \\
    \\7:                                                ; preds = %5, %6
    \\  %8 = phi i1 [ true, %5 ], [ %1, %6 ], !dbg !171
    \\  br i1 %8, label %9, label %15, !dbg !172, !prof !181
    \\
    \\9:                                                ; preds = %7
    \\  br i1 %2, label %10, label %11, !dbg !173, !prof !182
    \\
    \\10:                                               ; preds = %9
    \\  br label %12, !dbg !173
    \\
    \\11:                                               ; preds = %9
    \\  br label %12, !dbg !173
    \\
    \\12:                                               ; preds = %10, %11
    \\  %13 = phi i1 [ true, %10 ], [ %3, %11 ], !dbg !173
    \\  br label %14, !dbg !172
    \\
    \\14:                                               ; preds = %12
    \\  br label %16, !dbg !172
    \\
    \\15:                                               ; preds = %7
    \\  br label %16, !dbg !172
    \\
    \\16:                                               ; preds = %14, %15
    \\  %17 = phi i1 [ %13, %14 ], [ false, %15 ], !dbg !172
    \\  br i1 %17, label %18, label %19, !dbg !174, !prof !183
    \\
    \\18:                                               ; preds = %16
    \\  ret i64 1, !dbg !175
    \\
    \\19:                                               ; preds = %16
    \\  ret i64 0, !dbg !176
    \\}
    \\
;

const two_meta =
    \\!170 = distinct !DISubprogram(name: "two", linkageName: "pkg::c::two", scope: !8, file: !8, line: 18, type: !9, scopeLine: 18, spFlags: DISPFlagDefinition, unit: !0)
    \\!171 = !DILocation(line: 19, column: 11, scope: !170)
    \\!172 = !DILocation(line: 19, column: 17, scope: !170)
    \\!173 = !DILocation(line: 19, column: 24, scope: !170)
    \\!174 = !DILocation(line: 19, column: 5, scope: !170)
    \\!175 = !DILocation(line: 20, column: 9, scope: !170)
    \\!176 = !DILocation(line: 21, column: 5, scope: !170)
    \\!180 = !{!"branch_weights", i32 2, i32 4}
    \\!181 = !{!"branch_weights", i32 3, i32 3}
    \\!182 = !{!"branch_weights", i32 1, i32 2}
    \\!183 = !{!"branch_weights", i32 2, i32 4}
;

// 9k. Three short-circuit and/or on one line (`if (a or b) and (c or e):`,
// c.mojo 19, a function added to case.ll): each phi is its own and/or's,
// told by its column, and each right operand is derived (the inner `or`'s
// through the `and`'s). Kills: a phi matched to an and/or by its line alone
// (the `and`'s phi taken for the second `or`'s: the `and` refused).
test "9k one line: three short-circuits on one line, each derived" {
    var c = try h.Case.init("one line");
    defer c.deinit();
    try c.source("c", h.c_src ++ "def two(a: Bool, b: Bool, c: Bool, e: Bool) -> Int:\n    if (a or b) and (c or e):\n        return 1\n    return 0\n");
    var e = try h.Ir.of(c.a(), h.case_ll);
    const fun = try h.Ir.of(c.a(), two_ll ++ "\n");
    try e.insertBefore("attributes #0", fun.lines.items);
    const meta = try h.Ir.of(c.a(), two_meta ++ "\n");
    try e.append(meta.lines.items);
    const r = try c.run(try e.text());
    try r.exits(0);
    for ([_][]const u8{ "19,5:br:0/1,0,2", "19,5:br:0/1,1,4", "19,11:br:0/1,0,2", "19,11:rhs:0/1,0,1", "19,11:rhs:0/1,1,3", "19,17:br:0/1,0,3", "19,17:rhs:0/1,0,2", "19,17:rhs:0/1,1,1", "19,24:br:0/1,0,1", "19,24:rhs:0/1,0,1", "19,24:rhs:0/1,1,1" }) |rec| {
        try r.has(try std.mem.concat(c.a(), u8, &.{ "BRDA:", rec }), "one line: a record is not in the output");
    }
}
