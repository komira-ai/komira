//! cov_branch_classify's cases on fixtures/case.ll that add a function or a
//! source file (README.md#tests), the numbers those of the shell cases they
//! replace (9d to 9i): `@always_inline("nodebug")` callees and operators, an
//! instruction kind a token has not shown, an invoke, the zero-branch check
//! at an and/or line, a measured file with no decision, and one file under
//! two debug-info spellings. Each runs the shipped executable
//! (cov_branch_classify_harness.zig) and says the defect (mutant) it kills.

const std = @import("std");
const h = @import("cov_branch_classify_harness.zig");
const SRC = h.SRC;

// 9d. A branch at the call of a function a measured source declares
// @always_inline("nodebug") is refused (it may be that function's own
// decision, given the call's location); a nodebug operator, constructor or
// destructor refuses the run. Kills: the call class taken for any callee.
test "9d a br at a call of a nodebug function: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.case_ll);
    try e.insertAfter("  %4 = xor i1 %3, true, !dbg !123", &.{"  br i1 %4, label %5, label %6, !dbg !128, !prof !135"});
    _ = try c.refused("nodebug call", "src/pkg/c.mojo:12:21: a br at 'quick(' may be a decision of quick, which src/pkg/c.mojo:16 declares @always_inline(\"nodebug\")", try e.text());
}

test "9d a nodebug dunder: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    try c.source("n", "# made up\nstruct S:\n    @always_inline(\"nodebug\")\n    def __add__(self, o: S) -> S:\n        return o\n");
    _ = try c.refused("nodebug dunder", "src/pkg/n.mojo:4: __add__ is declared @always_inline(\"nodebug\")", h.case_ll);
}

// 9e. A compiler-made token with an instruction kind it has not shown is
// refused. Kills: a class accepting any kind (a select at `+`).
test "9e a select at '+': refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.case_ll);
    try e.sub("!31 = !DILocation(line: 17, column: 18,", "!31 = !DILocation(line: 4, column: 42,");
    _ = try c.refused("kind", "src/pkg/a.mojo:4:42: a select at '+': no select has been seen at this token", try e.text());
}

// 9f. Branch forms the classifier does not read, in a measured file, are
// refused. Kills: an invoke (or indirectbr, callbr) skipped unseen.
test "9f an invoke in a measured file: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.case_ll);
    try e.insertAfter("  %3 = icmp slt i64 %0, 0, !dbg !20", &.{"  invoke void @\"x\"() to label %4 unwind label %7, !dbg !20"});
    _ = try c.refused("invoke", "src/pkg/a.mojo:3:5: an invoke in a measured file", try e.text());
}

// 9g. A measured file with zero branches parsed and code on a line whose
// decision is an `and`, `or` or ternary `if` (not its first word) is
// refused. Kills: a zero-branch check that reads only the first word.
test "9g zero branches at an 'and' line: refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    try c.source("e", "# made up\ndef pick(a: Bool, b: Bool) -> Bool:\n    return a and b\n");
    var e = try h.Ir.of(c.a(), h.case_ll);
    try e.insertBefore("attributes #0", &.{ "define internal i1 @\"pkg::e::pick\"(i1 %0, i1 %1) #0 !dbg !141 {", "2:", "  %3 = and i1 %0, %1, !dbg !142", "  ret i1 %3, !dbg !142", "}", "" });
    try e.append(&.{
        "!140 = !DIFile(filename: \"" ++ SRC ++ "/e.mojo\", directory: \"\")",
        "!141 = distinct !DISubprogram(name: \"pick\", scope: !140, file: !140, line: 2, type: !9, unit: !0)",
        "!142 = !DILocation(line: 3, column: 5, scope: !141)",
    });
    _ = try c.refused("zero branches, and", "src/pkg/e.mojo: zero branches parsed, yet the IR has code on its decision line 3", try e.text());
}

// 9h. A measured file whose code the IR holds, with no decision in it, is
// named with no record (`SF:` then `end_of_record`) in its sorted place:
// bb.mojo between b.mojo's and c.mojo's records, e.mojo after the last. So
// covcheck counts its package's branches as measured, with none to take.
// Kills: a decision-free file left out (its package BranchNotMeasured in
// covcheck whatever its tests run), or written out of order.
test "9h a measured file with no decision: SF with no record, in its sorted place" {
    var c = try h.Case.init("no decision");
    defer c.deinit();
    try c.source("bb", "# made up\ndef one() -> Int:\n    return 1\n");
    try c.source("e", "# made up\ndef two() -> Int:\n    return 2\n");
    var e = try h.Ir.of(c.a(), h.case_ll);
    try e.insertBefore("attributes #0", &.{
        "define internal i64 @\"pkg::bb::one\"() #0 !dbg !141 {", "1:", "  ret i64 1, !dbg !142", "}", "",
        "define internal i64 @\"pkg::e::two\"() #0 !dbg !144 {",  "1:", "  ret i64 2, !dbg !145", "}", "",
    });
    try e.append(&.{
        "!140 = !DIFile(filename: \"" ++ SRC ++ "/bb.mojo\", directory: \"\")",
        "!141 = distinct !DISubprogram(name: \"one\", scope: !140, file: !140, line: 2, type: !9, unit: !0)",
        "!142 = !DILocation(line: 3, column: 5, scope: !141)",
        "!143 = !DIFile(filename: \"" ++ SRC ++ "/e.mojo\", directory: \"\")",
        "!144 = distinct !DISubprogram(name: \"two\", scope: !143, file: !143, line: 2, type: !9, unit: !0)",
        "!145 = !DILocation(line: 3, column: 5, scope: !144)",
    });
    const r = try c.run(try e.text());
    try r.exits(0);
    // The golden with bb.mojo after b.mojo's end_of_record and e.mojo last.
    var want = try h.Ir.of(c.a(), h.case_golden);
    var cur: []const u8 = "";
    var i: usize = 0;
    while (i < want.lines.items.len) : (i += 1) {
        const l = want.lines.items[i];
        if (std.mem.eql(u8, l, "end_of_record") and std.mem.eql(u8, cur, "SF:src/pkg/b.mojo")) {
            try want.lines.insertSlice(i + 1, &.{ "SF:src/pkg/bb.mojo", "end_of_record" });
            i += 2;
        }
        if (std.mem.startsWith(u8, l, "SF:")) cur = l;
    }
    try want.append(&.{ "SF:src/pkg/e.mojo", "end_of_record" });
    try r.golden(try want.text(), "no decision: bb.mojo and e.mojo are not each named with no record in their sorted place");
    try r.says("5 measured file(s)");
}

// 9i. Two debug-info spellings of one file (b.mojo as `filename` alone and
// as `directory` + `filename`, two DIFile nodes) are one measured file: one
// `SF:` in its sorted place, the golden output byte for byte, 3 measured
// files. A file is keyed by its joined name and --map's PREFIX is one
// string, so one repository path has one name. Kills: files keyed by the
// DIFile node (or any raw spelling), which names b.mojo twice and covcheck
// refuses the duplicate `SF:`.
test "9i two spellings of one file: one SF" {
    var c = try h.Case.init("two spellings");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.case_ll);
    try e.insertBefore("attributes #0", &.{ "define internal i64 @\"pkg::b::tail\"() #0 !dbg !151 {", "1:", "  ret i64 3, !dbg !152", "}", "" });
    try e.append(&.{
        "!150 = !DIFile(filename: \"b.mojo\", directory: \"" ++ SRC ++ "\")",
        "!151 = distinct !DISubprogram(name: \"tail\", scope: !150, file: !150, line: 2, type: !9, unit: !0)",
        "!152 = !DILocation(line: 7, column: 5, scope: !151)",
    });
    const r = try c.run(try e.text());
    try r.exits(0);
    try r.golden(h.case_golden, "two spellings: b.mojo under two DIFile spellings is not one SF (the output differs from the golden)");
    try r.counts("SF:src/pkg/b.mojo", 1, "two spellings: SF:src/pkg/b.mojo is not written once");
    try r.says("3 measured file(s)");
}
