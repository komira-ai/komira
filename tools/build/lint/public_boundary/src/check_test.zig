//! The lint over a tree (check.zig): a planted tree that passes, then one
//! defect per case, each of which must be reported by the line it names. The
//! cases are those of a tree's paths (a date, a home directory or a deny-list
//! word in a path, the path of binary data), of the holds over the findings
//! (one over a hold, a hold over its findings), of each ledger defect, of the
//! window, and of an empty tree. rules_test.zig holds the spellings.
//!
//! Planted findings are masked as in rules_test.zig: every `~` is dropped
//! before the tree is read.

const std = @import("std");
const check = @import("check.zig");

const File = struct { path: []const u8, text: []const u8 };

/// The tree of each case, from memory: a file whose text is `unreadable`
/// cannot be read.
const Mem = struct {
    files: []const File,

    pub fn read(self: Mem, p: []const u8) ![]const u8 {
        for (self.files) |f| {
            if (!std.mem.eql(u8, f.path, p)) continue;
            if (std.mem.eql(u8, f.text, "unreadable")) return error.AccessDenied;
            return f.text;
        }
        return error.FileNotFound;
    }

    pub fn free(_: Mem, _: []const u8) void {}
};

const PREFIX = "tests//neg/";

const CFG = check.Config{
    .prefix = PREFIX,
    .holds_name = "tests//neg/holds.tsv",
    .hosts_name = "tests//neg/hosts.tsv",
    .from = "2030",
    .public = "2031-09-01",
};

/// held.mojo holds two dates, a home directory and a commit id; data.arrow
/// holds findings that are not read; the BUCK file's URL uses the hosts row.
const TREE = [_]File{
    .{ .path = "docs/near.md", .text = "Nothing here but 2031-09-01 and /ho~me/user/x.\n" },
    .{ .path = "src/komira_a/held.mojo", .text = "# 2031-08-31\n# /ho~me/jdoe/x\nx = 1\n# Aug 31, 2031 and 1a2b3c~4d\n" },
    .{ .path = "src/komira_a/tests/fixtures/data.arrow", .text = "2031-08-31 /ho~me/jdoe/ 10.1.2~.3 jdoe~@corp.zz" },
    .{ .path = "third_party/up/BUCK", .text = "# Source: https:~//github.com/upstream/project\n" },
};

const HOLDS =
    "# The planted findings.\n" ++
    "date\tsrc/komira_a/held.mojo\t2\tplanted\n" ++
    "home_path\tsrc/komira_a/held.mojo\t1\tplanted\n" ++
    "commit_sha\tsrc/komira_a/held.mojo\t1\tplanted\n" ++
    ""
;

const HOSTS = "# The domains.\ngithub.com\tused by third_party/up/BUCK\n";

const Case = struct {
    name: []const u8,
    /// Files added to TREE, or replacing the one at their path.
    plant: []const File = &.{},
    /// Only these files, instead of TREE and `plant`.
    only: ?[]const File = null,
    holds: []const u8 = HOLDS,
    hosts: []const u8 = HOSTS,
    deny: []const u8 = "",
    public: []const u8 = "2031-09-01",
    /// A report line: the whole line, or its start when it ends with `--`.
    want: []const u8,
};

const DENY = "# A word a private consumer keeps out of its public repository.\nzanzibar\n";

const CASES = [_]Case{
    .{ .name = "date", .plant = &.{.{ .path = "docs/plant.md", .text = "Released 2031-08-31.\n" }}, .want = "tests//neg/docs/plant.md:1: date: 2031-08-31 -- a date before 2031-09-01, when the public history starts" },
    .{ .name = "home", .plant = &.{.{ .path = "docs/plant.md", .text = "x\nBuilt in /ho~me/jdoe/src.\n" }}, .want = "tests//neg/docs/plant.md:2: home_path: /ho~me/jdoe -- a home directory names a person: use a placeholder such as /home/user" },
    .{ .name = "ip", .plant = &.{.{ .path = "docs/plant.md", .text = "Reach it at 10.1.2~.3." }}, .want = "tests//neg/docs/plant.md:1: ip: 10.1.2~.3 --" },
    .{ .name = "host", .plant = &.{.{ .path = "docs/plant.md", .text = "See https:~//build.corp.zz/x.\n" }}, .want = "tests//neg/docs/plant.md:1: host: build.corp.zz -- a URL host that is neither a reserved example name nor under a domain of tests//neg/hosts.tsv" },
    .{ .name = "email", .plant = &.{.{ .path = "docs/plant.md", .text = "Ask jdoe~@corp.zz.\n" }}, .want = "tests//neg/docs/plant.md:1: email: jdoe~@corp.zz -- an email address outside the reserved example domains" },
    .{ .name = "sha_md", .plant = &.{.{ .path = "docs/plant.md", .text = "Fixed in 1a2b3c~4d.\n" }}, .want = "tests//neg/docs/plant.md:1: commit_sha: 1a2b3c~4d -- a commit id in prose: name the change by its pull request or release" },
    // third_party/ is read whole, its BUCK files and C headers too.
    .{ .name = "third_party_buck", .plant = &.{.{ .path = "third_party/up/BUCK", .text = "# Read.\n# Source: https:~//github.com/upstream/project\n# Built on 2031-08-31.\n" }}, .want = "tests//neg/third_party/up/BUCK:3: date: 2031-08-31 --" },
    .{ .name = "third_party_c", .plant = &.{.{ .path = "third_party/up/config.h", .text = "/* Built on 2031-08-31. */\n" }}, .want = "tests//neg/third_party/up/config.h:1: date: 2031-08-31 --" },
    // Paths: read at line 0, binary data's too; the file holds nothing.
    .{ .name = "path_date", .plant = &.{.{ .path = "docs/notes_2031_08_31.md", .text = "Nothing here.\n" }}, .want = "tests//neg/docs/notes_2031_08_31.md:0: date: 2031_08_31 (in the path) -- a date before 2031-09-01, when the public history starts" },
    .{ .name = "path_home", .plant = &.{.{ .path = "home/jdoe/notes.md", .text = "Nothing here.\n" }}, .want = "tests//neg/ho~me/jdoe/notes.md:0: home_path: /ho~me/jdoe (in the path) --" },
    .{ .name = "path_deny", .plant = &.{.{ .path = "docs/zanzibar_notes.md", .text = "Nothing here.\n" }}, .deny = DENY, .want = "tests//neg/docs/zanzibar_notes.md:0: deny: zanzibar (in the path) -- a word of the private deny list" },
    .{ .name = "path_binary", .plant = &.{.{ .path = "src/komira_a/tests/fixtures/2031-08-31.arrow", .text = "unreadable" }}, .want = "tests//neg/src/komira_a/tests/fixtures/2031-08-31.arrow:0: date: 2031-08-31 (in the path) --" },
    // One more date than held.mojo's row holds: every site is listed.
    .{ .name = "held_new_site", .plant = &.{.{ .path = "src/komira_a/held.mojo", .text = "# 2031-08-31\n# /ho~me/jdoe/x\nx = 1\n# Aug 31, 2031 and 1a2b3c~4d\n# one more 2031-08-30\n" }}, .want = "tests//neg/src/komira_a/held.mojo:5: date: 2031-08-30 -- a date before 2031-09-01, when the public history starts (3 findings, held 2)" },
    .{ .name = "deny", .plant = &.{.{ .path = "docs/plant.md", .text = "The Zanzibar ledger.\n" }}, .deny = DENY, .want = "tests//neg/docs/plant.md:1: deny: zanzibar -- a word of the private deny list" },
    .{ .name = "deny_held", .plant = &.{.{ .path = "docs/plant.md", .text = "The Zanzibar ledger.\n" }}, .deny = DENY, .holds = HOLDS ++ "deny\tdocs/plant.md\t1\tplanted\n", .want = "tests//neg/holds.tsv:5: unknown rule `deny` (the rules a row can hold: date, home_path, ip, host, email, commit_sha)" },
    .{ .name = "unreadable", .plant = &.{.{ .path = "docs/plant.md", .text = "unreadable" }}, .want = "tests//neg/docs/plant.md: cannot be read (AccessDenied); the lint read nothing of it" },
    // The holds ledger, one row changed or added.
    .{ .name = "holds_malformed", .holds = HOLDS ++ "date\tdocs/near.md\t1\n", .want = "tests//neg/holds.tsv:5: a row has 4 tab-separated fields (rule, file, count, reason), not 3" },
    .{ .name = "holds_rule", .holds = HOLDS ++ "date_time\tdocs/near.md\t1\tplanted\n", .want = "tests//neg/holds.tsv:5: unknown rule `date_time` (the rules a row can hold: date, home_path, ip, host, email, commit_sha)" },
    .{ .name = "holds_file", .holds = HOLDS ++ "date\tsrc/komira_a/gone.mojo\t1\tplanted\n", .want = "tests//neg/holds.tsv:5: src/komira_a/gone.mojo is not a file of the tree; delete the row" },
    .{ .name = "holds_binary", .holds = HOLDS ++ "date\tsrc/komira_a/tests/fixtures/data.arrow\t1\tplanted\n", .want = "tests//neg/holds.tsv:5: date in src/komira_a/tests/fixtures/data.arrow is held at 1 and has 0: delete the row" },
    .{ .name = "holds_count", .holds = HOLDS ++ "ip\tdocs/near.md\t0\tplanted\n", .want = "tests//neg/holds.tsv:5: count `0` is not a positive whole number" },
    .{ .name = "holds_count_sign", .holds = HOLDS ++ "ip\tdocs/near.md\t+1\tplanted\n", .want = "tests//neg/holds.tsv:5: count `+1` is not a positive whole number" },
    .{ .name = "holds_reason", .holds = HOLDS ++ "ip\tdocs/near.md\t1\t \n", .want = "tests//neg/holds.tsv:5: empty reason: say why the file holds it" },
    .{ .name = "holds_duplicate", .holds = HOLDS ++ "date\tsrc/komira_a/held.mojo\t2\tplanted\n", .want = "tests//neg/holds.tsv:5: a second row for date in src/komira_a/held.mojo" },
    .{ .name = "holds_lower", .holds = "date\tsrc/komira_a/held.mojo\t3\tplanted\nhome_path\tsrc/komira_a/held.mojo\t1\tplanted\ncommit_sha\tsrc/komira_a/held.mojo\t1\tplanted\n", .want = "tests//neg/holds.tsv:1: date in src/komira_a/held.mojo is held at 3 and has 2: lower the count to 2" },
    .{ .name = "holds_delete", .holds = HOLDS ++ "date\tdocs/near.md\t1\tplanted\n", .want = "tests//neg/holds.tsv:5: date in docs/near.md is held at 1 and has 0: delete the row" },
    // The hosts ledger.
    .{ .name = "hosts_malformed", .hosts = HOSTS ++ "amazonaws.com\n", .want = "tests//neg/hosts.tsv:3: a row has 2 tab-separated fields (domain, reason), not 1" },
    .{ .name = "hosts_reason", .hosts = HOSTS ++ "amazonaws.com\t\n", .want = "tests//neg/hosts.tsv:3: empty reason: say whose service amazonaws.com is" },
    .{ .name = "hosts_reserved", .hosts = HOSTS ++ "Example.com\tthe examples\n", .want = "tests//neg/hosts.tsv:3: example.com is reserved for examples and needs no row; delete the row" },
    .{ .name = "hosts_duplicate", .hosts = HOSTS ++ "GitHub.com\tagain\n", .want = "tests//neg/hosts.tsv:3: a second row for github.com" },
    .{ .name = "hosts_unused", .hosts = HOSTS ++ "unused.zz\tnothing\n", .want = "tests//neg/hosts.tsv:3: no URL host of the tree is unused.zz or under it; delete the row" },
    // The window, and a tree of binary data only.
    .{ .name = "window_month", .public = "2031-13-01", .want = "public_boundary: the window is from year `2030` to `2031-13-01`; name a year and a later first day of a month (YYYY-MM-01)" },
    .{ .name = "window_day", .public = "2031-09-15", .want = "public_boundary: the window is from year `2030` to `2031-09-15`; name a year and a later first day of a month (YYYY-MM-01)" },
    .{ .name = "empty", .only = &.{.{ .path = "src/komira_a/tests/fixtures/data.arrow", .text = "2031-08-31" }}, .holds = "", .hosts = "", .want = "public_boundary: checked nothing (no inputs, or no lines to check)" },
};

fn unmask(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (s) |c| if (c != '~') try out.append(alloc, c);
    return out.items;
}

/// TREE with `plant` laid over it, unmasked, sorted by path.
fn tree(alloc: std.mem.Allocator, c: Case) ![]const File {
    var out = std.ArrayList(File).empty;
    const base: []const File = c.only orelse &TREE;
    for (base) |f| {
        var replaced = false;
        for (c.plant) |p| replaced = replaced or std.mem.eql(u8, p.path, f.path);
        if (!replaced) try out.append(alloc, .{ .path = f.path, .text = try unmask(alloc, f.text) });
    }
    if (c.only == null) for (c.plant) |p| try out.append(alloc, .{ .path = p.path, .text = try unmask(alloc, p.text) });
    std.mem.sort(File, out.items, {}, struct {
        fn lt(_: void, a: File, b: File) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);
    return out.items;
}

fn runCase(alloc: std.mem.Allocator, c: Case) !check.Report {
    const files = try tree(alloc, c);
    var paths = std.ArrayList([]const u8).empty;
    for (files) |f| try paths.append(alloc, f.path);
    var cfg = CFG;
    cfg.public = c.public;
    return check.run(alloc, cfg, .{ .holds = c.holds, .hosts = c.hosts, .deny = c.deny }, paths.items, Mem{ .files = files });
}

fn dump(r: check.Report) void {
    for (r.lines) |l| std.debug.print("  | {s}\n", .{l});
}

test "the planted tree passes: every finding held at its count, binary data not read, the hosts row used" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try runCase(arena.allocator(), .{ .name = "green", .want = "" });
    if (r.lines.len != 0) {
        dump(r);
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, 3), r.checked);
    const json = try check.result(arena.allocator(), r);
    try std.testing.expectEqualStrings("{\"version\": 1, \"data\": {\"status\": \"success\", \"message\": \"public_boundary: 3 checked\"}}\n", json);
}

test "each planted defect is reported, naming it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    for (CASES) |c| {
        const r = try runCase(alloc, c);
        const want = try unmask(alloc, c.want);
        var found = false;
        for (r.lines) |l| {
            if (std.mem.endsWith(u8, want, "--")) {
                found = found or std.mem.startsWith(u8, l, want);
            } else found = found or std.mem.eql(u8, l, want);
        }
        if (!found) {
            std.debug.print("case {s}: no line `{s}` in\n", .{ c.name, want });
            dump(r);
            return error.TestUnexpectedResult;
        }
    }
}

test "a failing report is a failure result of at most 200 lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var lines = std.ArrayList([]const u8).empty;
    for (0..250) |i| try lines.append(alloc, try std.fmt.allocPrint(alloc, "line \"{d}\"", .{i}));
    const json = try check.result(alloc, .{ .lines = lines.items, .checked = 1 });
    const parsed = try std.json.parseFromSlice(struct { version: u32, data: struct { status: []const u8, message: []const u8 } }, alloc, json, .{});
    try std.testing.expectEqualStrings("failure", parsed.value.data.status);
    try std.testing.expect(std.mem.startsWith(u8, parsed.value.data.message, "public_boundary: 250 finding line(s)\nline \"0\"\n"));
    try std.testing.expectEqual(@as(usize, 201), std.mem.count(u8, parsed.value.data.message, "\n"));
}

test "binary data is known by its suffix" {
    try std.testing.expect(check.binary("a/b/data.arrow"));
    try std.testing.expect(check.binary("x.tar"));
    try std.testing.expect(!check.binary("a/data_arrow.txt"));
    try std.testing.expect(!check.binary("a.arrow/notes.md"));
    try std.testing.expect(!check.binary("Makefile"));
}

test "a directory's files are listed by path, sorted, directories left out" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("b/c");
    try tmp.dir.writeFile(.{ .sub_path = "b/c/z.md", .data = "z" });
    try tmp.dir.writeFile(.{ .sub_path = "a.md", .data = "a" });
    try tmp.dir.writeFile(.{ .sub_path = "b/y.txt", .data = "y" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try check.list(arena.allocator(), tmp.dir);
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("a.md", got[0]);
    try std.testing.expectEqualStrings("b/c/z.md", got[1]);
    try std.testing.expectEqualStrings("b/y.txt", got[2]);
}
