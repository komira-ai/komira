//! The cases of mopm_migrate (mopm_migrate.zig, plan.zig). Each test is a defect a migration would
//! otherwise carry into the tree: a manifest that differs from the hand-written one, a dependency
//! guessed from a BUCK file that disagrees with the sources, a shared row inserted out of order,
//! a plan that writes before it has refused, or a dry run that writes.
//!
//! The golden case runs the tool on the tree komira_resources had before its hand migration
//! (fixtures/komira_resources/old: the files as they were, with the BUCK file and manifest of the one
//! dependency) and requires the hand migration's files: `mopm.toml`, `mopm-toolchain.toml` and
//! `mopm.lock` byte for byte, the two shared rows files as the line-for-line diff the hand
//! migration made (fixtures/.../rows/*.diff), and the BUCK file code byte for byte with its comments
//! compared word for word (the hand comments were wrapped by eye). The documented differences are
//! asserted where they are tested.
const std = @import("std");
const sl = @import("starlark.zig");
const imp = @import("mojo_imports.zig");
const emit = @import("emit.zig");
const plan = @import("plan.zig");
const mm = @import("mopm_migrate.zig");
const t = std.testing;

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

// ---- helpers ------------------------------------------------------------------------------------

fn expectSameBytes(what: []const u8, want: []const u8, got: []const u8) !void {
    if (std.mem.eql(u8, want, got)) return;
    var w = std.mem.splitScalar(u8, want, '\n');
    var g = std.mem.splitScalar(u8, got, '\n');
    var line: usize = 1;
    while (true) : (line += 1) {
        const wl = w.next();
        const gl = g.next();
        if (wl == null and gl == null) break;
        if (wl == null or gl == null or !std.mem.eql(u8, wl.?, gl.?)) {
            std.debug.print("{s} differs at line {d}:\n  want: {s}\n  got:  {s}\n", .{ what, line, wl orelse "(end)", gl orelse "(end)" });
            break;
        }
    }
    return error.TestDiffersFromGolden;
}

fn writeOf(p: plan.Plan, path: []const u8) ![]const u8 {
    for (p.writes) |w| if (std.mem.eql(u8, w.path, path)) return w.text;
    std.debug.print("the plan writes no {s}\n", .{path});
    return error.TestMissingWrite;
}

fn expectRefusal(a: std.mem.Allocator, files: []const plan.File, o: plan.Options, needle: []const u8) !void {
    var c = plan.Ctx{ .a = a };
    if (plan.plan(&c, files, o)) |_| {
        std.debug.print("expected a refusal containing '{s}'\n", .{needle});
        return error.TestExpectedRefusal;
    } else |e| {
        try t.expect(e == error.Refused);
        if (std.mem.indexOf(u8, c.why, needle) == null) {
            std.debug.print("refusal was '{s}', wanted '{s}'\n", .{ c.why, needle });
            return error.TestWrongRefusal;
        }
    }
}

fn planOf(a: std.mem.Allocator, files: []const plan.File, o: plan.Options) !plan.Plan {
    var c = plan.Ctx{ .a = a };
    return plan.plan(&c, files, o) catch |e| {
        if (e == error.Refused) std.debug.print("refused: {s}\n", .{c.why});
        return e;
    };
}

/// Comment paragraphs joined into one line each, words separated by one space; code kept as is.
/// A comment inside a call (indented) is a paragraph too, and keeps its indent.
fn normalize(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var para = std.ArrayList(u8).empty;
    var para_indent: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const body = std.mem.trimLeft(u8, line, " ");
        const indent = line.len - body.len;
        if (std.mem.startsWith(u8, body, "#")) {
            var words = std.mem.tokenizeAny(u8, body[1..], " \t");
            var any = false;
            while (words.next()) |w| {
                if (!any and para.items.len == 0) para_indent = indent;
                any = true;
                try para.append(a, ' ');
                try para.appendSlice(a, w);
            }
            if (any) continue;
        }
        if (para.items.len > 0) {
            try out.appendNTimes(a, ' ', para_indent);
            try out.append(a, '#');
            try out.appendSlice(a, para.items);
            try out.append(a, '\n');
            para.clearRetainingCapacity();
        }
        if (std.mem.startsWith(u8, body, "#")) {
            try out.appendNTimes(a, ' ', indent);
            try out.appendSlice(a, "#\n");
        } else {
            try out.appendSlice(a, line);
            try out.append(a, '\n');
        }
    }
    return out.toOwnedSlice(a);
}

/// `after` must be `before` plus the lines the unified `diff` adds, each hunk's lines contiguous.
fn expectRowsAsDiff(a: std.mem.Allocator, what: []const u8, before: []const u8, after: []const u8, diff: []const u8) !void {
    var added = std.ArrayList([]const u8).empty;
    var hunks = std.ArrayList([]const []const u8).empty;
    var cur = std.ArrayList([]const u8).empty;
    var dl = std.mem.splitScalar(u8, diff, '\n');
    while (dl.next()) |l| {
        if (std.mem.startsWith(u8, l, "@@")) {
            if (cur.items.len > 0) try hunks.append(a, try cur.toOwnedSlice(a));
        } else if (l.len > 0 and l[0] == '+') {
            try added.append(a, l[1..]);
            try cur.append(a, l[1..]);
        } else if (l.len > 0 and l[0] == ' ') {
            try cur.append(a, l[1..]);
        } else if (l.len > 0 and l[0] == '-') return error.TestDiffRemovesLines;
    }
    if (cur.items.len > 0) try hunks.append(a, try cur.toOwnedSlice(a));
    try t.expect(added.items.len > 0);

    var bl = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, before, '\n');
    while (it.next()) |l| try bl.append(a, l);
    var al = std.ArrayList([]const u8).empty;
    it = std.mem.splitScalar(u8, after, '\n');
    while (it.next()) |l| try al.append(a, l);

    // after minus the added lines is before, in order
    var j: usize = 0;
    var used: usize = 0;
    for (al.items) |l| {
        if (j < bl.items.len and std.mem.eql(u8, l, bl.items[j])) {
            j += 1;
            continue;
        }
        var is_added = false;
        for (added.items) |x| is_added = is_added or std.mem.eql(u8, x, l);
        if (!is_added) {
            std.debug.print("{s}: the output has a line that is neither in the old file nor added by the hand migration: {s}\n", .{ what, l });
            return error.TestRowsDiffer;
        }
        used += 1;
    }
    if (j != bl.items.len or used != added.items.len) {
        std.debug.print("{s}: {d} of {d} old lines kept, {d} of {d} added lines present\n", .{ what, j, bl.items.len, used, added.items.len });
        return error.TestRowsDiffer;
    }
    // each hunk, context included, appears as one run of lines
    for (hunks.items) |h| {
        var found = false;
        var s: usize = 0;
        while (s + h.len <= al.items.len and !found) : (s += 1) {
            found = true;
            for (h, 0..) |hl, k| {
                if (!std.mem.eql(u8, hl, al.items[s + k])) {
                    found = false;
                    break;
                }
            }
        }
        if (!found) {
            std.debug.print("{s}: the hunk starting '{s}' is not in the output in one run\n", .{ what, h[0] });
            return error.TestRowsDiffer;
        }
    }
}

// ---- the golden: komira_resources ---------------------------------------------------------------

const fx = struct {
    const old_buck = @embedFile("fixtures/komira_resources/old/BUCK.fixture");
    const old_readme = @embedFile("fixtures/komira_resources/old/README.md");
    const old_init = @embedFile("fixtures/komira_resources/old/__init__.mojo");
    const old_resources = @embedFile("fixtures/komira_resources/old/resources.mojo");
    const old_probe = @embedFile("fixtures/komira_resources/old/tests/resources_probe.mojo");
    const old_test = @embedFile("fixtures/komira_resources/old/tests/test_resources.mojo");
    const sibling_buck = @embedFile("fixtures/komira_resources/old/sibling/BUCK.fixture");
    const sibling_toml = @embedFile("fixtures/komira_resources/old/sibling/mopm.toml");
    const release_buck = @embedFile("fixtures/komira_resources/old/release/BUCK.excerpt");
    const release_artifacts = @embedFile("fixtures/komira_resources/old/release/artifacts.textproto.excerpt");
    const hand_buck = @embedFile("fixtures/komira_resources/hand/BUCK.fixture");
    const hand_toml = @embedFile("fixtures/komira_resources/hand/mopm.toml");
    const hand_toolchain = @embedFile("fixtures/komira_resources/hand/mopm-toolchain.toml");
    const hand_lock = @embedFile("fixtures/komira_resources/hand/mopm.lock");
    const ids_before = @embedFile("fixtures/komira_resources/rows/mopm_native_ids.before.bzl");
    const ids_diff = @embedFile("fixtures/komira_resources/rows/mopm_native_ids.diff");
    const packages_before = @embedFile("fixtures/komira_resources/rows/packages.before.bzl");
    const packages_diff = @embedFile("fixtures/komira_resources/rows/packages.diff");
};

const resources_description = "The files a program reads at run time, found under its own share directory: a resource is named by its path, and an undeclared one is refused.";

fn resourcesTree() []const plan.File {
    return &.{
        .{ .path = "src/komira_resources/BUCK", .text = fx.old_buck },
        .{ .path = "src/komira_resources/README.md", .text = fx.old_readme },
        .{ .path = "src/komira_resources/__init__.mojo", .text = fx.old_init },
        .{ .path = "src/komira_resources/resources.mojo", .text = fx.old_resources },
        .{ .path = "src/komira_resources/coverage_census.tsv" },
        .{ .path = "src/komira_resources/coverage_held" },
        .{ .path = "src/komira_resources/tests/resources_probe.mojo", .text = fx.old_probe },
        .{ .path = "src/komira_resources/tests/test_resources.mojo", .text = fx.old_test },
        .{ .path = "src/komira_resources/tests/fixtures/declared.txt" },
        .{ .path = "src/komira_runtime_paths/BUCK", .text = fx.sibling_buck },
        .{ .path = "src/komira_runtime_paths/mopm.toml", .text = fx.sibling_toml },
        .{ .path = "release/BUCK", .text = fx.release_buck },
        .{ .path = "release/artifacts.textproto", .text = fx.release_artifacts },
        .{ .path = "release/readme_e2e/packages.bzl", .text = fx.packages_before },
        .{ .path = "release/mopm_native_ids.bzl", .text = fx.ids_before },
        .{ .path = "ci/targets.bzl", .text = "TARGETS = []\n" },
    };
}

/// The mopm of the two hand-migrated fixtures (their `mopm-toolchain.toml` files name it).
const fixture_mopm = "0.0.73";
/// A mopm other than the fixtures' one, as a caller passes it with `--mopm`.
const repo_mopm = "0.0.86";

const resources_options = plan.Options{
    .package = "komira_resources",
    .description = resources_description,
    .mopm = fixture_mopm,
    .test_layout = "installed",
};

test "golden: the manifest, the toolchain file and the lock are the hand migration's, byte for byte" {
    var ar = arena();
    defer ar.deinit();
    const p = try planOf(ar.allocator(), resourcesTree(), resources_options);
    try expectSameBytes("mopm.toml", fx.hand_toml, try writeOf(p, "src/komira_resources/mopm.toml"));
    try expectSameBytes("mopm-toolchain.toml", fx.hand_toolchain, try writeOf(p, "src/komira_resources/mopm-toolchain.toml"));
    try expectSameBytes("mopm.lock", fx.hand_lock, try writeOf(p, "src/komira_resources/mopm.lock"));
}

test "golden: the two shared rows files get the lines the hand migration added, in the same places" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const p = try planOf(a, resourcesTree(), resources_options);
    try expectRowsAsDiff(a, "release/readme_e2e/packages.bzl", fx.packages_before, try writeOf(p, "release/readme_e2e/packages.bzl"), fx.packages_diff);
    try expectRowsAsDiff(a, "release/mopm_native_ids.bzl", fx.ids_before, try writeOf(p, "release/mopm_native_ids.bzl"), fx.ids_diff);
    // ci/targets rows are generated: the plan neither writes them nor reads the file.
    for (p.writes) |w| try t.expect(std.mem.indexOf(u8, w.path, "ci/targets") == null);
}

test "golden: the BUCK file is the hand migration's in code and in comment words, with two documented differences" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const p = try planOf(a, resourcesTree(), resources_options);
    const got = try normalize(a, try writeOf(p, "src/komira_resources/BUCK"));
    var want = try normalize(a, fx.hand_buck);

    // Difference 1: the tool keeps the comment above the old mojo_library as written. The hand
    // migration edited one path in it, because the library file moved.
    const old_ref = "see resources.mojo.";
    const new_ref = "see src/komira_resources/resources.mojo.";
    try t.expect(std.mem.indexOf(u8, got, old_ref) != null);
    try t.expect(std.mem.indexOf(u8, want, new_ref) != null);
    const got_fixed = try std.mem.replaceOwned(u8, a, got, old_ref, new_ref);

    // Difference 2: the hand migration wrote a comment for the helper binary (why it depends on
    // komira_runtime_paths and not on the library whose test runs it). The old file had none,
    // so the tool writes none.
    const hand_only = "# The program the test runs as its data (see above). It uses komira_runtime_paths.data_path, the rule komira_resources applies, rather than komira_resources itself: that library's gated test runs this program, so depending on the gated library would be a cycle.\n";
    try t.expect(std.mem.indexOf(u8, want, hand_only) != null);
    want = try std.mem.replaceOwned(u8, a, want, hand_only, "");

    try expectSameBytes("BUCK (comments normalized)", want, got_fixed);
}

test "golden: the files move into the nested layout and the sources that are not the library stay" {
    var ar = arena();
    defer ar.deinit();
    const p = try planOf(ar.allocator(), resourcesTree(), resources_options);
    try t.expectEqual(@as(usize, 2), p.moves.len);
    try t.expectEqualStrings("src/komira_resources/__init__.mojo", p.moves[0].from);
    try t.expectEqualStrings("src/komira_resources/src/komira_resources/__init__.mojo", p.moves[0].to);
    try t.expectEqualStrings("src/komira_resources/resources.mojo", p.moves[1].from);
    try t.expectEqualStrings("src/komira_resources/src/komira_resources/resources.mojo", p.moves[1].to);
}

test "golden: the README keeps its text and gains the Build files section" {
    var ar = arena();
    defer ar.deinit();
    const p = try planOf(ar.allocator(), resourcesTree(), resources_options);
    const readme = try writeOf(p, "src/komira_resources/README.md");
    try t.expect(std.mem.startsWith(u8, readme, fx.old_readme));
    const tail = readme[fx.old_readme.len..];
    try t.expect(std.mem.startsWith(u8, tail, "\n## Build files\n"));
    try t.expect(std.mem.indexOf(u8, tail, "`mojo-komira_runtime_paths >=0.1,<0.2`") != null);
    try t.expect(std.mem.indexOf(u8, tail, "| `mopm.lock` |") != null);
}

// ---- the golden: komira_collections (a library with [dependencies]) ------------------------------

const cx = struct {
    const dir = "fixtures/komira_collections/";
    const old_buck = @embedFile(dir ++ "old/BUCK.fixture");
    const old_readme = @embedFile(dir ++ "old/README.md");
    const old_init = @embedFile(dir ++ "old/__init__.mojo.fixture");
    const old_dyn = @embedFile(dir ++ "old/dyn_value.mojo.fixture");
    const old_hll = @embedFile(dir ++ "old/hyperloglog.mojo.fixture");
    const old_slab = @embedFile(dir ++ "old/slab.mojo.fixture");
    const old_pack = @embedFile(dir ++ "old/variadic_pack.mojo.fixture");
    const old_t_atomic = @embedFile(dir ++ "old/tests/test_atomic_slab.mojo.fixture");
    const old_t_dyn = @embedFile(dir ++ "old/tests/test_dyn_value.mojo.fixture");
    const old_t_hll = @embedFile(dir ++ "old/tests/test_hyperloglog.mojo.fixture");
    const old_t_owned = @embedFile(dir ++ "old/tests/test_owned_slab.mojo.fixture");
    const old_t_slab = @embedFile(dir ++ "old/tests/test_slab.mojo.fixture");
    const old_t_edges = @embedFile(dir ++ "old/tests/test_slab_edges.mojo.fixture");
    const old_t_pack = @embedFile(dir ++ "old/tests/test_variadic_pack.mojo.fixture");
    const sibling_buck = @embedFile(dir ++ "old/sibling/BUCK.fixture");
    const sibling_toml = @embedFile(dir ++ "old/sibling/mopm.toml");
    const release_buck = @embedFile(dir ++ "old/release/BUCK.excerpt");
    const release_artifacts = @embedFile(dir ++ "old/release/artifacts.textproto.excerpt");
    const hand_buck = @embedFile(dir ++ "hand/BUCK.fixture");
    const hand_toml = @embedFile(dir ++ "hand/mopm.toml");
    const hand_toolchain = @embedFile(dir ++ "hand/mopm-toolchain.toml");
    const hand_lock = @embedFile(dir ++ "hand/mopm.lock");
    const ids_before = @embedFile(dir ++ "rows/mopm_native_ids.before.bzl");
    const ids_diff = @embedFile(dir ++ "rows/mopm_native_ids.diff");
    const packages_before = @embedFile(dir ++ "rows/packages.before.bzl");
    const packages_diff = @embedFile(dir ++ "rows/packages.diff");
};

const collections_description = "Generic containers: a typed slab, a type-erased inline value, a variadic pack and a HyperLogLog cardinality sketch.";

fn collectionsTree() []const plan.File {
    return &.{
        .{ .path = "src/komira_collections/BUCK", .text = cx.old_buck },
        .{ .path = "src/komira_collections/README.md", .text = cx.old_readme },
        .{ .path = "src/komira_collections/__init__.mojo", .text = cx.old_init },
        .{ .path = "src/komira_collections/dyn_value.mojo", .text = cx.old_dyn },
        .{ .path = "src/komira_collections/hyperloglog.mojo", .text = cx.old_hll },
        .{ .path = "src/komira_collections/slab.mojo", .text = cx.old_slab },
        .{ .path = "src/komira_collections/variadic_pack.mojo", .text = cx.old_pack },
        .{ .path = "src/komira_collections/coverage_census.tsv" },
        .{ .path = "src/komira_collections/tests/test_atomic_slab.mojo", .text = cx.old_t_atomic },
        .{ .path = "src/komira_collections/tests/test_dyn_value.mojo", .text = cx.old_t_dyn },
        .{ .path = "src/komira_collections/tests/test_hyperloglog.mojo", .text = cx.old_t_hll },
        .{ .path = "src/komira_collections/tests/test_owned_slab.mojo", .text = cx.old_t_owned },
        .{ .path = "src/komira_collections/tests/test_slab.mojo", .text = cx.old_t_slab },
        .{ .path = "src/komira_collections/tests/test_slab_edges.mojo", .text = cx.old_t_edges },
        .{ .path = "src/komira_collections/tests/test_variadic_pack.mojo", .text = cx.old_t_pack },
        .{ .path = "src/komira_atomic_alias/BUCK", .text = cx.sibling_buck },
        .{ .path = "src/komira_atomic_alias/mopm.toml", .text = cx.sibling_toml },
        .{ .path = "release/BUCK", .text = cx.release_buck },
        .{ .path = "release/artifacts.textproto", .text = cx.release_artifacts },
        .{ .path = "release/readme_e2e/packages.bzl", .text = cx.packages_before },
        .{ .path = "release/mopm_native_ids.bzl", .text = cx.ids_before },
    };
}

const collections_options = plan.Options{ .package = "komira_collections", .description = collections_description, .mopm = fixture_mopm };

test "golden collections: the manifest with [dependencies], the toolchain file and the lock are the hand migration's, byte for byte" {
    var ar = arena();
    defer ar.deinit();
    const p = try planOf(ar.allocator(), collectionsTree(), collections_options);
    try expectSameBytes("mopm.toml", cx.hand_toml, try writeOf(p, "src/komira_collections/mopm.toml"));
    try expectSameBytes("mopm-toolchain.toml", cx.hand_toolchain, try writeOf(p, "src/komira_collections/mopm-toolchain.toml"));
    try expectSameBytes("mopm.lock", cx.hand_lock, try writeOf(p, "src/komira_collections/mopm.lock"));
}

test "golden collections: the two shared rows files get the lines the hand migration added, in the same places" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const p = try planOf(a, collectionsTree(), collections_options);
    try expectRowsAsDiff(a, "release/readme_e2e/packages.bzl", cx.packages_before, try writeOf(p, "release/readme_e2e/packages.bzl"), cx.packages_diff);
    try expectRowsAsDiff(a, "release/mopm_native_ids.bzl", cx.ids_before, try writeOf(p, "release/mopm_native_ids.bzl"), cx.ids_diff);
}

test "golden collections: the BUCK file is the hand migration's in code and in comment words, with three documented differences, and the stale header is flagged" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const p = try planOf(a, collectionsTree(), collections_options);
    const got = try normalize(a, try writeOf(p, "src/komira_collections/BUCK"));
    const want = try normalize(a, cx.hand_buck);

    // The old header comment said "generic containers with no dependencies"; the package has one
    // dependency, and the hand migration edited the sentence. The tool keeps the comment as
    // written and says so in its notes.
    const old_words = "generic containers with no dependencies.";
    const new_words = "generic containers. The only dependency is komira_atomic_alias.";
    try t.expect(std.mem.indexOf(u8, got, old_words) != null);
    try t.expect(std.mem.indexOf(u8, want, new_words) != null);
    // Second: with several tests the tool says "every test of tests/ has passed"; the hand file
    // says "the tests of tests/ have passed". The same fact in other words.
    const tool_words = "exists only once every test of tests/ has passed.";
    const hand_words = "exists only once the tests of tests/ have passed.";
    try t.expect(std.mem.indexOf(u8, got, tool_words) != null);
    // Third: the tool's comment on `conda_holds` adds a clause the hand comment does not have.
    const holds_tool = "under `lib/mojo/` (komira_atomic_alias is not in it), and exactly one dependency, `mojo-komira_atomic_alias >=0.1,<0.2`, which is what installing the package pulls in.";
    const holds_hand = "under `lib/mojo/`, and exactly one dependency, `mojo-komira_atomic_alias >=0.1,<0.2`.";
    try t.expect(std.mem.indexOf(u8, got, holds_tool) != null);
    var fixed = try std.mem.replaceOwned(u8, a, got, old_words, new_words);
    fixed = try std.mem.replaceOwned(u8, a, fixed, tool_words, hand_words);
    fixed = try std.mem.replaceOwned(u8, a, fixed, holds_tool, holds_hand);
    try expectSameBytes("BUCK (comments normalized)", want, fixed);
    var flagged = false;
    for (p.notes) |n| flagged = flagged or std.mem.indexOf(u8, n, "says the package has no dependencies, and it has some") != null;
    try t.expect(flagged);
}

test "golden collections: five library files move, the tests and the tables stay" {
    var ar = arena();
    defer ar.deinit();
    const p = try planOf(ar.allocator(), collectionsTree(), collections_options);
    try t.expectEqual(@as(usize, 5), p.moves.len);
    for (p.moves) |m| {
        try t.expect(std.mem.startsWith(u8, m.to, "src/komira_collections/src/komira_collections/"));
        try t.expect(std.mem.indexOf(u8, m.from, "/tests/") == null);
    }
}

// ---- the golden: komira_dynamic_filter (a dependency whose closure declares static natives) -------
//
// komira_dynamic_filter depends on komira_buffer, which depends on komira_libc, which declares
// `[native.komira_libc_posix]` (a static archive). The package owns no C; the hand migration added
// `cxx_toolchain` to its `mojo_adopted_library` so a dependent's link takes the archive from the closure.

const dfx = struct {
    const dir = "fixtures/komira_dynamic_filter/";
    const old_buck = @embedFile(dir ++ "old/BUCK.fixture");
    const old_readme = @embedFile(dir ++ "old/README.md");
    const old_init = @embedFile(dir ++ "old/__init__.mojo.fixture");
    const old_bloom = @embedFile(dir ++ "old/bloom_filter.mojo.fixture");
    const old_constant = @embedFile(dir ++ "old/constant_filter.mojo.fixture");
    const old_in_list = @embedFile(dir ++ "old/in_list_filter.mojo.fixture");
    const old_range = @embedFile(dir ++ "old/range_filter.mojo.fixture");
    const old_tracker = @embedFile(dir ++ "old/selectivity_tracker.mojo.fixture");
    const old_t_parity = @embedFile(dir ++ "old/tests/test_bloom_filter_simd_parity.mojo.fixture");
    const old_t_unit = @embedFile(dir ++ "old/tests/test_bloom_filter_unit.mojo.fixture");
    const old_t_tail = @embedFile(dir ++ "old/tests/test_bloom_from_bytes_merge_tail.mojo.fixture");
    const old_t_hash = @embedFile(dir ++ "old/tests/test_bloom_hash_families.mojo.fixture");
    const old_t_in_list = @embedFile(dir ++ "old/tests/test_bloom_in_list_filter.mojo.fixture");
    const old_t_merge = @embedFile(dir ++ "old/tests/test_bloom_merge_or_range_simd_parity.mojo.fixture");
    const old_t_range = @embedFile(dir ++ "old/tests/test_bloom_range_filter.mojo.fixture");
    const old_t_tracker = @embedFile(dir ++ "old/tests/test_bloom_selectivity_tracker.mojo.fixture");
    const old_t_constant = @embedFile(dir ++ "old/tests/test_constant_filter.mojo.fixture");
    const alias_toml = @embedFile(dir ++ "old/siblings/komira_atomic_alias/mopm.toml");
    const buffer_toml = @embedFile(dir ++ "old/siblings/komira_buffer/mopm.toml");
    const host_toml = @embedFile(dir ++ "old/siblings/komira_host/mopm.toml");
    const libc_toml = @embedFile(dir ++ "old/siblings/komira_libc/mopm.toml");
    const simd_toml = @embedFile(dir ++ "old/siblings/komira_simd/mopm.toml");
    const release_buck = @embedFile(dir ++ "old/release/BUCK.excerpt");
    const release_artifacts = @embedFile(dir ++ "old/release/artifacts.textproto.excerpt");
    const hand_buck = @embedFile(dir ++ "hand/BUCK.fixture");
    const hand_toml = @embedFile(dir ++ "hand/mopm.toml");
    const hand_toolchain = @embedFile(dir ++ "hand/mopm-toolchain.toml");
    const hand_lock = @embedFile(dir ++ "hand/mopm.lock");
    const ids_before = @embedFile(dir ++ "rows/mopm_native_ids.before.bzl");
    const ids_diff = @embedFile(dir ++ "rows/mopm_native_ids.diff");
    const packages_before = @embedFile(dir ++ "rows/packages.before.bzl");
    const packages_diff = @embedFile(dir ++ "rows/packages.diff");
};

const dynamic_filter_description = "Bloom, range, IN-list and constant filters and the selectivity tracker.";
/// The BUCK file of a package already on `mojo_package`, as far as the tool reads it.
const sibling_migrated_buck = "mojo_package(path = \".\")\n";

fn dynamicFilterTree() []const plan.File {
    return &.{
        .{ .path = "src/komira_dynamic_filter/BUCK", .text = dfx.old_buck },
        .{ .path = "src/komira_dynamic_filter/README.md", .text = dfx.old_readme },
        .{ .path = "src/komira_dynamic_filter/__init__.mojo", .text = dfx.old_init },
        .{ .path = "src/komira_dynamic_filter/bloom_filter.mojo", .text = dfx.old_bloom },
        .{ .path = "src/komira_dynamic_filter/constant_filter.mojo", .text = dfx.old_constant },
        .{ .path = "src/komira_dynamic_filter/in_list_filter.mojo", .text = dfx.old_in_list },
        .{ .path = "src/komira_dynamic_filter/range_filter.mojo", .text = dfx.old_range },
        .{ .path = "src/komira_dynamic_filter/selectivity_tracker.mojo", .text = dfx.old_tracker },
        .{ .path = "src/komira_dynamic_filter/coverage_census.tsv" },
        .{ .path = "src/komira_dynamic_filter/coverage_held" },
        .{ .path = "src/komira_dynamic_filter/tests/test_bloom_filter_simd_parity.mojo", .text = dfx.old_t_parity },
        .{ .path = "src/komira_dynamic_filter/tests/test_bloom_filter_unit.mojo", .text = dfx.old_t_unit },
        .{ .path = "src/komira_dynamic_filter/tests/test_bloom_from_bytes_merge_tail.mojo", .text = dfx.old_t_tail },
        .{ .path = "src/komira_dynamic_filter/tests/test_bloom_hash_families.mojo", .text = dfx.old_t_hash },
        .{ .path = "src/komira_dynamic_filter/tests/test_bloom_in_list_filter.mojo", .text = dfx.old_t_in_list },
        .{ .path = "src/komira_dynamic_filter/tests/test_bloom_merge_or_range_simd_parity.mojo", .text = dfx.old_t_merge },
        .{ .path = "src/komira_dynamic_filter/tests/test_bloom_range_filter.mojo", .text = dfx.old_t_range },
        .{ .path = "src/komira_dynamic_filter/tests/test_bloom_selectivity_tracker.mojo", .text = dfx.old_t_tracker },
        .{ .path = "src/komira_dynamic_filter/tests/test_constant_filter.mojo", .text = dfx.old_t_constant },
        .{ .path = "src/komira_atomic_alias/BUCK", .text = sibling_migrated_buck },
        .{ .path = "src/komira_atomic_alias/mopm.toml", .text = dfx.alias_toml },
        .{ .path = "src/komira_buffer/BUCK", .text = sibling_migrated_buck },
        .{ .path = "src/komira_buffer/mopm.toml", .text = dfx.buffer_toml },
        .{ .path = "src/komira_host/mopm.toml", .text = dfx.host_toml },
        .{ .path = "src/komira_libc/mopm.toml", .text = dfx.libc_toml },
        .{ .path = "src/komira_simd/mopm.toml", .text = dfx.simd_toml },
        .{ .path = "release/BUCK", .text = dfx.release_buck },
        .{ .path = "release/artifacts.textproto", .text = dfx.release_artifacts },
        .{ .path = "release/readme_e2e/packages.bzl", .text = dfx.packages_before },
        .{ .path = "release/mopm_native_ids.bzl", .text = dfx.ids_before },
    };
}

const dynamic_filter_options = plan.Options{ .package = "komira_dynamic_filter", .description = dynamic_filter_description, .mopm = fixture_mopm };

test "golden dynamic_filter: the manifest, the toolchain file and the lock of a closure with a native-declaring package are the hand migration's, byte for byte" {
    var ar = arena();
    defer ar.deinit();
    const p = try planOf(ar.allocator(), dynamicFilterTree(), dynamic_filter_options);
    try expectSameBytes("mopm.toml", dfx.hand_toml, try writeOf(p, "src/komira_dynamic_filter/mopm.toml"));
    try expectSameBytes("mopm-toolchain.toml", dfx.hand_toolchain, try writeOf(p, "src/komira_dynamic_filter/mopm-toolchain.toml"));
    try expectSameBytes("mopm.lock", dfx.hand_lock, try writeOf(p, "src/komira_dynamic_filter/mopm.lock"));
}

test "golden dynamic_filter: the two shared rows files get the lines the hand migration added, in the same places" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const p = try planOf(a, dynamicFilterTree(), dynamic_filter_options);
    try expectRowsAsDiff(a, "release/readme_e2e/packages.bzl", dfx.packages_before, try writeOf(p, "release/readme_e2e/packages.bzl"), dfx.packages_diff);
    try expectRowsAsDiff(a, "release/mopm_native_ids.bzl", dfx.ids_before, try writeOf(p, "release/mopm_native_ids.bzl"), dfx.ids_diff);
}

test "golden dynamic_filter: the BUCK file is the hand migration's in code (cxx_toolchain included) and in comment words, with documented differences" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const p = try planOf(a, dynamicFilterTree(), dynamic_filter_options);
    const got = try normalize(a, try writeOf(p, "src/komira_dynamic_filter/BUCK"));
    const want = try normalize(a, dfx.hand_buck);

    // The attribute is code and is compared byte for byte below; its comment is prose that names the
    // package that links C. The hand comment names komira_buffer and komira_libc; the tool knows the
    // packages whose manifest declares static natives (komira_libc) and says so in its own words.
    const tool_c = "    # komira_libc is in the closure and links C (static `[native.<id>]` archives), so `lib`'s closure carries that archive and a dependent's link takes it from here. This package owns no C, so it names no `c_deps`: it takes the C toolchain's link facts directly.\n";
    const hand_c = "    # komira_buffer's closure links C (komira_libc's posix shim), so `lib`'s closure carries that archive and a dependent's link takes it from here. This package owns no C, so it names no `c_deps`: it takes the C toolchain's link facts directly.\n";
    try t.expect(std.mem.indexOf(u8, got, tool_c) != null);
    try t.expect(std.mem.indexOf(u8, want, hand_c) != null);
    var fixed = try std.mem.replaceOwned(u8, a, got, tool_c, hand_c);
    // The same fact in other words: the tool says "those packages'" where the hand file says "their".
    fixed = try std.mem.replaceOwned(u8, a, fixed, "its `:lib` is built from those packages' `:lib`.", "its `:lib` is built from their `:lib`.");
    // The conda comment lists the requirements in place of "(`mojo-<name> >=0.1,<0.2`)" and says
    // "those packages' files nowhere" where the hand file says "none of their files".
    fixed = try std.mem.replaceOwned(u8, a, fixed, "(`mojo-komira_atomic_alias >=0.1,<0.2` and `mojo-komira_buffer >=0.1,<0.2`) and holds those packages' files nowhere.", "(`mojo-<name> >=0.1,<0.2`) and holds none of their files.");
    // The comment on `conda_holds` adds a clause the hand comment does not have and writes the count
    // as a digit.
    fixed = try std.mem.replaceOwned(u8, a, fixed, "under `lib/mojo/` (komira_atomic_alias and komira_buffer are not in it), and exactly 2 dependencies, `mojo-komira_atomic_alias >=0.1,<0.2` and `mojo-komira_buffer >=0.1,<0.2`, which is", "under `lib/mojo/`, and exactly two dependencies, which is");
    try expectSameBytes("BUCK (comments normalized)", want, fixed);
}

test "golden dynamic_filter: a package whose closure has no native-declaring package gets no cxx_toolchain" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // the same package, with komira_libc declaring nothing: only the libc manifest changes
    var files = std.ArrayList(plan.File).empty;
    for (dynamicFilterTree()) |f| {
        if (std.mem.eql(u8, f.path, "src/komira_libc/mopm.toml")) {
            try files.append(a, .{ .path = f.path, .text = try std.mem.replaceOwned(u8, a, f.text.?, "[native.", "[ignored.") });
        } else try files.append(a, f);
    }
    const p = try planOf(a, files.items, dynamic_filter_options);
    try t.expect(std.mem.indexOf(u8, try writeOf(p, "src/komira_dynamic_filter/BUCK"), "cxx_toolchain") == null);
}

test "golden dynamic_filter: the README names the native-declaring package of the closure" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const p = try planOf(a, dynamicFilterTree(), dynamic_filter_options);
    const readme = try writeOf(p, "src/komira_dynamic_filter/README.md");
    try t.expect(std.mem.indexOf(u8, readme, "komira_libc in the closure links C of its own (static `[native.<id>]` archives); a dependent's link takes it from the closure, and this package owns no C.") != null);
}

// ---- a small repository for the refusals -----------------------------------------------------------

const mini_buck =
    \\load("@komira//tools/build/mojo:defs.bzl", "mojo_library")
    \\
    \\mojo_library(
    \\    name = "alpha",
    \\    srcs = glob(["**/*.mojo"], exclude = ["tests/**/*.mojo"]),
    \\    deps = ["//src/beta:beta"],
    \\    test_srcs = ["tests/test_alpha.mojo"],
    \\    visibility = ["PUBLIC"],
    \\)
    \\
;

const beta_toml_text =
    \\[package]
    \\name = "beta"
    \\version = "0.1.0"
    \\
    \\[targets]
    \\lib = { path = "src/beta" }
    \\
;

const migrated_buck = "mojo_package(path = \".\")\n";

const rows_packages =
    \\PACKAGES = {
    \\    "beta": "0.1.0",
    \\    "zeta": "0.1.0",
    \\}
    \\
;
const rows_ids =
    \\load("//src/beta:buildrules.mojo.lock.bzl", beta = "GRAPH")
    \\load("//src/zeta:buildrules.mojo.lock.bzl", zeta = "GRAPH")
    \\
    \\_GRAPHS = {
    \\    "beta": beta,
    \\    "zeta": zeta,
    \\}
    \\
;

const Mini = struct {
    buck: []const u8 = mini_buck,
    init: []const u8 = "from beta import thing\n",
    test_src: []const u8 = "from alpha import x\nfrom std.testing import assert_true\n",
    beta_buck: []const u8 = migrated_buck,
    beta_toml: []const u8 = beta_toml_text,
    /// Replaces the extra files of the package or the siblings.
    extra: []const plan.File = &.{},
    readme: ?[]const u8 = "# alpha\n",
};

fn mini(a: std.mem.Allocator, m: Mini) ![]const plan.File {
    var files = std.ArrayList(plan.File).empty;
    try files.append(a, .{ .path = "src/alpha/BUCK", .text = m.buck });
    if (m.readme) |r| try files.append(a, .{ .path = "src/alpha/README.md", .text = r });
    try files.append(a, .{ .path = "src/alpha/__init__.mojo", .text = m.init });
    try files.append(a, .{ .path = "src/alpha/tests/test_alpha.mojo", .text = m.test_src });
    try files.append(a, .{ .path = "src/beta/BUCK", .text = m.beta_buck });
    try files.append(a, .{ .path = "src/beta/mopm.toml", .text = m.beta_toml });
    try files.append(a, .{ .path = "release/readme_e2e/packages.bzl", .text = rows_packages });
    try files.append(a, .{ .path = "release/mopm_native_ids.bzl", .text = rows_ids });
    try files.appendSlice(a, m.extra);
    return files.toOwnedSlice(a);
}

const mini_options = plan.Options{ .package = "alpha", .description = "A library.", .mopm = repo_mopm };

fn buckWith(a: std.mem.Allocator, from: []const u8, to: []const u8) ![]const u8 {
    try t.expect(std.mem.indexOf(u8, mini_buck, from) != null);
    return std.mem.replaceOwned(u8, a, mini_buck, from, to);
}

test "the mini repository migrates: dependency, rows in order, moves" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const p = try planOf(a, try mini(a, .{}), mini_options);
    try t.expect(std.mem.indexOf(u8, try writeOf(p, "src/alpha/mopm.toml"), "beta = { path = \"../beta\", version = \"0.1\" }") != null);
    try expectSameBytes("packages", "PACKAGES = {\n    \"alpha\": \"0.1.0\",\n    \"beta\": \"0.1.0\",\n    \"zeta\": \"0.1.0\",\n}\n", try writeOf(p, "release/readme_e2e/packages.bzl"));
    try expectSameBytes("ids", "load(\"//src/alpha:buildrules.mojo.lock.bzl\", alpha = \"GRAPH\")\nload(\"//src/beta:buildrules.mojo.lock.bzl\", beta = \"GRAPH\")\nload(\"//src/zeta:buildrules.mojo.lock.bzl\", zeta = \"GRAPH\")\n\n_GRAPHS = {\n    \"alpha\": alpha,\n    \"beta\": beta,\n    \"zeta\": zeta,\n}\n", try writeOf(p, "release/mopm_native_ids.bzl"));
    try t.expectEqual(@as(usize, 1), p.moves.len);
}

test "a package with no dependency gets no conda_holds row, no members and no [dependencies]" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const buck = try buckWith(a, "    deps = [\"//src/beta:beta\"],\n", "");
    const p = try planOf(a, try mini(a, .{ .buck = buck, .init = "from std.memory import memcpy\n" }), mini_options);
    try t.expect(std.mem.indexOf(u8, try writeOf(p, "src/alpha/mopm.toml"), "[dependencies]") == null);
    try t.expect(std.mem.indexOf(u8, try writeOf(p, "src/alpha/BUCK"), "mojo_conda_holds") == null);
    try t.expect(std.mem.indexOf(u8, try writeOf(p, "src/alpha/BUCK"), "members") == null);
    try t.expect(std.mem.indexOf(u8, try writeOf(p, "src/alpha/mopm.lock"), "\"packages\": []") != null);
}

test "a chain: the closure is locked and its manifests are members, and the holds list the direct dependency only" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const beta_toml = beta_toml_text ++ "\n[dependencies]\ngamma = { path = \"../gamma\", version = \"0.1\" }\n";
    const extra = [_]plan.File{
        .{ .path = "src/gamma/BUCK", .text = migrated_buck },
        .{ .path = "src/gamma/mopm.toml", .text = "[package]\nname = \"gamma\"\nversion = \"0.1.4\"\n" },
    };
    const p = try planOf(a, try mini(a, .{ .beta_toml = beta_toml, .extra = &extra }), mini_options);
    const lock = try writeOf(p, "src/alpha/mopm.lock");
    try t.expect(std.mem.indexOf(u8, lock, "\"name\": \"beta\",\n      \"version\": \"0.1.0\",\n      \"source\": \"path\",\n      \"path\": \"../beta\",\n      \"deps\": [\n        \"gamma\"\n      ]\n    },\n    {\n      \"name\": \"gamma\",\n      \"version\": \"0.1.4\"") != null);
    const buck = try writeOf(p, "src/alpha/BUCK");
    try t.expect(std.mem.indexOf(u8, buck, "        \"../beta\": \"//src/beta:mopm.toml\",\n        \"../gamma\": \"//src/gamma:mopm.toml\",\n") != null);
    try t.expect(std.mem.indexOf(u8, buck, "depends = [\"mojo-beta >=0.1,<0.2\"]") != null);
}

test "refuses an import that maps to no known package" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try expectRefusal(a, try mini(a, .{ .init = "from beta import thing\nfrom gamma import other\n" }), mini_options, "imports 'gamma', which maps to no known package");
}

test "refuses a dependency still on the old rule, naming it" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const old = "mojo_library(\n    name = \"beta\",\n)\n";
    const files = try mini(a, .{ .beta_buck = old, .extra = &.{} });
    // the sibling has a manifest in the mini repository; the old rule is what makes it unmigrated
    var no_toml = std.ArrayList(plan.File).empty;
    for (files) |f| if (!std.mem.eql(u8, f.path, "src/beta/mopm.toml")) try no_toml.append(a, f);
    try expectRefusal(a, no_toml.items, mini_options, "'beta', which is still on the old rule (mojo_library)");
}

test "refuses native code in each form: C sources, a native attribute, a native rule, a native dependency" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try expectRefusal(a, try mini(a, .{ .extra = &.{.{ .path = "src/alpha/shim.c" }} }), mini_options, "a native source or library");
    try expectRefusal(a, try mini(a, .{ .buck = try buckWith(a, "    visibility", "    native = \":alpha_native\",\n    visibility") }), mini_options, "'native' declares native code");
    try expectRefusal(a, try mini(a, .{ .buck = try std.mem.concat(a, u8, &.{ mini_buck, "\nnative_shared_library(name = \"x\")\n" }) }), mini_options, "native_shared_library: a native library");
    try expectRefusal(a, try mini(a, .{ .beta_toml = beta_toml_text ++ "\n[native-dependencies]\nlz4 = { version = \">=1.9\", kind = \"shared\", mode = \"load\" }\n" }), mini_options, "natives other than static");
}

test "a dependency that declares only static natives is accepted: cxx_toolchain, named in the comment" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const p = try planOf(a, try mini(a, .{ .beta_toml = beta_toml_text ++ "\n[native.beta_shim]\nkind = \"static\"\nsrcs = [\"native/beta_shim.c\"]\n" }), mini_options);
    const buck = try writeOf(p, "src/alpha/BUCK");
    try t.expect(std.mem.indexOf(u8, buck, "    cxx_toolchain = \"komira//tools/build/mojo:adopt_cxx_link_facts\",\n") != null);
    try t.expect(std.mem.indexOf(u8, buck, "# beta is in the closure and links C") != null);
    // c_deps stays out: the package owns no C
    try t.expect(std.mem.indexOf(u8, buck, "c_deps") == null or std.mem.indexOf(u8, buck, "names no `c_deps`") != null);
}

test "refuses a dependency whose native table is not static, or has no kind, even beside a static one" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try expectRefusal(a, try mini(a, .{ .beta_toml = beta_toml_text ++ "\n[native.shim]\nkind = \"shared\"\n" }), mini_options, "natives other than static");
    try expectRefusal(a, try mini(a, .{ .beta_toml = beta_toml_text ++ "\n[native.shim]\nsrcs = [\"native/shim.c\"]\n" }), mini_options, "natives other than static");
    try expectRefusal(a, try mini(a, .{ .beta_toml = beta_toml_text ++ "\n[native.one]\nkind = \"static\"\n\n[native.two]\nkind = \"shared\"\n" }), mini_options, "natives other than static");
}

test "refuses a package that declares natives itself, whatever its dependencies declare" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const static_beta = beta_toml_text ++ "\n[native.beta_shim]\nkind = \"static\"\n";
    try expectRefusal(a, try mini(a, .{ .beta_toml = static_beta, .extra = &.{.{ .path = "src/alpha/shim.c" }} }), mini_options, "a native source or library");
    try expectRefusal(a, try mini(a, .{ .beta_toml = static_beta, .buck = try buckWith(a, "    visibility", "    c_deps = [\":shim\"],\n    visibility") }), mini_options, "declares native code");
}

test "refuses a BUCK file it cannot read as data: a variable, a comprehension, an operator, a triple-quoted string" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try expectRefusal(a, try mini(a, .{ .buck = try std.mem.concat(a, u8, &.{ "DEPS = [\"//src/beta:beta\"]\n", mini_buck }) }), mini_options, "'DEPS' is not a call: an assignment or a variable");
    try expectRefusal(a, try mini(a, .{ .buck = try buckWith(a, "[\"//src/beta:beta\"]", "DEPS") }), mini_options, "the variable 'DEPS' used as a value");
    try expectRefusal(a, try mini(a, .{ .buck = try buckWith(a, "[\"//src/beta:beta\"]", "[d for d in DEPS]") }), mini_options, "a comprehension");
    try expectRefusal(a, try mini(a, .{ .buck = try buckWith(a, "[\"//src/beta:beta\"]", "[\"//src/beta:beta\"] + OTHER") }), mini_options, "an operator '+' between values");
    try expectRefusal(a, try mini(a, .{ .buck = try buckWith(a, "[\"//src/beta:beta\"]", "[\"\"\"//src/beta:beta\"\"\"]") }), mini_options, "a triple-quoted string");
}

test "refuses what the recipe does not cover: another rule, another load, another attribute, a different srcs" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try expectRefusal(a, try mini(a, .{ .buck = try std.mem.concat(a, u8, &.{ mini_buck, "\ngenrule(name = \"g\")\n" }) }), mini_options, "a call to genrule");
    try expectRefusal(a, try mini(a, .{ .buck = try std.mem.concat(a, u8, &.{ "load(\"//x:y.bzl\", \"z\")\n", mini_buck }) }), mini_options, "loads //x:y.bzl");
    try expectRefusal(a, try mini(a, .{ .buck = try buckWith(a, "    visibility", "    test_defines = [\"A=1\"],\n    visibility") }), mini_options, "the attribute 'test_defines' of mojo_library is not covered");
    try expectRefusal(a, try mini(a, .{ .buck = try buckWith(a, "glob([\"**/*.mojo\"], exclude = [\"tests/**/*.mojo\"])", "[\"__init__.mojo\"]") }), mini_options, "srcs is not glob");
    try expectRefusal(a, try mini(a, .{ .buck = try buckWith(a, "[\"PUBLIC\"]", "[\"//src/...\"]") }), mini_options, "visibility is not");
}

test "refuses deps that disagree with the imports, in both directions" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try expectRefusal(a, try mini(a, .{ .init = "from std.memory import memcpy\n" }), mini_options, "deps lists 'beta' but no library source imports it");
    const extra = [_]plan.File{
        .{ .path = "src/gamma/BUCK", .text = migrated_buck },
        .{ .path = "src/gamma/mopm.toml", .text = beta_toml_text },
    };
    try expectRefusal(a, try mini(a, .{ .init = "from beta import thing\nfrom gamma import more\n", .extra = &extra }), mini_options, "the library sources import 'gamma' but deps does not list it");
}

test "refuses a test_srcs list that is not the tests/test_*.mojo files" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try expectRefusal(a, try mini(a, .{ .extra = &.{.{ .path = "src/alpha/tests/test_more.mojo", .text = "" }} }), mini_options, "'tests/test_more.mojo' is not in test_srcs");
    try expectRefusal(a, try mini(a, .{ .buck = try buckWith(a, "[\"tests/test_alpha.mojo\"]", "[\"tests/test_alpha.mojo\", \"tests/test_gone.mojo\"]") }), mini_options, "lists 'tests/test_gone.mojo'");
}

test "refuses test_data with no stated layout, and a test-only dependency without the flag" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const with_data = try buckWith(a, "    visibility", "    test_data = {\"tests/test_alpha.mojo\": {\"a.txt\": \"a.txt\"}},\n    visibility");
    try expectRefusal(a, try mini(a, .{ .buck = with_data }), mini_options, "Pass --test-layout=installed");
    const p = try planOf(a, try mini(a, .{ .buck = with_data }), .{ .package = "alpha", .description = "A library.", .mopm = repo_mopm, .test_layout = "installed" });
    try t.expect(std.mem.indexOf(u8, try writeOf(p, "src/alpha/BUCK"), "    test_data = {\"tests/test_alpha.mojo\": {\"a.txt\": \"a.txt\"}},\n    test_layout = \"installed\",\n") != null);

    const extra = [_]plan.File{
        .{ .path = "src/gamma/BUCK", .text = migrated_buck },
        .{ .path = "src/gamma/mopm.toml", .text = beta_toml_text },
    };
    const dev_buck = try buckWith(a, "    visibility", "    test_deps = [\"//src/gamma:gamma\"],\n    visibility");
    const dev_test = "from alpha import x\nfrom gamma import y\n";
    try expectRefusal(a, try mini(a, .{ .buck = dev_buck, .test_src = dev_test, .extra = &extra }), mini_options, "[dev-dependencies] entry");
    const q = try planOf(a, try mini(a, .{ .buck = dev_buck, .test_src = dev_test, .extra = &extra }), .{ .package = "alpha", .description = "A library.", .mopm = repo_mopm, .dev_dependencies = true });
    try t.expect(std.mem.indexOf(u8, try writeOf(q, "src/alpha/mopm.toml"), "[dev-dependencies]\ngamma = { path = \"../gamma\", version = \"0.1\" }\n") != null);
}

test "refuses a static-native dependency that only the tests reach, and accepts it when the library reaches it too" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const native_toml = beta_toml_text ++ "\n[native.gamma_shim]\nkind = \"static\"\n";
    const extra = [_]plan.File{
        .{ .path = "src/gamma/BUCK", .text = migrated_buck },
        .{ .path = "src/gamma/mopm.toml", .text = native_toml },
    };
    const dev_buck = try buckWith(a, "    visibility", "    test_deps = [\"//src/gamma:gamma\"],\n    visibility");
    const dev_test = "from alpha import x\nfrom gamma import y\n";
    const o = plan.Options{ .package = "alpha", .description = "A library.", .mopm = repo_mopm, .dev_dependencies = true };
    try expectRefusal(a, try mini(a, .{ .buck = dev_buck, .test_src = dev_test, .extra = &extra }), o, "reached only through [dev-dependencies]");
    // the same package, imported by the library as well: a library dependency, accepted
    const both_buck = try buckWith(a, "    deps = [\"//src/beta:beta\"],", "    deps = [\"//src/beta:beta\", \"//src/gamma:gamma\"],");
    const p = try planOf(a, try mini(a, .{ .buck = both_buck, .init = "from beta import thing\nfrom gamma import y\n", .extra = &extra }), o);
    try t.expect(std.mem.indexOf(u8, try writeOf(p, "src/alpha/BUCK"), "# gamma is in the closure and links C") != null);
}

test "refuses what is already done or in the way: migrated, src/ present, generated/, a row already listed, no description" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try expectRefusal(a, try mini(a, .{ .extra = &.{.{ .path = "src/alpha/mopm.toml", .text = "" }} }), mini_options, "is migrated already");
    try expectRefusal(a, try mini(a, .{ .extra = &.{.{ .path = "src/alpha/src/x.mojo", .text = "" }} }), mini_options, "src/alpha/src exists");
    try expectRefusal(a, try mini(a, .{ .extra = &.{.{ .path = "src/alpha/generated/alpha/x.mojo", .text = "" }} }), mini_options, "generated sources are not a plain migration");
    try expectRefusal(a, try mini(a, .{ .readme = null }), mini_options, "README.md not found");
    try expectRefusal(a, try mini(a, .{ .readme = "# a\n\n## Build files\n" }), mini_options, "has a 'Build files' section already");
    try expectRefusal(a, try mini(a, .{}), .{ .package = "alpha", .description = "", .mopm = repo_mopm }, "--description is required");
    try expectRefusal(a, try mini(a, .{}), .{ .package = "Alpha!", .description = "d", .mopm = repo_mopm }, "is not a package name");
    try expectRefusal(a, try mini(a, .{}), .{ .package = "missing", .description = "d", .mopm = repo_mopm }, "not found: src/missing is not a package");
}

test "an import list counts every module: a dependency named second is found, and a from list names one module" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // beta appears only second in a comma list, and the BUCK file does not list it: refused.
    const buck = try buckWith(a, "    deps = [\"//src/beta:beta\"],\n", "");
    try expectRefusal(a, try mini(a, .{ .buck = buck, .init = "import std.sys, beta\n" }), mini_options, "the library sources import 'beta' but deps does not list it");
    try expectRefusal(a, try mini(a, .{ .buck = buck, .init = "import std.sys as s, beta.inner as b\n" }), mini_options, "the library sources import 'beta' but deps does not list it");
    // the same through a test file
    try expectRefusal(a, try mini(a, .{ .test_src = "from alpha import x\nimport std.testing, gamma\n" }), mini_options, "imports 'gamma', which maps to no known package");
    // a name after `from m import` is not a module
    const p = try planOf(a, try mini(a, .{ .buck = buck, .init = "from std.sys import beta, gamma\n" }), mini_options);
    try t.expect(std.mem.indexOf(u8, try writeOf(p, "src/alpha/mopm.toml"), "[dependencies]") == null);
}

test "the scanner reads every module of an import list" {
    var ar = arena();
    defer ar.deinit();
    var out = std.ArrayList([]const u8).empty;
    var bad = imp.Bad{};
    try imp.scan(ar.allocator(), "import std.sys, komira_resources\nimport a as x, b.c, d\nfrom m import n, o\n", &out, &bad);
    const want = [_][]const u8{ "std", "komira_resources", "a", "b", "d", "m" };
    try t.expectEqual(want.len, out.items.len);
    for (want, out.items) |w, g| try t.expectEqualStrings(w, g);
    var out2 = std.ArrayList([]const u8).empty;
    try t.expectError(error.BadImport, imp.scan(ar.allocator(), "x = 1\nimport std.sys, 5\n", &out2, &bad));
    try t.expectEqual(@as(usize, 2), bad.line);
}

test "the plan does not edit ci/targets: no write for it, and the farm step names the generator for the layout" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const p = try planOf(a, try mini(a, .{}), mini_options);
    for (p.writes) |w| try t.expect(std.mem.indexOf(u8, w.path, "ci/targets") == null);
    var single: ?[]const u8 = null;
    for (p.farm) |f| if (std.mem.indexOf(u8, f, "targets.bxl:generate") != null) {
        single = f;
    };
    try t.expect(single != null);
    try t.expect(std.mem.indexOf(u8, single.?, "> ci/targets.bzl") != null);
    // the sharded layout: the same plan, the copy form
    const sharded = try planOf(a, try mini(a, .{ .extra = &.{.{ .path = "ci/targets/shard_0.bzl", .text = "TARGETS = []\n" }} }), mini_options);
    var copy: ?[]const u8 = null;
    for (sharded.farm) |f| if (std.mem.indexOf(u8, f, "targets.bxl:generate") != null) {
        copy = f;
    };
    try t.expect(copy != null);
    try t.expect(std.mem.indexOf(u8, copy.?, "cp -rL --no-preserve=mode") != null);
    // The copy runs only when the generator printed an existing directory that is not `/`: an
    // empty output would make the bare form copy `/` into ci/.
    try t.expect(std.mem.indexOf(u8, copy.?, "out=$(./buck2 bxl komira//tools/build/ci/targets.bxl:generate) && [ -d \"$out\" ] && [ \"$out\" != / ] && cp -rL --no-preserve=mode \"$out\"/. ci/") != null);
    try t.expect(std.mem.indexOf(u8, copy.?, "\"$(./buck2") == null);
    try t.expect(std.mem.indexOf(u8, copy.?, "> ci/targets.bzl") == null);
    for (sharded.writes) |w| try t.expect(std.mem.indexOf(u8, w.path, "ci/targets") == null);
}

test "refuses a library that loads a shared library at run time, and ignores the name in a comment" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try expectRefusal(a, try mini(a, .{ .extra = &.{.{ .path = "src/alpha/ffi.mojo", .text = "from std.ffi import OwnedDLHandle\n\nfn f():\n    var h = OwnedDLHandle(\"libx.so\")\n" }} }), mini_options, "src/alpha/ffi.mojo:1: uses DLHandle");
    try expectRefusal(a, try mini(a, .{ .extra = &.{.{ .path = "src/alpha/ffi.mojo", .text = "fn f():\n    var h = DLHandle(\"libx.so\")\n" }} }), mini_options, "src/alpha/ffi.mojo:2: uses DLHandle");
    try expectRefusal(a, try mini(a, .{ .test_src = "from alpha import x\nvar h = OwnedDLHandle(\"l\")\n" }), mini_options, "uses DLHandle");
    const ok = try planOf(a, try mini(a, .{ .extra = &.{.{ .path = "src/alpha/doc.mojo", .text = "# no DLHandle here\n\"\"\"\nOwnedDLHandle in a docstring\n\"\"\"\nfn f(): pass\n" }} }), mini_options);
    try t.expectEqual(@as(usize, 2), ok.moves.len);
}

test "warns when the kept header comment says there are no dependencies and there are some" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const claim = try std.mem.replaceOwned(u8, a, mini_buck, "mojo_library(\n", "# Alpha has no dependencies beyond std.\nmojo_library(\n");
    const p = try planOf(a, try mini(a, .{ .buck = claim }), mini_options);
    var warned = false;
    for (p.notes) |n| warned = warned or std.mem.indexOf(u8, n, "says the package has no dependencies, and it has some") != null;
    try t.expect(warned);
    // no dependency: the same words are true, and nothing is said
    const buck = try std.mem.replaceOwned(u8, a, claim, "    deps = [\"//src/beta:beta\"],\n", "");
    const q = try planOf(a, try mini(a, .{ .buck = buck, .init = "from std.memory import memcpy\n" }), mini_options);
    for (q.notes) |n| try t.expect(std.mem.indexOf(u8, n, "no dependencies") == null);
}

// ---- the BUCK reader ----------------------------------------------------------------------------

test "the reader keeps the text of every value and attaches the comment directly above a call" {
    var ar = arena();
    defer ar.deinit();
    var c = sl.Ctx{ .a = ar.allocator() };
    const src =
        \\# detached
        \\
        \\# attached one
        \\# attached two
        \\rule(
        \\    name = "x",
        \\    deps = [
        \\        "//a:a",  # trailing
        \\    ],
        \\    data = {"k": {"n": 1}},
        \\)
        \\
    ;
    const stmts = try sl.parse(&c, src);
    try t.expectEqual(@as(usize, 1), stmts.len);
    try t.expectEqualStrings("# attached one\n# attached two", stmts[0].comment);
    try t.expectEqual(@as(usize, 5), stmts[0].line);
    const deps = stmts[0].call.kwarg("deps").?;
    try t.expectEqualStrings("[\n        \"//a:a\",  # trailing\n    ]", deps.text(src));
    try t.expectEqualStrings("{\"k\": {\"n\": 1}}", stmts[0].call.kwarg("data").?.text(src));
}

test "the reader refuses a def, a bad escape and a call with trailing text" {
    var ar = arena();
    defer ar.deinit();
    var c = sl.Ctx{ .a = ar.allocator() };
    try t.expectError(error.Refused, sl.parse(&c, "def f():\n    pass\n"));
    try t.expect(std.mem.indexOf(u8, c.why, "the statement 'def'") != null);
    try t.expectError(error.Refused, sl.parse(&c, "rule(name = \"a\\qb\")\n"));
    try t.expect(std.mem.indexOf(u8, c.why, "the escape \\q") != null);
    try t.expectError(error.Refused, sl.parse(&c, "rule(name = \"a\") rule(name = \"b\")\n"));
    try t.expect(std.mem.indexOf(u8, c.why, "text after the call to rule") != null);
}

// ---- the import scanner -------------------------------------------------------------------------

test "imports count in code, indented or not; docstrings, comments and relative imports do not" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\"""A module.
        \\
        \\from fake_in_docstring import x
        \\"""
        \\# from fake_in_comment import y
        \\from std.memory import memcpy
        \\from komira_hash import fnv
        \\import komira_json
        \\from . import sibling
        \\
        \\def f():
        \\    from komira_zlib.inner import z
        \\    var s = """
        \\import fake_in_string
        \\"""
        \\
    ;
    var out = std.ArrayList([]const u8).empty;
    var bad = imp.Bad{};
    try imp.scan(a, src, &out, &bad);
    try t.expectEqual(@as(usize, 4), out.items.len);
    try t.expectEqualStrings("std", out.items[0]);
    try t.expectEqualStrings("komira_hash", out.items[1]);
    try t.expectEqualStrings("komira_json", out.items[2]);
    try t.expectEqualStrings("komira_zlib", out.items[3]);
}

test "a from line that names no module outside a string is an error with its line" {
    var ar = arena();
    defer ar.deinit();
    var out = std.ArrayList([]const u8).empty;
    var bad = imp.Bad{};
    try t.expectError(error.BadImport, imp.scan(ar.allocator(), "x = 1\nfrom 5,000 pieces import y\n", &out, &bad));
    try t.expectEqual(@as(usize, 2), bad.line);
}

// ---- the command: dry run and a real run on a scratch tree ----------------------------------------

fn writeTree(dir: std.fs.Dir, files: []const plan.File) !void {
    for (files) |f| {
        if (std.fs.path.dirname(f.path)) |d| try dir.makePath(d);
        try dir.writeFile(.{ .sub_path = f.path, .data = f.text orelse "" });
    }
}

/// Every file of `dir` with its bytes, in path order, as one string.
fn snapshot(a: std.mem.Allocator, dir: std.fs.Dir) ![]u8 {
    var entries = std.ArrayList([]const u8).empty;
    var w = try dir.walk(a);
    defer w.deinit();
    while (try w.next()) |e| {
        if (e.kind != .file) continue;
        const bytes = try dir.readFileAlloc(a, e.path, 1 << 20);
        try entries.append(a, try std.fmt.allocPrint(a, "{s}\x00{s}\x00", .{ e.path, bytes }));
    }
    std.mem.sort([]const u8, entries.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    return std.mem.concat(a, u8, entries.items);
}

test "a dry run prints the whole plan and writes nothing" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeTree(tmp.dir, try mini(a, .{ .extra = &.{.{ .path = "src/alpha/helper.mojo", .text = "" }} }));
    const before = try snapshot(a, tmp.dir);

    var out = std.Io.Writer.Allocating.init(a);
    var c = plan.Ctx{ .a = a };
    try mm.run(a, &c, tmp.dir, .{ .plan = mini_options, .dry_run = true, .use_git = false }, &out.writer);

    const text = out.written();
    try t.expect(std.mem.indexOf(u8, text, "dry run: nothing is written") != null);
    try t.expect(std.mem.indexOf(u8, text, "git mv src/alpha/__init__.mojo src/alpha/src/alpha/__init__.mojo") != null);
    try t.expect(std.mem.indexOf(u8, text, "git mv src/alpha/helper.mojo src/alpha/src/alpha/helper.mojo") != null);
    try t.expect(std.mem.indexOf(u8, text, "create src/alpha/mopm.toml") != null);
    try t.expect(std.mem.indexOf(u8, text, "edit src/alpha/BUCK") != null);
    try t.expect(std.mem.indexOf(u8, text, "bxl komira//tools/build/ci/targets.bxl:generate") != null);
    try t.expect(std.mem.indexOf(u8, text, "left to the farm") != null);
    try expectSameBytes("the tree after a dry run", before, try snapshot(a, tmp.dir));
}

test "a refused run writes nothing even though it printed no plan" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeTree(tmp.dir, try mini(a, .{ .init = "from beta import thing\nfrom gamma import other\n" }));
    const before = try snapshot(a, tmp.dir);
    var out = std.Io.Writer.Allocating.init(a);
    var c = plan.Ctx{ .a = a };
    try t.expectError(error.Refused, mm.run(a, &c, tmp.dir, .{ .plan = mini_options, .dry_run = false, .use_git = false }, &out.writer));
    try t.expectEqual(@as(usize, 0), out.written().len);
    try expectSameBytes("the tree after a refusal", before, try snapshot(a, tmp.dir));
}

test "a real run moves the library, writes the files and a second run refuses" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeTree(tmp.dir, try mini(a, .{}));
    var out = std.Io.Writer.Allocating.init(a);
    var c = plan.Ctx{ .a = a };
    try mm.run(a, &c, tmp.dir, .{ .plan = mini_options, .dry_run = false, .use_git = false }, &out.writer);

    try t.expectError(error.FileNotFound, tmp.dir.access("src/alpha/__init__.mojo", .{}));
    try tmp.dir.access("src/alpha/src/alpha/__init__.mojo", .{});
    try tmp.dir.access("src/alpha/tests/test_alpha.mojo", .{});
    const toml = try tmp.dir.readFileAlloc(a, "src/alpha/mopm.toml", 1 << 20);
    try t.expect(std.mem.startsWith(u8, toml, "[package]\nname = \"alpha\"\n"));
    const buck = try tmp.dir.readFileAlloc(a, "src/alpha/BUCK", 1 << 20);
    try t.expect(std.mem.indexOf(u8, buck, "mojo_package(path = \".\")") != null);
    try t.expect(std.mem.indexOf(u8, buck, "mojo_library") == null);
    const packages = try tmp.dir.readFileAlloc(a, "release/readme_e2e/packages.bzl", 1 << 20);
    try t.expect(std.mem.indexOf(u8, packages, "\"alpha\": \"0.1.0\",") != null);

    var c2 = plan.Ctx{ .a = a };
    try t.expectError(error.Refused, mm.run(a, &c2, tmp.dir, .{ .plan = mini_options, .dry_run = false, .use_git = false }, &out.writer));
    try t.expect(std.mem.indexOf(u8, c2.why, "is migrated already") != null);
}

test "a file git does not track refuses the run before anything moves" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // helper.mojo sorts after __init__.mojo, so an unguarded run moves __init__.mojo first.
    try writeTree(tmp.dir, try mini(a, .{ .extra = &.{.{ .path = "src/alpha/helper.mojo", .text = "" }} }));
    const before = try snapshot(a, tmp.dir);
    const tracked = [_][]const u8{ "src/alpha/BUCK", "src/alpha/README.md", "src/alpha/__init__.mojo", "src/alpha/tests/test_alpha.mojo" };
    var out = std.Io.Writer.Allocating.init(a);
    var c = plan.Ctx{ .a = a };
    try t.expectError(error.Refused, mm.run(a, &c, tmp.dir, .{ .plan = mini_options, .dry_run = false, .use_git = false, .tracked = &tracked }, &out.writer));
    try t.expect(std.mem.indexOf(u8, c.why, "src/alpha/helper.mojo is not tracked by git") != null);
    try t.expectEqual(@as(usize, 0), out.written().len);
    try expectSameBytes("the tree after the refusal", before, try snapshot(a, tmp.dir));
    // the dry run refuses too
    var c2 = plan.Ctx{ .a = a };
    try t.expectError(error.Refused, mm.run(a, &c2, tmp.dir, .{ .plan = mini_options, .dry_run = true, .use_git = false, .tracked = &tracked }, &out.writer));
    // everything tracked: the run goes through
    const all = tracked ++ [_][]const u8{"src/alpha/helper.mojo"};
    var c3 = plan.Ctx{ .a = a };
    try mm.run(a, &c3, tmp.dir, .{ .plan = mini_options, .dry_run = false, .use_git = false, .tracked = &all }, &out.writer);
    try tmp.dir.access("src/alpha/src/alpha/helper.mojo", .{});
}

fn parsed(args: []const []const u8, why: *std.ArrayList(u8), a: std.mem.Allocator) !?mm.Parsed {
    return mm.parseArgs(args, a, why);
}

test "the command line: --mopm is required, the tool has no default version" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var why: std.ArrayList(u8) = .empty;
    const r = try parsed(&.{ "mopm_migrate", "--package", "alpha", "--description", "A library." }, &why, a);
    try t.expect(r == null);
    try t.expect(std.mem.indexOf(u8, why.items, "--mopm is required") != null);
}

test "the command line: the migrated output names the version --mopm gives" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var why: std.ArrayList(u8) = .empty;
    const r = (try parsed(&.{ "mopm_migrate", "--package", "alpha", "--description", "A library.", "--mopm", repo_mopm }, &why, a)).?;
    try t.expectEqualStrings(repo_mopm, r.plan.mopm);
    const p = try planOf(a, try mini(a, .{}), r.plan);
    try t.expect(std.mem.indexOf(u8, try writeOf(p, "src/alpha/mopm-toolchain.toml"), "mopm = \"0.0.86\"") != null);
    try t.expect(std.mem.indexOf(u8, try writeOf(p, "src/alpha/BUCK"), "toolchains//:mopm_0_0_86") != null);
    try t.expect(std.mem.indexOf(u8, try writeOf(p, "src/alpha/mopm-toolchain.toml"), "0.0.73") == null);
}
