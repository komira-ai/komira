//! The image filesystem's cases (image.zig).

const std = @import("std");
const C = @import("common.zig");
const I = @import("image.zig");
const T = @import("tar.zig");
const F = @import("tar_fixture.zig");

const Fs = I.Fs;
const eqs = std.testing.expectEqualStrings;
const expect = std.testing.expect;

const CERT = "etc/ssl/certs/ca-certificates.crt";

/// A base like the pinned distroless one, as far as these checks go.
fn base() []T.Entry {
    return T.read(F.tar(&[_]F.E{
        .{ "./", '5', 0o755, "", "" },
        .{ "./etc/", '5', 0o755, "", "" },
        .{ "./etc/ssl/", '5', 0o755, "", "" },
        .{ "./etc/ssl/certs/", '5', 0o755, "", "" },
        .{ "./etc/ssl/certs/ca-certificates.crt", '0', 0o644, "PEM", "" },
        .{ "./etc/ssl/cert.pem", '2', 0o777, "", "certs/ca-certificates.crt" },
        .{ "./etc/os-release", '2', 0o777, "", "../usr/lib/os-release" },
        .{ "./usr/", '5', 0o755, "", "" },
        .{ "./usr/lib/", '5', 0o755, "", "" },
        .{ "./usr/lib/os-release", '0', 0o644, "ID=debian", "" },
        .{ "./usr/bin/", '5', 0o755, "", "" },
        .{ "./usr/bin/tool", '0', 0o755, "x", "" },
        .{ "./usr/bin/same", '1', 0o755, "", "usr/bin/tool" },
    })) catch unreachable;
}

const Img = struct { below: Fs, fs: Fs, layer: []T.Entry };

fn image(last: []const F.E) !Img {
    var below = Fs.init();
    try F.ok(below.apply(base()));
    const layer = try F.ok(T.read(F.tar(last)));
    var fs = Fs.init();
    try F.ok(fs.apply(base()));
    try F.ok(fs.apply(layer));
    return .{ .below = below, .fs = fs, .layer = layer };
}

fn wanted(w: I.Want, p: []const u8) I.Wanted {
    return .{ .want = w, .path = p };
}

/// The failures of checking the certificate bundle as a file.
fn certs(fs: *const Fs) [][]const u8 {
    return I.checkPaths(fs, &.{wanted(.file, CERT)}).bad;
}

fn strs(want: []const []const u8, got: []const []const u8) !void {
    if (want.len != got.len) {
        std.debug.print("want {d} lines, got {d}:\n", .{ want.len, got.len });
        for (got) |g| std.debug.print("  {s}\n", .{g});
        return error.TestUnexpectedResult;
    }
    for (want, got) |w, g| try eqs(w, g);
}

fn noKey(fs: *const Fs, pred: *const fn ([]const u8) bool) !void {
    var it = fs.nodes.keyIterator();
    while (it.next()) |k| {
        if (pred(k.*)) {
            std.debug.print("key {s}\n", .{k.*});
            return error.TestUnexpectedResult;
        }
    }
}

const FLOOR = [_]F.E{ .{ "bin/", '5', 0o755, "", "" }, .{ "bin/sh", '0', 0o755, "busybox", "" } };

test "image: control_image_is_green" {
    const m = try image(&FLOOR);
    try strs(&.{}, certs(&m.fs));
    const r = I.checkPaths(&m.fs, &.{ wanted(.exec, "bin/sh"), wanted(.exec, "/usr/bin/same"), wanted(.file, "etc/ssl/cert.pem") });
    try strs(&.{}, r.bad);
    try eqs("ok file etc/ssl/cert.pem -> etc/ssl/certs/ca-certificates.crt", r.ok[2]);
    try strs(&.{}, I.typeChanges(&m.below, m.layer));
}

test "image: a_directory_whiteout_removes_everything_under_it" {
    // etc/.wh.ssl removes etc/ssl, so etc/ssl/certs/... too.
    const m = try image(&.{ .{ "etc/", '5', 0o755, "", "" }, .{ "etc/.wh.ssl", '0', 0o644, "", "" } });
    try strs(&.{"file " ++ CERT ++ ": not in the image"}, certs(&m.fs));
    try noKey(&m.fs, struct {
        fn f(k: []const u8) bool {
            return C.startsWith(k, "etc/ssl");
        }
    }.f);
    try expect(m.fs.get("etc/os-release") != null);
}

test "image: an_opaque_whiteout_removes_the_children_below" {
    const m = try image(&.{ .{ "etc/ssl/certs/", '5', 0o755, "", "" }, .{ "etc/ssl/certs/.wh..wh..opq", '0', 0o644, "", "" } });
    try strs(&.{"file " ++ CERT ++ ": not in the image"}, certs(&m.fs));
    try std.testing.expectEqual(I.Type.dir, m.fs.get("etc/ssl/certs").?.ty);
    try expect(m.fs.get("etc/ssl/cert.pem") != null);
}

test "image: whiteouts_spare_their_own_layer_and_siblings" {
    // An opaque directory keeps what its own layer puts in it, in any
    // order; a whiteout of `cert` leaves `certs` alone.
    const m = try image(&.{
        .{ "etc/ssl/certs/ca-certificates.crt", '0', 0o644, "NEW", "" },
        .{ "etc/ssl/certs/.wh..wh..opq", '0', 0o644, "", "" },
        .{ "etc/ssl/.wh.cert", '0', 0o644, "", "" },
    });
    try strs(&.{}, certs(&m.fs));
    try std.testing.expectEqual(@as(u64, 3), m.fs.get(CERT).?.size);
    // The same whiteout in a layer that adds nothing back: `cert` names
    // no entry, and `certs/`, what is under it and `cert.pem` (names
    // starting with `cert`) all stay.
    const m2 = try image(&.{.{ "etc/ssl/.wh.cert", '0', 0o644, "", "" }});
    try strs(&.{}, certs(&m2.fs));
    try std.testing.expectEqual(@as(u64, 3), m2.fs.get(CERT).?.size);
    try std.testing.expectEqual(I.Type.dir, m2.fs.get("etc/ssl/certs").?.ty);
    try std.testing.expectEqual(I.Type.symlink, m2.fs.get("etc/ssl/cert.pem").?.ty);
    // A file whiteout: that one file goes.
    const m3 = try image(&.{.{ "etc/ssl/certs/.wh.ca-certificates.crt", '0', 0o644, "", "" }});
    try expect(certs(&m3.fs).len > 0);
    try expect(m3.fs.get("etc/ssl/certs") != null);
}

test "image: a_file_over_a_directory_hides_what_was_under_it" {
    const m = try image(&.{.{ "etc/ssl", '0', 0o644, "x", "" }});
    try expect(certs(&m.fs).len > 0);
    try strs(&.{"the last layer turns etc/ssl from type d into type -"}, I.typeChanges(&m.below, m.layer));
}

test "image: a_directory_over_a_symlink_is_a_type_change" {
    const m = try image(&.{ .{ "etc/os-release/", '5', 0o755, "", "" }, .{ "etc/os-release/x", '0', 0o644, "x", "" } });
    try strs(&.{"the last layer turns etc/os-release from type l into type d"}, I.typeChanges(&m.below, m.layer));
}

test "image: modes_and_types_are_checked" {
    const m = try image(&.{ .{ "bin/", '5', 0o755, "", "" }, .{ "bin/sh", '0', 0o644, "x", "" }, .{ "bin/e", '0', 0o644, "", "" }, .{ "bin/d/", '5', 0o755, "", "" } });
    const r = I.checkPaths(&m.fs, &.{ wanted(.exec, "bin/sh"), wanted(.file, "bin/e"), wanted(.exec, "bin/d"), wanted(.exec, "nope") });
    try strs(&.{}, r.ok);
    try strs(&.{
        "exec bin/sh: bin/sh has mode 644, want 755",
        "file bin/e: bin/e is empty",
        "exec bin/d: bin/d is of type d, not a regular file",
        "exec nope: not in the image",
    }, r.bad);
}

test "image: symlinks_resolve_through_directories_and_dot_dot" {
    const m = try image(&.{ .{ "lib", '2', 0o777, "", "usr/lib" }, .{ "abs", '2', 0o777, "", "/etc/os-release" }, .{ "loop", '2', 0o777, "", "loop" } });
    try eqs("usr/lib/os-release", try F.ok(m.fs.resolve("lib/os-release")));
    try eqs("usr/lib/os-release", try F.ok(m.fs.resolve("abs")));
    // An absolute target is read from /, not from the link's directory.
    const sub = try image(&.{.{ "usr/abs", '2', 0o777, "", "/etc/os-release" }});
    try eqs("usr/lib/os-release", try F.ok(sub.fs.resolve("usr/abs")));
    try eqs("usr/lib/os-release", try F.ok(m.fs.resolve("/etc/../../etc/./os-release")));
    // An empty component, in the path or in a link's target, is none.
    try eqs("usr/lib/os-release", try F.ok(m.fs.resolve("usr//lib//os-release")));
    const dbl = try image(&.{.{ "dbl", '2', 0o777, "", "usr//lib" }});
    try eqs("usr/lib/os-release", try F.ok(dbl.fs.resolve("dbl/os-release")));
    try F.expectFailContains(m.fs.resolve("loop"), "symbolic links");
}

fn layerOf(entries: []const F.E) []T.Entry {
    return T.read(F.tar(entries)) catch unreachable;
}

fn based() Fs {
    var fs = Fs.init();
    fs.apply(base()) catch unreachable;
    return fs;
}

test "image: a_layer_that_cannot_be_applied_is_refused" {
    for ([_][]const u8{ "etc/.wh.", "etc/.wh..", "etc/.wh..." }) |wh| {
        var fs = based();
        try F.expectFail(fs.apply(layerOf(&.{.{ wh, '0', 0o644, "", "" }})), C.fmt("a whiteout `{s}` names no entry", .{wh}));
    }
    var empty = Fs.init();
    try F.expectFail(empty.apply(layerOf(&.{.{ "./", '0', 0o644, "", "" }})), "the layer's root entry `./` is not a directory");
    var fs = Fs.init();
    try F.ok(fs.apply(layerOf(&.{ .{ "./", '5', 0o755, "", "" }, .{ "/", '5', 0o755, "", "" } })));
    try std.testing.expectEqual(@as(u32, 0), fs.nodes.count());
    var b1 = based();
    try F.expectFail(b1.apply(layerOf(&.{.{ "a", '1', 0o644, "", "nope" }})), "hard link a -> nope: no such entry");
    var b2 = based();
    try F.expectFail(b2.apply(layerOf(&.{.{ "a", '1', 0o644, "", "etc" }})), "hard link a -> etc: a directory");
    // A hard link is its target: type, mode and size.
    var b3 = based();
    try F.ok(b3.apply(layerOf(&.{.{ "a", '1', 0o644, "", "./usr/bin/tool" }})));
    const a = b3.get("a").?;
    try std.testing.expectEqual(I.Type.file, a.ty);
    try std.testing.expectEqual(@as(u32, 0o755), a.mode);
    try std.testing.expectEqual(@as(u64, 1), a.size);
    try eqs("", a.link);
}

test "image: whiteouts_are_never_entries_and_an_opaque_root_empties_all" {
    const m = try image(&.{ .{ "etc/", '5', 0o755, "", "" }, .{ "etc/.wh.ssl", '0', 0o644, "", "" }, .{ "usr/.wh..wh..opq", '0', 0o644, "", "" } });
    try noKey(&m.fs, struct {
        fn f(k: []const u8) bool {
            return C.contains(k, ".wh.");
        }
    }.f);
    try noKey(&m.fs, struct {
        fn f(k: []const u8) bool {
            return C.startsWith(k, "usr/");
        }
    }.f);
    var fs = based();
    try F.ok(fs.apply(layerOf(&.{.{ ".wh..wh..opq", '0', 0o644, "", "" }})));
    try std.testing.expectEqual(@as(u32, 0), fs.nodes.count());
    // A directory over a directory keeps what is under it.
    const m2 = try image(&.{ .{ "etc/", '5', 0o700, "", "" }, .{ "etc/ssl/", '5', 0o755, "", "" } });
    try strs(&.{}, certs(&m2.fs));
    try std.testing.expectEqual(@as(u32, 0o700), m2.fs.get("etc").?.mode);
}

test "image: at_most_forty_links_are_followed" {
    var entries = C.list(F.E);
    const chains = [_]struct { []const u8, usize }{ .{ "a", I.MAX_LINKS }, .{ "b", I.MAX_LINKS + 1 } };
    for (chains) |ch| {
        for (0..ch[1]) |i| {
            const target = if (i + 1 == ch[1]) "usr/lib/os-release" else C.fmt("{s}{d}", .{ ch[0], i + 1 });
            C.push(F.E, &entries, .{ C.fmt("{s}{d}", .{ ch[0], i }), '2', 0o777, "", target });
        }
    }
    const m = try image(entries.items);
    try eqs("usr/lib/os-release", try F.ok(m.fs.resolve("a0")));
    try F.expectFail(m.fs.resolve("b0"), "b0: more than 40 symbolic links");
    try strs(&.{"file b0: b0: more than 40 symbolic links"}, I.checkPaths(&m.fs, &.{wanted(.file, "b0")}).bad);
}

test "image: an_exec_is_exactly_0755_and_a_file_one_byte_or_more" {
    const m = try image(&.{ .{ "bin/", '5', 0o755, "", "" }, .{ "bin/a", '0', 0o775, "x", "" }, .{ "bin/b", '0', 0o4755, "x", "" }, .{ "one", '0', 0o644, "x", "" } });
    const r = I.checkPaths(&m.fs, &.{ wanted(.exec, "bin/a"), wanted(.exec, "bin/b"), wanted(.file, "one"), wanted(.file, "bin/a") });
    try strs(&.{ "exec bin/a: bin/a has mode 775, want 755", "exec bin/b: bin/b has mode 4755, want 755" }, r.bad);
    try strs(&.{ "ok file one -> one", "ok file bin/a -> bin/a" }, r.ok);
}

test "image: every_type_change_of_the_last_layer_is_named" {
    const m = try image(&.{
        .{ "etc/", '5', 0o755, "", "" },
        .{ "etc/ssl/", '1', 0o644, "", "usr/bin/tool" },
        .{ "usr/lib/os-release", '3', 0o644, "", "" },
        .{ "usr/lib/", '5', 0o755, "", "" },
        .{ "usr/bin", '2', 0o777, "", "lib" },
        .{ "usr/bin/tool", '0', 0o644, "y", "" },
    });
    try strs(&.{
        "the last layer turns etc/ssl from type d into type -",
        "the last layer turns usr/lib/os-release from type - into type ?",
        "the last layer turns usr/bin from type d into type l",
    }, I.typeChanges(&m.below, m.layer));
}

test "image: normalize_stays_under_root" {
    try eqs("a/c", I.normalize("./a//b/../c/"));
    try eqs("a", I.normalize("/../../a"));
    try eqs("", I.normalize("./"));
}
