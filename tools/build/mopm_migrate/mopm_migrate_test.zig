//! The cases of mopm_migrate (mopm_migrate.zig, plan.zig). Each test is a defect a migration would
//! otherwise carry into the tree: a manifest that differs from the hand-written one, a dependency
//! guessed from a BUCK file that disagrees with the sources, a shared row inserted out of order,
//! a plan that writes before it has refused, or a dry run that writes.
//!
//! The golden case runs the tool on the tree komira_resources had before its hand migration
//! (fixtures/komira_resources/old: the files as they were, with the BUCK file and manifest of the one
//! dependency) and requires the hand migration's files: `mopm.toml`, `mopm-toolchain.toml` and
//! `mopm.lock` byte for byte, the three shared rows files as the line-for-line diff the hand
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
fn normalize(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var para = std.ArrayList(u8).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "#")) {
            var words = std.mem.tokenizeAny(u8, line[1..], " \t");
            var any = false;
            while (words.next()) |w| {
                any = true;
                try para.append(a, ' ');
                try para.appendSlice(a, w);
            }
            if (any) continue;
        }
        if (para.items.len > 0) {
            try out.append(a, '#');
            try out.appendSlice(a, para.items);
            try out.append(a, '\n');
            para.clearRetainingCapacity();
        }
        if (std.mem.startsWith(u8, line, "#")) {
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
    const targets_before = @embedFile("fixtures/komira_resources/rows/targets.before.bzl");
    const targets_diff = @embedFile("fixtures/komira_resources/rows/targets.diff");
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
        .{ .path = "ci/targets.bzl", .text = fx.targets_before },
    };
}

const resources_options = plan.Options{
    .package = "komira_resources",
    .description = resources_description,
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

test "golden: the three shared rows files get the lines the hand migration added, in the same places" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const p = try planOf(a, resourcesTree(), resources_options);
    try expectRowsAsDiff(a, "release/readme_e2e/packages.bzl", fx.packages_before, try writeOf(p, "release/readme_e2e/packages.bzl"), fx.packages_diff);
    try expectRowsAsDiff(a, "release/mopm_native_ids.bzl", fx.ids_before, try writeOf(p, "release/mopm_native_ids.bzl"), fx.ids_diff);
    try expectRowsAsDiff(a, "ci/targets.bzl", fx.targets_before, try writeOf(p, "ci/targets.bzl"), fx.targets_diff);
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
const rows_targets =
    \\TARGETS = [
    \\    "komira//src/beta:ci",
    \\    "komira//src/zeta:ci",
    \\]
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
    try files.append(a, .{ .path = "ci/targets.bzl", .text = rows_targets });
    try files.appendSlice(a, m.extra);
    return files.toOwnedSlice(a);
}

const mini_options = plan.Options{ .package = "alpha", .description = "A library." };

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
    try expectSameBytes("targets", "TARGETS = [\n    \"komira//src/alpha:ci\",\n    \"komira//src/alpha:conda_holds\",\n    \"komira//src/alpha:coverage_floor\",\n    \"komira//src/alpha:table\",\n    \"komira//src/beta:ci\",\n    \"komira//src/zeta:ci\",\n]\n", try writeOf(p, "ci/targets.bzl"));
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
    try t.expect(std.mem.indexOf(u8, try writeOf(p, "ci/targets.bzl"), "alpha:conda_holds") == null);
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
    try expectRefusal(a, try mini(a, .{ .beta_toml = beta_toml_text ++ "\n[native.lz4]\nkind = \"static\"\n" }), mini_options, "declares natives");
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
    const p = try planOf(a, try mini(a, .{ .buck = with_data }), .{ .package = "alpha", .description = "A library.", .test_layout = "installed" });
    try t.expect(std.mem.indexOf(u8, try writeOf(p, "src/alpha/BUCK"), "    test_data = {\"tests/test_alpha.mojo\": {\"a.txt\": \"a.txt\"}},\n    test_layout = \"installed\",\n") != null);

    const extra = [_]plan.File{
        .{ .path = "src/gamma/BUCK", .text = migrated_buck },
        .{ .path = "src/gamma/mopm.toml", .text = beta_toml_text },
    };
    const dev_buck = try buckWith(a, "    visibility", "    test_deps = [\"//src/gamma:gamma\"],\n    visibility");
    const dev_test = "from alpha import x\nfrom gamma import y\n";
    try expectRefusal(a, try mini(a, .{ .buck = dev_buck, .test_src = dev_test, .extra = &extra }), mini_options, "[dev-dependencies] entry");
    const q = try planOf(a, try mini(a, .{ .buck = dev_buck, .test_src = dev_test, .extra = &extra }), .{ .package = "alpha", .description = "A library.", .dev_dependencies = true });
    try t.expect(std.mem.indexOf(u8, try writeOf(q, "src/alpha/mopm.toml"), "[dev-dependencies]\ngamma = { path = \"../gamma\", version = \"0.1\" }\n") != null);
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
    try expectRefusal(a, try mini(a, .{}), .{ .package = "alpha", .description = "" }, "--description is required");
    try expectRefusal(a, try mini(a, .{}), .{ .package = "Alpha!", .description = "d" }, "is not a package name");
    try expectRefusal(a, try mini(a, .{}), .{ .package = "missing", .description = "d" }, "not found: src/missing is not a package");
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
    try t.expect(std.mem.indexOf(u8, text, "+     \"komira//src/alpha:table\",") != null);
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
