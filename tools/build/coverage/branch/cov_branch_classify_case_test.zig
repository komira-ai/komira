//! cov_branch_classify's cases on fixtures/case.ll (README.md#tests), the
//! numbers those of the shell cases they replace (1 to 9c): the golden
//! output, the metadata order, a second test's counts, unknown tokens, file
//! names, --gen, zero branches, another [src], and malformed or inconsistent
//! IR. Each runs the shipped executable (cov_branch_classify_harness.zig)
//! and says the defect (mutant) it kills.

const std = @import("std");
const h = @import("cov_branch_classify_harness.zig");
const SRC = h.SRC;

/// case.ll edited by `sub` (sed 's/old/new/').
fn variant(c: *h.Case, old: []const u8, new: []const u8) ![]const u8 {
    var e = try h.Ir.of(c.a(), h.case_ll);
    try e.sub(old, new);
    return e.text();
}

/// case.ll with the line starting `prefix` replaced by `line`.
fn variantLine(c: *h.Case, prefix: []const u8, line: []const u8) ![]const u8 {
    var e = try h.Ir.of(c.a(), h.case_ll);
    try e.subLine(prefix, line);
    return e.text();
}

const golden_summary = "3 measured file(s): 23 source decision(s) (if 13, elif 1, while 2, and 2, or 3, for-in 2, try 0; 5 right operand(s) derived, 0 and/or result(s) no test reads, 2 a second test of one decision), 5 compiler-made (String lifetime 0, + 1, call( 2, [ 0, // 1, % 1) not written; 6 branch(es) outside the measured sources";

// 1. The golden output, byte for byte. Kills: an instance not summed (3,5 is
// 2,10 + 1,1 of the other generic instance + 0,1 of a copy inlined into the
// test: 3,12, one record per arm); a never-ran count written as 0 (9,5 never
// ran in either instance: `-`); arms swapped (5,5 is 1,9: true first, as the
// weights are); a compiler-made branch written (no record on lines 4, 17, 18,
// 19: `+`, `String(`, `//`, `%`, `check(`); an inlined branch put on its call
// site (11,19 is 5,1, not 5,1 + the 9,9 of range.mojo inlined there); the
// [src] hash left in the path (SF:src/pkg/...); the right operands of `or`
// (13,14:rhs = 3-1, 2) and `and` (15,14:rhs = 3, 4-3) as selects, of a
// short-circuit `or` and `and` (a br at the token, a phi, a branch on it:
// c.mojo 3,17:rhs = 3-1, 3; 7,14:rhs = 3, 4-3) and of an `or` under `not`
// (11,15:rhs through `xor ..., true`: the branch's arms swapped, 5-3, 2);
// two distinct branches of one function at one location (b.mojo 3,5:br:0/2 =
// 1,4 and 1/2 = 1,3, as Mojo gives an `elif` its `if`'s location) summed
// into one; one decision tested twice (a.mojo 11,19's two branches on one
// value with one weights node, as a `range(` loop has; c.mojo 3,5's select
// and branch on the phi) written twice; a switch's three arms; files and
// records sorted. Not in the output: the test, the standard library, the
// dependency, the generated source, `<unknown>`. c.mojo declares `quick`
// @always_inline("nodebug") and no branch is at a call of it: not refused.
// 1b. The mutants of case 1, each named (the golden diff alone would not
// say which).
test "1 golden: case.ll gives case.golden.info byte for byte, exit 0, the summary on stderr" {
    var c = try h.Case.init("golden");
    defer c.deinit();
    const r = try c.run(h.case_ll);
    try r.exits(0);
    try r.golden(h.case_golden, "the output differs from fixtures/case.golden.info");
    try r.says(golden_summary);
    try r.has("BRDA:9,5:br:0/1,0,-", "never ran: 9,5 arm 0 is not '-' (NONE written as a count)");
    try r.has("BRDA:3,5:br:0/1,1,12", "instances: 3,5 arm 1 is not 10+1+1 (instances or inlined copies not summed)");
    try r.counts("BRDA:3,5:br:0/1,1,", 2, "instances: 3,5 arm 1 is not written once in a.mojo and once in c.mojo");
    try r.has("BRDA:3,5:br:1/2,1,3", "one location, two branches: b.mojo's second branch at 3,5 is not its own record");
    try r.has("BRDA:3,17:rhs:0/1,0,2", "short-circuit or: c.mojo 3,17's right operand is not 3-1 true");
    try r.has("BRDA:7,14:rhs:0/1,1,1", "short-circuit and: c.mojo 7,14's right operand is not 4-3 false");
    try r.has("BRDA:11,15:rhs:0/1,0,2", "not (a or b): c.mojo 11,15's right operand is not 5-3 true (the xor's arms not swapped)");
    try r.counts("BRDA:11,19:", 2, "one decision tested twice: 11,19 (two branches on one value and weights) is not one record of two arms");
    try r.lacks("BRDA:3,5:select:", "one decision tested twice: c.mojo 3,5's select on the value its branch tests was written");
    for ([_][]const u8{ "BRDA:4,", "BRDA:17,", "BRDA:18,", "BRDA:19," }) |p| try r.lacks(p, "compiler-made: a branch on line 4, 17, 18 or 19 was written");
    try r.lacksText("0123456789abcdef", "path: the [src] hash is in the output");
}

// 2. The order of the metadata does not matter: the same IR with its
// metadata lines reversed gives the same bytes. Kills: a node resolved only
// when it was read before its user.
test "2 reversed metadata: the same bytes as the golden" {
    var c = try h.Case.init("reversed metadata");
    defer c.deinit();
    const ir = try h.Ir.of(c.a(), h.case_ll);
    var code = std.ArrayList([]const u8).init(c.a());
    var meta = std.ArrayList([]const u8).init(c.a());
    for (ir.lines.items) |l| {
        if (l.len >= 2 and l[0] == '!' and std.ascii.isDigit(l[1])) try meta.append(l) else try code.append(l);
    }
    std.mem.reverse([]const u8, meta.items);
    var rev = h.Ir{ .al = c.a(), .lines = code };
    try rev.append(meta.items);
    const v = try rev.text();
    try std.testing.expect(!std.mem.eql(u8, v, h.case_ll));
    const r = try c.run(v);
    try r.exits(0);
    try r.golden(h.case_golden, "reversed metadata: other bytes than the golden");
}

/// Each line of `info` cut to its first three comma fields (cut -d, -f1-3).
fn ids(al: std.mem.Allocator, info: []const u8) ![]const u8 {
    var b = std.ArrayList(u8).init(al);
    var it = std.mem.splitScalar(u8, info, '\n');
    while (it.next()) |l| {
        var n: usize = 0;
        var end = l.len;
        for (l, 0..) |ch, i| {
            if (ch == ',') {
                n += 1;
                if (n == 3) {
                    end = i;
                    break;
                }
            }
        }
        try b.appendSlice(l[0..end]);
        try b.append('\n');
    }
    return b.items;
}

// 3. Another test's run of the same code (other counts) gives the same
// records but for the counts: the id `<line>,<col>:<kind>:<n>/<N>,<arm>` is
// what covcheck sums by across tests. Kills: an id holding a count, an order
// or an IR line number.
test "3 second test: other counts, the same ids" {
    var c = try h.Case.init("second test");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.case_ll);
    try e.subLine("!60 = ", "!60 = !{!\"branch_weights\", i32 0, i32 4}");
    try e.subLine("!64 = ", "!64 = !{!\"branch_weights\", i32 2, i32 3}");
    const r = try c.run(try e.text());
    try r.exits(0);
    try std.testing.expectEqualStrings(try ids(c.a(), h.case_golden), try ids(c.a(), try r.output()));
    try r.has("BRDA:3,5:br:0/1,1,6", "second test: 3,5 arm 1 is not 4+1+1");
    try r.has("BRDA:13,14:rhs:0/1,0,1", "second test: 13,14:rhs arm 0 is not 3-2");
}

// 4. Tokens that are neither a source decision nor a known compiler-made
// branch fail the action, naming file:line:col and the token. Kills: an
// allowlist that accepts an unknown token (a fall-through to "decision" or
// to "compiler-made").
test "4 unknown token: '+='" {
    var c = try h.Case.init("");
    defer c.deinit();
    _ = try c.refused("+=", "src/pkg/a.mojo:10:11: a br at '+=' is neither a source decision nor a known compiler-made branch: i += 1", try variant(&c, "!25 = !DILocation(line: 9, column: 5,", "!25 = !DILocation(line: 10, column: 11,"));
}

test "4 unknown token: a word" {
    var c = try h.Case.init("");
    defer c.deinit();
    _ = try c.refused("a word", "src/pkg/a.mojo:6:9: a br at 'return' is neither", try variant(&c, "!23 = !DILocation(line: 5, column: 5,", "!23 = !DILocation(line: 6, column: 9,"));
}

test "4 unknown token: for, off the head" {
    var c = try h.Case.init("");
    defer c.deinit();
    _ = try c.refused("for, off the head", "src/pkg/a.mojo:20:31: a br at 'sep(' is neither", try variant(&c, "!26 = !DILocation(line: 11, column: 19,", "!26 = !DILocation(line: 20, column: 31,"));
}

test "4 unknown token: one slash" {
    var c = try h.Case.init("");
    defer c.deinit();
    _ = try c.refused("one slash", "src/pkg/a.mojo:17:19: a select at '/ 2' is neither", try variant(&c, "!31 = !DILocation(line: 17, column: 18,", "!31 = !DILocation(line: 17, column: 19,"));
}

test "4 unknown token: column outside the line" {
    var c = try h.Case.init("");
    defer c.deinit();
    _ = try c.refused("column outside", "src/pkg/a.mojo:3:99: a br at '<column outside the line>'", try variant(&c, "!20 = !DILocation(line: 3, column: 5,", "!20 = !DILocation(line: 3, column: 99,"));
}

test "4 unknown token: inside a word" {
    var c = try h.Case.init("");
    defer c.deinit();
    _ = try c.refused("inside a word", "src/pkg/a.mojo:3:6: a br at 'f' is neither", try variant(&c, "!20 = !DILocation(line: 3, column: 5,", "!20 = !DILocation(line: 3, column: 6,"));
}

// Every unclassified branch is named, not only the first.
test "4 two unknown tokens: both named" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.case_ll);
    try e.sub("!23 = !DILocation(line: 5, column: 5,", "!23 = !DILocation(line: 6, column: 9,");
    try e.sub("!25 = !DILocation(line: 9, column: 5,", "!25 = !DILocation(line: 10, column: 11,");
    const r = try c.refused("two unknown", "src/pkg/a.mojo:6:9: a br at 'return'", try e.text());
    try r.says("src/pkg/a.mojo:10:11: a br at '+='");
}

// 5. File names: without `--exclude buck-out/` the dependency's source is
// unmapped and refused (so case 1 dropped it by the exclusion, not by
// accident); without the test's --exclude-file, the test is.
test "5 unmapped dependency: refused without --exclude buck-out/" {
    var c = try h.Case.init("unmapped dependency");
    defer c.deinit();
    try c.write("v.ll", h.case_ll);
    const r = try c.exec(&(h.IO ++ h.MAP ++ h.STD ++ [_][]const u8{ "--exclude", "oss/modular/", "--exclude-file", "tests/test_a.mojo", "--exclude-file", "<unknown>", "--gen", "gen.mojo" }));
    try r.exits(1);
    try r.says("unmapped file name 'buck-out/v2/art/cell/src/dep/__dep__/fedcba9876543210/src/dep/d.mojo'");
    try r.nothing_written();
}

test "5 unmapped test: refused without its --exclude-file" {
    var c = try h.Case.init("unmapped test");
    defer c.deinit();
    try c.write("v.ll", h.case_ll);
    const r = try c.exec(&(h.IO ++ h.MAP ++ h.STD ++ [_][]const u8{ "--exclude", "oss/modular/", "--exclude", "buck-out/", "--exclude-file", "<unknown>", "--gen", "gen.mojo" }));
    try r.exits(1);
    try r.says("unmapped file name 'tests/test_a.mojo'");
    try r.nothing_written();
}

// 6. Without --gen, the generated source is measured: case 1's drop is the
// --gen's doing (the map is checked before the exclusions, so a [src] under
// buck-out/ is measured).
test "6 no --gen: the generated source is measured" {
    var c = try h.Case.init("no --gen");
    defer c.deinit();
    try c.write("v.ll", h.case_ll);
    const r = try c.exec(&(h.IO ++ h.MAP ++ h.STD ++ [_][]const u8{ "--exclude", "oss/modular/", "--exclude", "buck-out/", "--exclude-file", "tests/test_a.mojo", "--exclude-file", "<unknown>" }));
    try r.exits(0);
    try r.has("SF:src/pkg/gen.mojo", "no --gen: the generated source is not in the output");
    try r.has("BRDA:3,5:br:0/1,0,9", "no --gen: its branch is not written");
}

// 7. Zero branches parsed in a measured file whose IR has code on an `if`
// line is refused (the branches were not read); b.mojo, whose only code
// left is on `return 3`, is not. Kills: a parser that silently reads no
// branch.
test "7 zero branches: refused for a.mojo, not for b.mojo" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.case_ll);
    try e.drop(" br i1 ", .contains);
    try e.drop(" = select i1 ", .contains);
    try e.drop("  switch ", .prefix);
    try e.drop("  ], ", .prefix);
    try e.drop("    i64 0, label ", .prefix);
    try e.drop("    i64 1, label ", .prefix);
    var kept = std.ArrayList([]const u8).init(c.a());
    for (e.lines.items) |l| if (!std.mem.endsWith(u8, l, "!dbg !50")) try kept.append(l);
    e.lines = kept;
    const r = try c.refused("zero branches", "src/pkg/a.mojo: zero branches parsed, yet the IR has code on its decision line 3", try e.text());
    try r.silent("src/pkg/b.mojo");
}

// 8. The library's [src] under another content hash in the IR than --map's
// is refused, naming the file, although `--exclude buck-out/` covers it.
// Kills: a [src] the IR was not compiled from (a hash that does not match)
// falling through to the exclusion unseen, leaving nothing measured. The
// dependency (another library under buck-out/, case 5) is not refused.
test "8 other hash: the library's [src] under another hash is refused" {
    var c = try h.Case.init("other hash");
    defer c.deinit();
    const other = "buck-out/v2/art/cell/src/pkg/__pkg__/ffffffffffffffff/src/pkg";
    try c.mkdir(other);
    try c.write("v.ll", h.case_ll);
    const r = try c.exec(&(h.IO ++ [_][]const u8{ "--map", other ++ "/=src/pkg/" } ++ h.EXC));
    try r.exits(1);
    try r.says("'" ++ SRC ++ "/a.mojo' is the library's source under another [src] than --map's ('" ++ other ++ "/')");
    try r.silent("dep/d.mojo");
    try r.nothing_written();
}

// 8b. So is the library's [src] under another target or configuration
// directory (`/<hash>/src/pkg/` in another place), which `--exclude
// buck-out/` would drop unseen. Kills: a check of the hash segment alone.
test "8b other [src]: the library's sources under another directory are refused" {
    var c = try h.Case.init("");
    defer c.deinit();
    _ = try c.refused("other [src]", "'buck-out/v2/art/cfg/other/__pkg2__/fedcba9876543210/src/pkg/d.mojo' is the library's source under another [src]", try variant(&c, "!6 = !DIFile(filename: \"buck-out/v2/art/cell/src/dep/__dep__/fedcba9876543210/src/dep/d.mojo\"", "!6 = !DIFile(filename: \"buck-out/v2/art/cfg/other/__pkg2__/fedcba9876543210/src/pkg/d.mojo\""));
}

// 8c. A --map PREFIX with no `/<16 hex>/` segment is refused: with no hash
// to look for, a library source under another [src] (8, 8b) could not be
// told and `--exclude buck-out/` would drop it unseen. Kills: the check of
// 8 skipped silently when the prefix has no hash.
test "8c no hash: a --map PREFIX with no hash segment is bad usage" {
    var c = try h.Case.init("no hash");
    defer c.deinit();
    for ([_][]const u8{ "a", "b", "c", "d", "gen", "t" }) |n| {
        const p = try std.fmt.allocPrint(c.a(), "{s}/{s}.mojo", .{ SRC, n });
        try c.write(try std.fmt.allocPrint(c.a(), "srcroot/pkg/{s}.mojo", .{n}), try c.read(p));
    }
    try c.write("v.ll", h.case_ll);
    const r = try c.exec(&(h.IO ++ [_][]const u8{ "--map", "srcroot/pkg/=src/pkg/" } ++ h.EXC));
    try r.exits(2);
    try r.says("the --map PREFIX 'srcroot/pkg/' holds no '/<16 hex>/' segment");
    try r.nothing_written();
}

// 9. Malformed or inconsistent IR is refused.
test "9 no header" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.case_ll);
    _ = e.lines.orderedRemove(0);
    _ = try c.refused("no header", "does not start with '; *** IR Dump After PGOInstrumentationUse on [module] ***'", try e.text());
}

test "9 three weights for two arms" {
    var c = try h.Case.init("");
    defer c.deinit();
    _ = try c.refused("arms", "src/pkg/a.mojo:5:5: 3 branch weights for 2 arms", try variantLine(&c, "!61 = ", "!61 = !{!\"branch_weights\", i32 1, i32 9, i32 2}"));
}

test "9 !prof not branch weights of counts" {
    var c = try h.Case.init("");
    defer c.deinit();
    _ = try c.refused("expected", "src/pkg/a.mojo:5:5: !prof is not branch weights of counts", try variantLine(&c, "!61 = ", "!61 = !{!\"branch_weights\", !\"expected\", i32 1, i32 9}"));
}

test "9 a br with no !dbg" {
    var c = try h.Case.init("");
    defer c.deinit();
    _ = try c.refused("no dbg", "a br with no !dbg location", try variant(&c, ", !dbg !23, !prof !61", ", !prof !61"));
}

test "9 a scope with no file" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.case_ll);
    try e.subExact("!50 = !DILocation(line: 3, column: 5, scope: !12)", "!50 = !DILocation(line: 3, column: 5, scope: !9)");
    _ = try c.refused("scope with no file", "of a switch is not a DILocation whose scope names a DIFile", try e.text());
}

// Two instances of one switch with 3 and 2 arms.
test "9 arms of two instances" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.case_ll);
    try e.insertBefore("attributes #0", &.{ "define internal i64 @\"pkg::b::f2\"(i64 %0) #0 !dbg !12 {", "1:", "  switch i64 %0, label %4 [", "    i64 0, label %2", "  ], !dbg !50", "}", "" });
    _ = try c.refused("arms of two instances", "src/pkg/b.mojo:3:5: two instances of one switch have 3 and 2 arms", try e.text());
}

// 9b. A copy of a function holding another number of branches of a kind at
// a location than another copy is refused: its n-th is not theirs. Kills:
// ordinals summed across copies that do not match (a branch one generic
// instance folded away shifting the others'). The second branch has other
// weights: with the same, it would be one decision tested twice.
test "9b copies differ in number" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.case_ll);
    var i: usize = 0;
    var n: usize = 0;
    while (i < e.lines.items.len) : (i += 1) {
        const l = e.lines.items[i];
        if (!std.mem.endsWith(u8, l, ", !dbg !40, !prof !70")) continue;
        try e.lines.insert(i + 1, try std.mem.concat(c.a(), u8, &.{ l[0 .. l.len - "!prof !70".len], "!prof !72" }));
        i += 1;
        n += 1;
    }
    try std.testing.expect(n > 0);
    _ = try c.refused("copies differ", "src/pkg/a.mojo:3:5 (br): one copy of its function has 1 branch(es) of this kind here and another 2", try e.text());
}

// So is one holding as many whose conditions are computed elsewhere (each
// instance folded away another of its branches there). Kills: copies
// matched by their number alone.
test "9b copies' conditions computed elsewhere" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.case_ll);
    try e.subExact("  %3 = icmp slt i64 %0, 0, !dbg !40", "  %3 = icmp slt i64 %0, 0, !dbg !41");
    _ = try c.refused("copies' conditions", "src/pkg/a.mojo:3:5 (br): two copies of its function hold different branches here: the condition of the one numbered 0 is computed at", try e.text());
}

// 9c. An and/or whose result cannot be read is refused, naming it. Kills:
// an and/or taken on its token alone (a branch no and/or shape shows).
test "9c a select at 'or' of another form" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.case_ll);
    try e.subStart("  %3 = select i1 %0, i1 true, i1 %1, !dbg !122", "  %3 = select i1 %0, i1 %1, i1 true, !dbg !122");
    const r = try c.refused("or select form", "src/pkg/c.mojo:11:15: IR line", try e.text());
    try r.says("the select at this 'or' is not that of one");
}

// A short-circuit `or` whose phi is missing, or is not an `or`'s.
test "9c a short-circuit 'or' with no phi" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.case_ll);
    try e.drop("%8 = phi i1 [ %6, %5 ], [ true, %4 ], !dbg !111", .contains);
    _ = try c.refused("or no phi", "src/pkg/c.mojo:3:17: a short-circuit 'or' (a br) whose result is not a phi at its location", try e.text());
}

test "9c a short-circuit 'or' whose phi is of another form" {
    var c = try h.Case.init("");
    defer c.deinit();
    const r = try c.refused("or phi form", "src/pkg/c.mojo:3:17: IR line", try variant(&c, "%8 = phi i1 [ %6, %5 ], [ true, %4 ]", "%8 = phi i1 [ %6, %5 ], [ false, %4 ]"));
    try r.says("the phi at this 'or' is not that of a short-circuit one");
}

// A short-circuit whose deciding constant arrives from the branch's other
// target: the phi has the and/or shape, but the constant is the result when
// the left operand is the other value (`not a or b` under an `or` token), so
// the derived right operand would be wrong. Refused, not derived. Kills: a
// phi read by its shape alone, the targets of its branch not compared.
test "9c an 'or' whose constant arrives from the false target" {
    var c = try h.Case.init("");
    defer c.deinit();
    _ = try c.refused("or constant from the false target", "src/pkg/c.mojo:3:17: IR line 122: the 'true' of the phi at this 'or' arrives from %4, the branch's false target, not its true target (%5)", try variant(&c, "br i1 %3, label %4, label %5, !dbg !111", "br i1 %3, label %5, label %4, !dbg !111"));
}

test "9c an 'and' whose constant arrives from the true target" {
    var c = try h.Case.init("");
    defer c.deinit();
    _ = try c.refused("and constant from the true target", "src/pkg/c.mojo:7:14: IR line 146: the 'false' of the phi at this 'and' arrives from %6, the branch's true target, not its false target (%4)", try variant(&c, "br i1 %3, label %4, label %6, !dbg !117", "br i1 %3, label %6, label %4, !dbg !117"));
}

// The constant arriving straight from the branch's own block (the phi in
// the deciding target, with no forwarding block between) is a correct
// shape the classifier does not read (no such IR has been seen): the phi
// does not join one value under each target (the branch's own block is
// under neither), so it is not taken as the or's, and the or is refused,
// not guessed.
test "9c an 'or' whose constant arrives straight from the branch's block" {
    var c = try h.Case.init("");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.case_ll);
    const f = try e.function("@\"pkg::c::spend\"");
    var kept = std.ArrayList([]const u8).init(c.a());
    var skip: usize = 0;
    for (e.lines.items, 0..) |l, i| {
        const in = i > f[0] and i < f[1];
        if (in and std.mem.startsWith(u8, l, "  br i1 %3, label %4, label %5, !dbg !111")) {
            try kept.append("  br i1 %3, label %7, label %5, !dbg !111, !prof !130");
            continue;
        }
        if (in and std.mem.startsWith(u8, l, "4:  ")) skip = 3;
        if (skip > 0) {
            skip -= 1;
            continue;
        }
        try kept.append(l);
    }
    e.lines = kept;
    const g = try e.function("@\"pkg::c::spend\"");
    _ = try e.subIn(g[0], g[1], "[ true, %4 ]", "[ true, %2 ]");
    for (e.lines.items[g[0]..g[1]]) |*l| {
        if (std.mem.endsWith(u8, l.*, "preds = %4, %5")) l.* = try std.mem.concat(c.a(), u8, &.{ l.*[0 .. l.len - "preds = %4, %5".len], "preds = %2, %5" });
    }
    const v = try e.text();
    try std.testing.expect(std.mem.indexOf(u8, v, "%8 = phi i1 [ %6, %5 ], [ true, %2 ]") != null);
    _ = try c.refused("or straight edge", "src/pkg/c.mojo:3:17: a short-circuit 'or' (a br) whose result is not a phi at its location: its right operand cannot be counted (IR line 119: the phi at this 'or' does not join one value arriving under the branch's true target %7 and one under its false target %5", v);
}
