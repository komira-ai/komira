//! cov_branch_classify's shape-rule cases on fixtures/rules.ll and d.mojo
//! (README.md#tests), the numbers those of the shell cases they replace (11
//! to 11f): a String's lifetime, a raising call, the loop head, short-circuit
//! forms and copies that folded part of a header. Each runs the shipped
//! executable (cov_branch_classify_harness.zig) and says the defect (mutant)
//! it kills.

const std = @import("std");
const h = @import("cov_branch_classify_harness.zig");

/// rules.ll with `add` after each line `at` (the shell's rinsert).
fn rinsert(c: *h.Case, at: []const u8, add: []const []const u8) ![]const u8 {
    var e = try h.Ir.of(c.a(), h.rules_ll);
    try e.insertAfter(at, add);
    return e.text();
}

/// rules.ll with the prefix `old` of a line replaced (sed 's/^old/new/').
fn rvariant(c: *h.Case, old: []const u8, new: []const u8) ![]const u8 {
    var e = try h.Ir.of(c.a(), h.rules_ll);
    try e.subStart(old, new);
    return e.text();
}

// 11. The shape rules (README.md: String lifetime, a raising call, the loop
// head, short-circuit forms, copies that folded part of a header), on
// rules.ll and d.mojo: the golden output, byte for byte. Each shape is an
// excerpt of a library's IR (README.md names where). Kills, each named
// below: a String destructor or copy at a decision's token recorded as the
// decision (d.mojo 3,5: the `if flag` with four more branches, bits 62 and
// 63, the last-reference test, the negated bit-62 test, all at 3:5, which
// the classifier before this rule wrote as 3,5:br:0/5 to 4/5); a test at a
// decision's token computed elsewhere taken as a String's (16,5 stays a
// decision); a user mask taken as a String's (14,5); a loop head taken at
// another column (23,18 the attribute's `.`, 27,28 a call's `(`); a raising
// call at a loop head dropped (27,28 holds two decisions); a short-circuit
// `and` whose left operand is reloaded (36,17), whose constant arrives
// through a String destructor's diamond (38,16), or whose right operand is
// a nested `and` (40,39 derived from 40,21's right operand through the
// `not`); two copies of `at` (44,5), one of which folded `index < 0` away,
// not summed; in `more`, loop heads on a list literal running over lines
// (54,14), a string literal's method (59,27) and an attribute after a call
// (61,22); a call `p.run[...](` over three lines (65:6, compiler-made); a
// select at an inlined raising call on the flag its error check tests
// (69:17), and one on a call's `i1` its error check tests (71:18); a String
// carried in phis of an inlined callee (71:28); an `or` and an `and` whose
// raising right operand's error flag is a phi beside the result (72,12 and
// 74,12: the and's error flag has the result's shape and is tested by the
// call's error check, not by the `if`); a reload with a destructor call
// after it (76,26).
test "11 rules golden: rules.ll gives rules.golden.info byte for byte" {
    var c = try h.Case.init("rules golden");
    defer c.deinit();
    const r = try c.run(h.rules_ll);
    try r.exits(0);
    try r.golden(h.rules_golden, "the output differs from fixtures/rules.golden.info");
    try r.says("1 measured file(s): 33 source decision(s) (if 15, elif 0, while 0, and 6, or 2, for-in 10, try 0; 8 right operand(s) derived, 0 and/or result(s) no test reads, 1 a second test of one decision), 26 compiler-made (String lifetime 15, + 0, call( 9, [ 1, // 1, % 0) not written; 0 branch(es) outside the measured sources");
    try r.counts("BRDA:3,5:", 2, "String at a decision: 3,5 is not one decision of two arms (a destructor's branch recorded as the if's)");
    try r.has("BRDA:16,5:br:0/1,0,2", "String strictness: 16,5 (a flags test computed at 5:10, tested at the if) is not a decision");
    try r.has("BRDA:14,5:br:0/1,0,1", "user mask: 14,5 is not a decision");
    try r.has("BRDA:27,28:br:1/2,1,6", "loop head: 27,28 does not hold the raising call and the iteration");
    try r.has("BRDA:36,17:rhs:0/1,0,2", "reload: 36,17's right operand is not 2 true");
    try r.has("BRDA:38,16:rhs:0/1,1,3", "dominated constant: 38,16's right operand is not 3 false");
    try r.has("BRDA:40,39:rhs:0/1,0,1", "nested and: 40,39's right operand is not 1 true (derived through the not)");
    try r.has("BRDA:44,5:br:0/2,0,3", "folded copies: 44,5:br:0/2 is not 2+1 true");
    try r.has("BRDA:72,12:rhs:0/1,0,1", "error flag beside the result: 72,12's right operand is not 4-3 true");
    try r.has("BRDA:74,12:rhs:0/1,1,3", "and-shaped error flag: 74,12's right operand is not 4-1 false (derived from the call's error check)");
    try r.has("BRDA:76,26:rhs:0/1,0,2", "reload before a destructor: 76,26's right operand is not 2 true");
}

// 11a. A String's shapes, read strictly. Kills: the `and` and `icmp` of the
// flags test allowed at two locations (a made-up `icmp ne` at the `!=` of
// `(w.c & M) != 0`, refused there; Mojo's own `!= 0` is an `icmp eq` and a
// `xor`, test 47's mask.mojo); any mask (bit 60); the last reference not
// inlined at the branch, or not the standard library's (--stdlib); the
// shape taken at a call of a measured nodebug function (still refused).
test "11a user mask at '!= ': refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    _ = try c.refused("user mask", "src/pkg/d.mojo:14:26: a br at '!= ' is neither", try rinsert(&c, "  %83 = icmp ne i64 %82, 0, !dbg !225", &.{"  br i1 %83, label %62, label %63, !dbg !225, !prof !288"}));
}

test "11a mask bit 60: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    _ = try c.refused("mask bit 60", "src/pkg/d.mojo:5:10: a br at '== ' is neither", try rvariant(&c, "  %34 = and i64 %33, 4611686018427387904", "  %34 = and i64 %33, 1152921504606846976"));
}

test "11a last reference inlined elsewhere: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    _ = try c.refused("last reference elsewhere", "src/pkg/d.mojo:6:11: a br at '+=' is neither", try rvariant(&c, "!217 = !DILocation(line: 492, column: 10, scope: !208, inlinedAt: !216)", "!217 = !DILocation(line: 492, column: 10, scope: !208, inlinedAt: !210)"));
}

test "11a last reference outside --stdlib: refused" {
    var c = try h.Case.init("last reference outside --stdlib");
    defer c.deinit();
    try c.write("v.ll", h.rules_ll);
    const r = try c.exec(&(h.IO ++ h.MAP ++ [_][]const u8{ "--stdlib", "oss/other/", "--exclude", "oss/modular/", "--exclude", "buck-out/", "--exclude-file", "tests/test_a.mojo" }));
    try r.exits(1);
    try r.says("src/pkg/d.mojo:6:11: a br at '+=' is neither");
    try r.nothing_written();
}

test "11a a String's shape at a call of a nodebug function: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    _ = try c.refused("String at a nodebug call", "src/pkg/d.mojo:9:32: a br at 'gn[Int](' may be a decision of gn, which src/pkg/d.mojo:50 declares", try rinsert(&c, "  %35 = icmp ne i64 %34, 0, !dbg !213", &.{"  br i1 %35, label %36, label %41, !dbg !229, !prof !283"}));
}

// 11b. A subscript's `[` and a call's select take only a raising call's
// error flag; `name[...](` is a call of `name`. Kills: a `[` taking any br;
// a call taking any select; `%=` taken as `//=` is. (The nodebug check
// keyed on the text before `(`, `]`, is killed by 11a's last case.)
test "11b a br at '[' not on a raising call's flag: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    _ = try c.refused("subscript, not raising", "src/pkg/d.mojo:8:14: a br at '[' that is not on a raising call's error flag", try rinsert(&c, "  %61 = extractvalue { i1, ptr } %60, 0, !dbg !219", &.{ "  %900 = icmp slt i64 %43, 0, !dbg !219", "  br i1 %900, label %62, label %63, !dbg !219, !prof !285" }));
}

test "11b a select at a call not on a raising call's flag: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    _ = try c.refused("call select, not raising", "src/pkg/d.mojo:10:14: a select at 'h(' that is not on a raising call's error flag", try rinsert(&c, "  %72 = select i1 %71, i64 1, i64 2, !dbg !221, !prof !283", &.{ "  %901 = icmp slt i64 %43, 0, !dbg !221", "  %902 = select i1 %901, i64 1, i64 2, !dbg !221, !prof !283" }));
}

test "11b a select at '%=': refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    _ = try c.refused("%=", "src/pkg/d.mojo:13:7: a select at '%=' is neither", try rvariant(&c, "!222 = !DILocation(line: 12, column: 7,", "!222 = !DILocation(line: 13, column: 7,"));
}

// 11c. An iterable with no head (a subscript) is no loop decision. Kills: a
// head computed for any iterable.
test "11c an iterable with no head: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    _ = try c.refused("no head", "src/pkg/d.mojo:31:14: a br at 'xs' is neither", try rinsert(&c, "  %22 = icmp eq i8 %21, 0, !dbg !234", &.{"  br i1 %22, label %23, label %23, !dbg !237, !prof !290"}));
}

// 11d. A reload of another pointer than the left operand's, or one in a
// block doing more, is not the deciding value; a constant arriving through
// a block both targets reach is not under the deciding target. Kills: any
// non-constant from the deciding block taken; "reachable from" taken for
// "dominated by".
test "11d a reload of another pointer: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    _ = try c.refused("reload, other pointer", "src/pkg/d.mojo:36:17: IR line 157: the phi at this 'and' is not that of a short-circuit one", try rvariant(&c, "  %10 = load i1, ptr %5, align 1, !dbg !242", "  %10 = load i1, ptr %3, align 1, !dbg !242"));
}

test "11d a reload with a store before it: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    _ = try c.refused("reload, a store before it", "src/pkg/d.mojo:36:17: IR line 158: the phi at this 'and' is not that of a short-circuit one", try rinsert(&c, "9:                                                ; preds = %4", &.{"  store i1 false, ptr %5, align 1, !dbg !242"}));
}

test "11d a reload with a store after the left operand: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    _ = try c.refused("reload, a store after the left operand", "src/pkg/d.mojo:76:26: IR line 344: the phi at this 'and' is not that of a short-circuit one", try rinsert(&c, "  %57 = load i1, ptr %56, align 1, !dbg !328", &.{"  store i1 false, ptr %56, align 1, !dbg !328"}));
}

test "11d a constant under both targets: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    // sed 's/^31:  *; preds = %28, %29$/31:<spaces>; preds = %28, %29, %21/'
    var e = try h.Ir.of(c.a(), h.rules_ll);
    var n: usize = 0;
    for (e.lines.items) |*l| {
        if (!std.mem.startsWith(u8, l.*, "31: ") or !std.mem.endsWith(u8, l.*, "; preds = %28, %29")) continue;
        const mid = l.*[3 .. l.len - "; preds = %28, %29".len];
        if (std.mem.trim(u8, mid, " ").len != 0) continue;
        l.* = "31:                                                ; preds = %28, %29, %21";
        n += 1;
    }
    try std.testing.expect(n > 0);
    _ = try c.refused("constant under both", "src/pkg/d.mojo:38:16: a short-circuit 'and' (a br) whose result is not a phi at its location: its right operand cannot be counted (IR line 184: the phi at this 'and' does not join", try e.text());
}

// 11f. A call `name[...](` over lines is a call of `name` (a nodebug one
// refused); a select at a call on a value a br at the call tests is that
// br's only with the same weights; a String's flags carried in phis needs a
// leaf that is a String's (a field-2 load, or a static String's flags).
// Kills: the nodebug check missing a call over lines, or naming the callee
// from a bracket in a string literal or a comment; a select taken on any
// value some br tests; phis of constants taken as a String's.
const over_lines_at = "  br i1 %14, label %15, label %15, !dbg !314, !prof !285";
const over_lines_add = "  br i1 %14, label %15, label %15, !dbg !315, !prof !285";

test "11f a nodebug call over lines: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    _ = try c.refused("nodebug call over lines", "src/pkg/d.mojo:68:6: a br at 'gn[' may be a decision of gn", try rinsert(&c, over_lines_at, &.{over_lines_add}));
}

/// d.mojo with its line `n` (1-based) `old` replaced by `new`.
fn dLine(c: *h.Case, edits: []const [3][]const u8) ![]const u8 {
    var e = try h.Ir.of(c.a(), h.d_src);
    for (edits) |ed| {
        const n = try std.fmt.parseInt(usize, ed[0], 10);
        try std.testing.expectEqualStrings(ed[1], e.lines.items[n - 1]);
        e.lines.items[n - 1] = ed[2];
    }
    return e.text();
}

// The same call with a string literal holding a `[`, or a comment holding a
// `]`, in its parameters is still a call of gn. Kills: brackets in string
// literals (the name would be `a`, no nodebug function) or comments counted
// when the name before `[` is looked for.
test "11f a bracket in a string literal or a comment: still a call of gn" {
    for ([_][]const u8{ "        Int, \"a[b\",", "        Int,  # a]" }) |line67| {
        var c = try h.Case.init("");
        defer c.deinit();
        try c.source("d", try dLine(&c, &.{.{ "67", "        Int,", line67 }}));
        _ = try c.refused(line67, "src/pkg/d.mojo:68:6: a br at 'gn[' may be a decision of gn", try rinsert(&c, over_lines_at, &.{over_lines_add}));
    }
}

// A triple-quoted string running over lines in its parameters refuses the
// branch: read line by line, `gn["""` then `x[""", Int,` names the call `x`
// (no nodebug function), and the br would be taken as a call's. Kills: the
// refusal dropped (a `"""` or `'''` read as one-line literals).
test "11f a triple-quoted string over lines: refused" {
    for ([_][]const u8{ "\"\"\"", "'''" }) |q| {
        var c = try h.Case.init("");
        defer c.deinit();
        const l66 = try std.mem.concat(c.a(), u8, &.{ "    v += gn[", q });
        const l67 = try std.mem.concat(c.a(), u8, &.{ "        x[", q, ", Int," });
        try c.source("d", try dLine(&c, &.{ .{ "66", "    v += gn[", l66 }, .{ "67", "        Int,", l67 } }));
        _ = try c.refused(q, "src/pkg/d.mojo:68:6: a br at '(v)': the name of the call whose parameters close here is not read: line 67 holds a triple-quoted string's quotes", try rinsert(&c, over_lines_at, &.{over_lines_add}));
    }
}

test "11f a select with other weights than the br: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    _ = try c.refused("select, other weights than the br", "src/pkg/d.mojo:69:17: a select at 'overflows(' that is not on a raising call's error flag", try rvariant(&c, "  %21 = select i1 %19, i1 true, i1 %20, !dbg !316, !prof !292", "  %21 = select i1 %19, i1 true, i1 %20, !dbg !316, !prof !293"));
}

test "11f flags in phis with no String leaf: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    _ = try c.refused("flags phis, no String leaf", "src/pkg/d.mojo:71:28: a select at 'read(' that is not on a raising call's error flag", try rvariant(&c, "  %30 = phi i64 [ %28, %27 ], [ 2305843009213693952, %26 ]", "  %30 = phi i64 [ %28, %27 ], [ 5, %26 ]"));
}

// 11e. Copies of a function whose n-th conditions are computed in one
// header are summed (44,5, case 11); one computed on the `elif` line is not
// in the `if`'s header. Kills: the header check dropped (any two positions
// taken).
test "11e copies, a condition on the elif line: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.rules_ll);
    try e.subStart("  br i1 %3, label %4, label %5, !dbg !266, !prof !273", "  br i1 %6, label %4, label %5, !dbg !266, !prof !273");
    try e.subStart("  br i1 %6, label %4, label %4, !dbg !266, !prof !274", "  br i1 %3, label %4, label %4, !dbg !266, !prof !274");
    _ = try c.refused("copies, elif line", "src/pkg/d.mojo:44:5 (br): two copies of its function hold different branches here", try e.text());
}
