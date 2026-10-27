//! Unit tests of census_render.zig: each refusal of census.tsv, the holds and the
//! `below` mark, the ranking, the doc's sections, and the validation result. The
//! doc byte for byte over a whole census is tests//negative/coverage:census_ok_doc
//! (its golden), and the red twins are the `census_*` fixtures there.
const std = @import("std");
const R = @import("census_render.zig");
const t = std.testing;

const head = "census\t2026-10-01\t-\tfirst census\n";

fn row(label: []const u8, kind: []const u8, status: []const u8, nums: []const u8, tail: []const u8) []const u8 {
    _ = label;
    _ = kind;
    _ = status;
    _ = nums;
    return tail;
}

fn heldOf(a: std.mem.Allocator, text: []const u8) !std.StringHashMap([]const u8) {
    return R.parseHeld(a, text);
}

fn refusal(a: std.mem.Allocator, text: []const u8, held: []const u8) ![]const u8 {
    var err: []const u8 = "";
    try t.expectError(error.Refused, R.parseCensus(a, "census.tsv", text, try heldOf(a, held), 9900, &err));
    return err;
}

const ok_a = "komira//src/a:a\tsrc/a\tlibrary\tOK\t90\t100\t8\t10\tyes\trelease\t-\t-\n";
const ok_b = "komira//src/b:b\tsrc/b\tlibrary\tOK\t100\t100\t-\t-\tno\tconda\tb/x.mojo,b/y.mojo\t-\n";
const failed_c = "komira//src/c:c\tsrc/c\tlibrary\tRUN_FAILED\t-\t-\t-\t-\tno\tno\t-\ta run failed\n";
const test_d = "komira//src/tests/d:d\tsrc/tests/d\ttest\tOK\t1\t4\t-\t-\tno\tno\t-\t-\n";
const test_e = "komira//src/tests/e:e\tsrc/tests/e\ttest\tGATE_FAILED\t-\t-\t-\t-\tno\tno\t-\tthe gate failed\n";

test "refusals of the first line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const want = "census.sh: error: census.tsv:1: the first line is census<TAB><date><TAB><commit or -><TAB><note or ->";
    try t.expectEqualStrings(want, try refusal(a, "census\t2026-10-1\t-\tn\n", ""));
    try t.expectEqualStrings(want, try refusal(a, "census\t2026-10-01\tabc\tn\n", ""));
    try t.expectEqualStrings(want, try refusal(a, "census\t2026-10-01\t-\t\n", ""));
    try t.expectEqualStrings(want, try refusal(a, "cens\t2026-10-01\t-\tn\n", ""));
    // Comments come first without counting; the line numbers count them.
    try t.expectEqualStrings("census.sh: error: census.tsv:3: the first line is census<TAB><date><TAB><commit or -><TAB><note or ->", try refusal(a, "# c\n# d\nfoo\n", ""));
    try t.expectEqualStrings("census.sh: error: census.tsv: no census line", try refusal(a, "# only a comment\n", ""));
}

test "refusals of a row" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("census.sh: error: census.tsv:2: a row has 12 fields, not 3", try refusal(a, head ++ "a\tb\tc\n", ""));
    try t.expectEqualStrings("census.sh: error: census.tsv:2: not a library label under src/: komira//tools/x:y", try refusal(a, head ++ "komira//tools/x:y\tp\tlibrary\tOK\t1\t1\t-\t-\tno\tno\t-\t-\n", ""));
    try t.expectEqualStrings("census.sh: error: census.tsv:3: rows are not sorted by label: komira//src/a:a after komira//src/b:b", try refusal(a, head ++ ok_b ++ ok_a, ""));
    try t.expectEqualStrings("census.sh: error: census.tsv:3: rows are not sorted by label: komira//src/a:a after komira//src/a:a", try refusal(a, head ++ ok_a ++ ok_a, ""));
    try t.expectEqualStrings("census.sh: error: census.tsv:2: package src/x is not the label's src/a", try refusal(a, head ++ "komira//src/a:a\tsrc/x\tlibrary\tOK\t1\t1\t-\t-\tno\tno\t-\t-\n", ""));
    try t.expectEqualStrings("census.sh: error: census.tsv:2: kind test is wrong for src/a", try refusal(a, head ++ "komira//src/a:a\tsrc/a\ttest\tOK\t1\t1\t-\t-\tno\tno\t-\t-\n", ""));
    try t.expectEqualStrings("census.sh: error: census.tsv:2: status DONE", try refusal(a, head ++ "komira//src/a:a\tsrc/a\tlibrary\tDONE\t1\t1\t-\t-\tno\tno\t-\t-\n", ""));
    try t.expectEqualStrings("census.sh: error: census.tsv:2: branch_gate or published", try refusal(a, head ++ "komira//src/a:a\tsrc/a\tlibrary\tOK\t1\t1\t-\t-\tmaybe\tno\t-\t-\n", ""));
    try t.expectEqualStrings("census.sh: error: census.tsv:2: line_hit is not a count: 01", try refusal(a, head ++ "komira//src/a:a\tsrc/a\tlibrary\tOK\t01\t1\t-\t-\tno\tno\t-\t-\n", ""));
    try t.expectEqualStrings("census.sh: error: census.tsv:2: line_hit > line_found", try refusal(a, head ++ "komira//src/a:a\tsrc/a\tlibrary\tOK\t5\t4\t-\t-\tno\tno\t-\t-\n", ""));
    try t.expectEqualStrings("census.sh: error: census.tsv:2: branch_hit > branch_found", try refusal(a, head ++ "komira//src/a:a\tsrc/a\tlibrary\tOK\t1\t1\t5\t4\tyes\tno\t-\t-\n", ""));
    try t.expectEqualStrings("census.sh: error: census.tsv:2: an OK row has no note", try refusal(a, head ++ "komira//src/a:a\tsrc/a\tlibrary\tOK\t1\t1\t-\t-\tno\tno\t-\tnote\n", ""));
    try t.expectEqualStrings("census.sh: error: census.tsv:2: a row that is not OK has no numbers and a note", try refusal(a, head ++ "komira//src/a:a\tsrc/a\tlibrary\tRUN_FAILED\t1\t-\t-\t-\tno\tno\t-\twhy\n", ""));
    try t.expectEqualStrings("census.sh: error: census.tsv:2: a row that is not OK has no numbers and a note", try refusal(a, head ++ "komira//src/a:a\tsrc/a\tlibrary\tGATE_FAILED\t-\t-\t-\t-\tno\tno\t-\t-\n", ""));
    try t.expectEqualStrings("census.sh: error: census.tsv:2: an empty field", try refusal(a, head ++ "komira//src/a:a\tsrc/a\tlibrary\tOK\t1\t1\t-\t-\tno\tno\t\t-\n", ""));
}

test "the holds mark a library under the target on a held metric" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var err: []const u8 = "";
    const held = "# held\nsrc/a\tline,branch\nsrc/b\tbranch\n";
    const c = try R.parseCensus(a, "census.tsv", head ++ ok_a ++ ok_b ++ test_d, try heldOf(a, held), 9900, &err);
    // a: 90% line < 99% and line is held: below. b: held on branch with no branch number: below.
    try t.expectEqual(@as(usize, 2), c.ok.len);
    // Ranked lowest line coverage first.
    try t.expectEqualStrings("komira//src/a:a", c.ok[0].library);
    try t.expect(c.ok[0].below);
    try t.expectEqualStrings("line,branch", c.ok[0].held);
    try t.expect(c.ok[1].below);
    try t.expectEqual(@as(usize, 1), c.tests.len);
    const c2 = try R.parseCensus(a, "census.tsv", head ++ ok_a ++ ok_b, try heldOf(a, "src/a\tbranch\n"), 9900, &err);
    // a: held on branch, 8/10 = 80% < 99%: below; b holds nothing: not below.
    try t.expect(c2.ok[0].below);
    try t.expect(!c2.ok[1].below);
    try t.expectEqualStrings("-", c2.ok[1].held);
    // Nothing held: nothing below.
    const c3 = try R.parseCensus(a, "census.tsv", head ++ ok_a, try heldOf(a, ""), 9900, &err);
    try t.expect(!c3.ok[0].below);
}

test "ranking: by line basis points, a library with no line last, then by label" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var err: []const u8 = "";
    const rows = head ++
        "komira//src/a:a\tsrc/a\tlibrary\tOK\t5\t10\t-\t-\tno\tno\t-\t-\n" ++
        "komira//src/b:b\tsrc/b\tlibrary\tOK\t0\t0\t-\t-\tno\tno\t-\t-\n" ++
        "komira//src/c:c\tsrc/c\tlibrary\tOK\t1\t10\t-\t-\tno\tno\t-\t-\n" ++
        "komira//src/d:d\tsrc/d\tlibrary\tOK\t5\t10\t-\t-\tno\tno\t-\t-\n";
    const c = try R.parseCensus(a, "census.tsv", rows, try heldOf(a, ""), 9900, &err);
    try t.expectEqualStrings("komira//src/c:c", c.ok[0].library);
    try t.expectEqualStrings("komira//src/a:a", c.ok[1].library);
    try t.expectEqualStrings("komira//src/d:d", c.ok[2].library);
    try t.expectEqualStrings("komira//src/b:b", c.ok[3].library);
}

test "renderDoc: the summary, the ranked table, the failures, the unmeasured files, the test packages" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var err: []const u8 = "";
    const c = try R.parseCensus(a, "census.tsv", head ++ ok_a ++ ok_b ++ failed_c ++ test_d ++ test_e, try heldOf(a, "src/a\tline,branch\n"), 9900, &err);
    const doc = try R.renderDoc(a, c, 9900);
    const has = struct {
        fn f(d: []const u8, s: []const u8) !void {
            if (std.mem.indexOf(u8, d, s) == null) {
                std.debug.print("no `{s}` in:\n{s}\n", .{ s, d });
                return error.NotInDoc;
            }
        }
    }.f;
    try has(doc, "# Coverage census\n\nGenerated: `./buck2 build //:coverage_census` renders this file from each\n");
    try has(doc, "holds at the 99.00% target.");
    try has(doc, "Census of 2026-10-01 (first census), built with\n");
    try has(doc, "| Libraries (under `src/`, not `src/tests/`) | 3 |\n| Measured | 2 |\n| Not measured (a run or the gate failed) | 1 |\n");
    try has(doc, "| Line coverage, all measured libraries | 95.00% (190/200) |\n");
    try has(doc, "| Median line coverage (lower middle) | 90.00% |\n");
    try has(doc, "| At 100% / 90% to 100% / 50% to 90% / under 50% / no line | 1 / 1 / 0 / 0 / 0 |\n");
    try has(doc, "| Branch coverage of the libraries with branch records (1) | 80.00% (8/10) |\n");
    try has(doc, "| Libraries with files no test compiles | 1 (2 files) |\n");
    try has(doc, "| Published: in the release / a conda package only / neither | 1 / 1 / 1 |\n");
    try has(doc, "| Held and below 99.00% | 1 |\n");
    try has(doc, "| 1 | `src/a:a` | 90.00% (90/100) | 10 | 80.00% (8/10) | 0 | release | line, branch **below target** |\n");
    try has(doc, "| 2 | `src/b:b` | 100.00% (100/100) | 0 | not gated | 2 | conda | - |\n");
    try has(doc, "| Library | Status | Why | Published | Held |\n|---|---|---|---|---|\n| `src/c:c` | RUN_FAILED | a run failed | no | - |\n");
    try has(doc, "- `src/b:b`: `b/x.mojo`, `b/y.mojo`\n");
    try has(doc, "| `src/tests/d:d` | 25.00% (1/4) | 3 | not gated | 0 | OK |\n");
    try has(doc, "| `src/tests/e:e` | - | - | - | - | GATE_FAILED: the gate failed |\n");
}

test "renderDoc: an empty census and no failures say None" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var err: []const u8 = "";
    const c = try R.parseCensus(a, "census.tsv", head, try heldOf(a, ""), 9900, &err);
    const doc = try R.renderDoc(a, c, 9900);
    try t.expect(std.mem.indexOf(u8, doc, "| Line coverage, all measured libraries | n/a |\n| Median line coverage (lower middle) | n/a |\n") != null);
    try t.expect(std.mem.indexOf(u8, doc, "## Not measured\n\nNone.\n") != null);
    try t.expect(std.mem.indexOf(u8, doc, "executable lines uncovered (covcheck's UnmeasuredFile).\n\nNone.\n") != null);
    // A census line with no note is "-": no parenthesis after the date.
    const c2 = try R.parseCensus(a, "census.tsv", "census\t2026-10-02\t-\t-\n", try heldOf(a, ""), 9900, &err);
    try t.expect(std.mem.indexOf(u8, try R.renderDoc(a, c2, 9900), "Census of 2026-10-02, built with\n") != null);
}

test "resultJson: success, or the message escaped line by line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("{\"version\": 1, \"data\": {\"status\": \"success\", \"message\": \"coverage_census: the census renders\"}}\n", try R.resultJson(a, null));
    try t.expectEqualStrings(
        "{\"version\": 1, \"data\": {\"status\": \"failure\", \"message\": \"coverage_census: the census is not one census.sh renders: a \\\"q\\\" \\\\ b\\tc\\nsecond\\n\"}}\n",
        try R.resultJson(a, "the census is not one census.sh renders: a \"q\" \\ b\tc\x01\nsecond\n"),
    );
}
