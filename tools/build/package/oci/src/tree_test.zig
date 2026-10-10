//! The tree's refusals and its laying out (tree.zig).

const std = @import("std");
const C = @import("common.zig");
const R = @import("tree.zig");
const F = @import("tar_fixture.zig");
const D = @import("fs_fixture.zig");

const Place = R.Place;
const eqs = std.testing.expectEqualStrings;

fn places(bundles: []const []const u8, files: []const []const u8) []Place {
    var out = C.list(Place);
    for (bundles) |p| C.push(Place, &out, .{ .path = p, .src = C.fmt("src-of-{s}", .{p}), .bundle = true });
    for (files) |p| C.push(Place, &out, .{ .path = p, .src = C.fmt("src-of-{s}", .{p}), .bundle = false });
    return out.items;
}

fn refusals(bundles: []const []const u8, files: []const []const u8) ![]const []const u8 {
    const given = places(bundles, files);
    switch (R.plan(given)) {
        .plan => |p| {
            // An accepted plan holds the places as given.
            try std.testing.expectEqual(given.len, p.places.len);
            for (given, p.places) |g, q| {
                try eqs(g.path, q.path);
                try eqs(g.src, q.src);
                try std.testing.expectEqual(g.bundle, q.bundle);
            }
            return &.{};
        },
        .refused => |r| return r,
    }
}

fn strs(want: []const []const u8, got: []const []const u8) !void {
    if (want.len != got.len) {
        std.debug.print("want {d} lines, got {d}:\n", .{ want.len, got.len });
        for (got) |g| std.debug.print("  {s}\n", .{g});
        return error.TestUnexpectedResult;
    }
    for (want, got) |w, g| try eqs(w, g);
}

test "tree: the_base_images_tree_is_accepted" {
    try strs(&.{}, try refusals(&.{ "komira/", "opt/kci/" }, &.{"bin/sh"}));
    try strs(&.{}, try refusals(&.{ "komira/", "komira2/" }, &.{ "bin/sh", "bin/sh2", "bin/s" }));
    try strs(&.{}, try refusals(&.{}, &.{ "etc/.wh.ssl", "etc/ssl/certs/.wh..wh..opq" }));
}

test "tree: a_path_inside_another_is_refused" {
    try strs(&.{"`komira/bin/supervisor` is inside `komira/`"}, try refusals(&.{"komira/"}, &.{"komira/bin/supervisor"}));
    try strs(&.{"`opt/kci/` is inside `opt/`"}, try refusals(&.{ "opt/", "opt/kci/" }, &.{}));
    try strs(&.{"`a/b` is inside `a`"}, try refusals(&.{}, &.{ "a", "a/b" }));
    try strs(&.{"`bin/` is inside `bin`"}, try refusals(&.{"bin/"}, &.{"bin"}));
    try strs(&.{"`a` given twice"}, try refusals(&.{}, &.{ "a", "a" }));
}

test "tree: a_path_given_twice_apart_is_refused" {
    // The twice check compares neighbours after sorting, so a pair with
    // another path between them is found only if the paths are sorted.
    try strs(&.{"`a` given twice"}, try refusals(&.{}, &.{ "a", "b", "a" }));
    try strs(&.{"`a/` given twice"}, try refusals(&.{ "a/", "b/", "a/" }, &.{}));
    try strs(&.{"`z` given twice"}, try refusals(&.{"k/"}, &.{ "z", "c", "z" }));
}

test "tree: plain_is_letters_digits_and_four_marks" {
    try strs(&.{}, try refusals(&.{"A_b+c-d.9/"}, &.{"x/A_b+c-d.9"}));
    for ([_][]const u8{ "a:b", "a*b", "a\\b", "a b", "\u{e9}", "a=b" }) |bad| {
        try strs(&.{C.fmt("file path `{s}` must be a plain relative path", .{bad})}, try refusals(&.{}, &.{bad}));
    }
}

fn at(p: []const u8, src: []const u8, bundle: bool) Place {
    return .{ .path = p, .src = src, .bundle = bundle };
}

fn planOf(given: []const Place) !R.Plan {
    return switch (R.plan(C.a().dupe(Place, given) catch C.oom())) {
        .plan => |p| p,
        .refused => |r| {
            for (r) |x| std.debug.print("refused: {s}\n", .{x});
            return error.TestUnexpectedResult;
        },
    };
}

test "tree: lay_copies_with_plain_modes" {
    const d = D.scratch("tree", "lay");
    const src = D.path(d, "src");
    D.mkdirAll(D.path(src, "b/sub"));
    const files = [_]struct { []const u8, u32 }{ .{ "exe", 0o700 }, .{ "ro", 0o400 }, .{ "b/sub/f", 0o600 }, .{ "b/g", 0o610 }, .{ "b/o", 0o601 } };
    for (files) |f| D.writeMode(D.path(src, f[0]), f[0], f[1]);
    const p = try planOf(&.{ at("bin/exe", D.path(src, "exe"), false), at("bin/ro", D.path(src, "ro"), false), at("opt/b/", D.path(src, "b"), true) });
    const out = D.path(d, "out");
    try F.ok(R.lay(out, p));
    const modes = [_]struct { []const u8, u32 }{
        .{ "", 0o755 },        .{ "bin", 0o755 },       .{ "bin/exe", 0o755 },     .{ "bin/ro", 0o644 },
        .{ "opt", 0o755 },     .{ "opt/b", 0o755 },     .{ "opt/b/sub", 0o755 },   .{ "opt/b/sub/f", 0o644 },
        .{ "opt/b/g", 0o755 }, .{ "opt/b/o", 0o755 },
    };
    for (modes) |m| {
        if (D.modeOf(D.path(out, m[0])) != m[1]) {
            std.debug.print("{s}: mode {o}, want {o}\n", .{ m[0], D.modeOf(D.path(out, m[0])), m[1] });
            return error.TestUnexpectedResult;
        }
    }
    try eqs("b/sub/f", D.read(D.path(out, "opt/b/sub/f")));
    try F.expectFailPrefix(R.lay(out, p), C.fmt("cannot create {s}: ", .{out}));
    // A bundle whose one file is in its first directory, an empty one
    // after it: it holds a file all the same.
    const nested = D.path(d, "nested");
    D.mkdirAll(D.path(nested, "a"));
    D.mkdirAll(D.path(nested, "b"));
    D.write(D.path(nested, "a/f"), "f");
    try F.ok(R.lay(D.path(d, "out2"), try planOf(&.{at("n/", nested, true)})));
    try eqs("f", D.read(D.path(d, "out2/n/a/f")));
}

fn laid(d: []const u8, name: []const u8, place: Place) C.Fail!void {
    const p = planOf(&.{place}) catch unreachable;
    return R.lay(D.path(d, name), p);
}

test "tree: lay_refuses_what_it_cannot_copy" {
    const d = D.scratch("tree", "refuse");
    D.mkdirAll(D.path(d, "empty/sub"));
    D.mkdir(D.path(d, "linky"));
    D.symlink("x", D.path(d, "linky/l"));
    try F.expectFail(laid(d, "o1", at("e/", D.path(d, "empty"), true)), C.fmt("bundle {s} holds no files", .{D.path(d, "empty")}));
    try F.expectFail(laid(d, "o2", at("l/", D.path(d, "linky"), true)), C.fmt("{s}: not a regular file or directory", .{D.path(d, "linky/l")}));
    try F.expectFail(laid(d, "o3", at("f", D.path(d, "empty"), false)), C.fmt("{s}: not a regular file", .{D.path(d, "empty")}));
    try F.expectFailPrefix(laid(d, "o4", at("f", D.path(d, "missing"), false)), C.fmt("cannot read {s}: ", .{D.path(d, "missing")}));
    // What a plan never asks for: a file over one already laid, a
    // directory through a file.
    D.write(D.path(d, "x"), "x");
    try F.expectFail(R.copyFile(D.path(d, "x"), D.path(d, "x")), C.fmt("{s}: already in the tree", .{D.path(d, "x")}));
    try F.expectFail(R.mkdirs(d, "x/y"), C.fmt("{s}: not a directory", .{D.path(d, "x")}));
    try F.ok(R.mkdirs(d, "empty/sub/new"));
    try std.testing.expectEqual(@as(u32, 0o755), D.modeOf(D.path(d, "empty/sub/new")));
    // Names are read in sorted order, so of many it cannot copy the
    // first by name is the one named.
    D.mkdir(D.path(d, "links"));
    var i: usize = 50;
    while (i > 0) {
        i -= 1;
        D.symlink("x", D.path(d, C.fmt("links/{d:0>2}", .{i})));
    }
    try F.expectFail(laid(d, "o5", at("k/", D.path(d, "links"), true)), C.fmt("{s}: not a regular file or directory", .{D.path(d, "links/00")}));
}

test "tree: a_path_that_is_not_plain_is_refused" {
    try strs(&.{"bundle path `komira` must be a plain relative path ending in /"}, try refusals(&.{"komira"}, &.{}));
    try strs(&.{"file path `/bin/sh` must be a plain relative path"}, try refusals(&.{}, &.{"/bin/sh"}));
    try strs(&.{ "bundle path `a/../b/` must be a plain relative path ending in /", "file path `c/../d` must be a plain relative path" }, try refusals(&.{"a/../b/"}, &.{"c/../d"}));
    try strs(&.{"file path `./bin/sh` must be a plain relative path"}, try refusals(&.{}, &.{"./bin/sh"}));
    try strs(&.{"file path `bin/` must be a plain relative path"}, try refusals(&.{}, &.{"bin/"}));
    try strs(&.{ "bundle path `/` must be a plain relative path ending in /", "file path `a b` must be a plain relative path" }, try refusals(&.{"/"}, &.{"a b"}));
    try strs(&.{"an empty tree"}, try refusals(&.{}, &.{}));
}
