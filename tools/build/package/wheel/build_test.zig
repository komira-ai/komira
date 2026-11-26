//! The wheel of an input: built twice it is the same bytes, also from inputs
//! in another order; its members in order with their modes; METADATA, WHEEL
//! and RECORD text; the version a stamp gives (and a half stamp refused); the
//! tags taken (manylinux x86_64 and aarch64, macosx arm64) and refused (any,
//! a CPython ABI); and each input it cannot carry refused by name.

const std = @import("std");
const diag = @import("native_policy").diag;
const stamp = @import("stamp.zig");
const tag = @import("tag.zig");
const wheel = @import("wheel.zig");
const zip = @import("zip.zig");
const fixture = @import("testing.zig");
const t = std.testing;
const Alloc = std.mem.Allocator;

const want_metadata =
    \\Metadata-Version: 2.4
    \\Name: komira
    \\Version: 0.1.57
    \\Summary: SQL over local files
    \\Requires-Python: >=3.13
    \\License-Expression: Apache-2.0
    \\License-File: LICENSE
    \\License-File: NOTICE
    \\Classifier: Programming Language :: Python :: 3.13
    \\Classifier: Typing :: Typed
    \\Project-URL: Homepage, https://github.com/komira-ai/komira
    \\Requires-Dist: pyarrow
    \\Requires-Dist: mojo-compiler==1.0.0
    \\Description-Content-Type: text/markdown
    \\
    \\# komira
    \\
    \\SQL over local files.
    \\
;

test "built twice, and from inputs in another order, the wheel is the same bytes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    var in = try fixture.input(a);
    const first = try wheel.build(a, &d, in, .{});
    const second = try wheel.build(a, &d, in, .{});
    try t.expectEqualSlices(u8, first, second);
    const files = try a.dupe(wheel.File, in.files);
    std.mem.reverse(wheel.File, files);
    const lics = try a.dupe(wheel.File, in.licenses);
    std.mem.reverse(wheel.File, lics);
    in.files = files;
    in.licenses = lics;
    try t.expectEqualSlices(u8, first, try wheel.build(a, &d, in, .{}));
}

test "the members in order, with their modes, and METADATA, WHEEL and RECORD" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const in = try fixture.input(a);
    const ms = try zip.read(a, &d, try wheel.build(a, &d, in, .{}));
    const names = [_][]const u8{
        "komira/__init__.py",
        "komira/_lib/lib/libkomira_fs_native.so.1",
        "komira/_lib/libkomira.so",
        "komira-0.1.57.dist-info/METADATA",
        "komira-0.1.57.dist-info/WHEEL",
        "komira-0.1.57.dist-info/licenses/LICENSE",
        "komira-0.1.57.dist-info/licenses/NOTICE",
        "komira-0.1.57.dist-info/RECORD",
    };
    try t.expectEqual(names.len, ms.len);
    for (names, ms) |n, m| try t.expectEqualStrings(n, m.name);
    const modes = [_]u32{ 0o644, 0o755, 0o755, 0o644, 0o644, 0o644, 0o644, 0o644 };
    for (modes, ms) |mode, m| try t.expectEqual(mode, m.mode);
    try t.expectEqualStrings(want_metadata, ms[3].data);
    try t.expectEqualStrings("Wheel-Version: 1.0\nGenerator: komira_wheel\nRoot-Is-Purelib: false\nTag: py3-none-manylinux_2_34_x86_64\n", ms[4].data);
    try t.expectEqualStrings("Apache License text\n", ms[5].data);

    var lines = std.mem.splitScalar(u8, ms[7].data, '\n');
    for (ms[0..7]) |m| {
        try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s},{s},{d}", .{ m.name, try wheel.recordHash(a, m.data), m.data.len }), lines.next().?);
    }
    try t.expectEqualStrings("komira-0.1.57.dist-info/RECORD,,", lines.next().?);
    try t.expectEqualStrings("", lines.next().?);
    try t.expectEqual(@as(?[]const u8, null), lines.next());
    try t.expectEqualStrings("sha256=47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU", try wheel.recordHash(a, ""));
    try t.expectEqualStrings("komira-0.1.57-py3-none-manylinux_2_34_x86_64.whl", try wheel.fileName(a, "komira", "0.1.57", in.tag));
    try t.expectEqualStrings("my_pkg-0.1.1.dist-info", try wheel.distInfo(a, "my-pkg", "0.1.1"));
}

test "the stamp: all three give 0.1.<N>, none gives 0.0.0, any other mix is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const commit = "7e57c0de1f2e3d4c5b6a79880a1b2c3d4e5f6071";
    const s = try stamp.of(a, &d, "57", commit, "1795186129000");
    try t.expectEqualStrings("0.1.57", s.version);
    try t.expect(s.stamped);
    try t.expectEqual(@as(i64, 1795186129000), s.timestamp_ms);
    const none = try stamp.of(a, &d, "0", "", "0");
    try t.expectEqualStrings("0.0.0", none.version);
    try t.expect(!none.stamped);
    try t.expectEqualStrings("0.0.0", (try stamp.of(a, &d, "", "", "")).version);

    try t.expectError(error.Refused, stamp.of(a, &d, "57", "", "0"));
    try t.expectEqualStrings("a stamp needs all of -c komira.package_stamp, -c komira.package_commit and -c komira.package_timestamp_ms, or none; missing: komira.package_commit, komira.package_timestamp_ms", d.msg);
    try t.expectError(error.Refused, stamp.of(a, &d, "0", commit, "1"));
    try t.expectEqualStrings("a stamp needs all of -c komira.package_stamp, -c komira.package_commit and -c komira.package_timestamp_ms, or none; missing: komira.package_stamp", d.msg);
    try t.expectError(error.Refused, stamp.of(a, &d, "057", commit, "1"));
    try t.expectEqualStrings("the stamp `057` is not a positive number without leading zeros", d.msg);
    try t.expectError(error.Refused, stamp.of(a, &d, "57", "7E57C0DE1F2E3D4C5B6A79880A1B2C3D4E5F6071", "1"));
    try t.expectEqualStrings("the stamp's commit `7E57C0DE1F2E3D4C5B6A79880A1B2C3D4E5F6071` is not 40 lowercase hex digits", d.msg);
    try t.expectError(error.Refused, stamp.of(a, &d, "57", commit, "-5"));
    try t.expectEqualStrings("the stamp's commit time `-5` is not a number of milliseconds", d.msg);
    try t.expectError(error.Refused, stamp.of(a, &d, "57", commit, "99999999999999999999"));
    try t.expectEqualStrings("the stamp's commit time `99999999999999999999` is out of range", d.msg);
}

test "tags: manylinux x86_64 and aarch64 and macosx arm64 are taken, any and a CPython ABI refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const x86 = try tag.parse(a, &d, "py3-none-manylinux_2_34_x86_64");
    try t.expectEqualStrings("2.34", x86.glibc.?);
    try t.expect(x86.macos == null);
    try t.expect(x86.linux);
    try t.expectEqualStrings("x86_64", x86.arch);
    try t.expectEqualStrings("2.34", (try tag.parse(a, &d, "py3-none-manylinux_2_34_aarch64")).glibc.?);
    try t.expect((try tag.parse(a, &d, "py3-none-manylinux_2_34_aarch64")).macos == null);
    const mac = try tag.parse(a, &d, "py3-none-macosx_11_0_arm64");
    try t.expect(mac.glibc == null);
    try t.expectEqualStrings("11.0", mac.macos.?);
    try t.expectEqualStrings("14.2", (try tag.parse(a, &d, "py3-none-macosx_14_2_arm64")).macos.?);
    try t.expect(!mac.linux);
    const Case = struct { tag: []const u8, want: []const u8 };
    for ([_]Case{
        .{ .tag = "py3-none-any", .want = "the tag `py3-none-any` says any platform, but a wheel holding a native library is built for one" },
        .{ .tag = "cp313-cp313-manylinux_2_34_x86_64", .want = "the tag `cp313-cp313-manylinux_2_34_x86_64` is not `py3-none-<platform>` (the package loads its library with ctypes and uses no CPython ABI)" },
        .{ .tag = "py3-none-manylinux_2_34_riscv64", .want = "the manylinux tag `manylinux_2_34_riscv64` names the architecture `riscv64`, not x86_64 or aarch64" },
        .{ .tag = "py3-none-macosx_11_0_x86_64", .want = "the macosx tag `macosx_11_0_x86_64` names the architecture `x86_64`, not arm64" },
        .{ .tag = "py3-none-manylinux2014_x86_64", .want = "the platform tag `manylinux2014_x86_64` is not <family>_<major>_<minor>_<arch>" },
        .{ .tag = "py3-none-win_2_0_amd64", .want = "the platform tag `win_2_0_amd64` is neither manylinux nor macosx" },
        .{ .tag = "py3-none-manylinux_02_34_x86_64", .want = "the platform tag `manylinux_02_34_x86_64` is not <family>_<major>_<minor>_<arch>" },
    }) |c| {
        try t.expectError(error.Refused, tag.parse(a, &d, c.tag));
        try t.expectEqualStrings(c.want, d.msg);
    }
}

fn refusal(a: Alloc, in: wheel.Input) ![]const u8 {
    var d = diag.Diag{};
    try t.expectError(error.Refused, wheel.build(a, &d, in, .{}));
    return d.msg;
}

test "metadata the wheel cannot carry is refused, a License classifier beside the expression among it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var in = try fixture.input(a);
    in.classifiers = &.{"License :: OSI Approved :: Apache Software License"};
    try t.expectEqualStrings("metadata: the classifier `License :: OSI Approved :: Apache Software License` beside license_expression: PEP 639 forbids License :: classifiers with a License-Expression", try refusal(a, in));
    in = try fixture.input(a);
    in.name = "Komira";
    try t.expectEqualStrings("metadata: the name `Komira` is not a normalised name (lowercase letters, digits, single `-`)", try refusal(a, in));
    for ([_][]const u8{ "0.1.57+local", "0.1.57.post1", "1", "0.01.1", "0.1.", "0.1.57rc1" }) |v| {
        in = try fixture.input(a);
        in.version = v;
        try t.expectEqualStrings(try std.fmt.allocPrint(a, "metadata: the version `{s}` is not a release version (dot-separated numbers; no local, pre- or post-release part)", .{v}), try refusal(a, in));
    }
    in = try fixture.input(a);
    in.summary = "";
    try t.expectEqualStrings("metadata: the summary is empty", try refusal(a, in));
    in = try fixture.input(a);
    in.requires_dist = &.{"pyarrow\nRequires-Dist: evil"};
    try t.expectEqualStrings("metadata: a requirement `pyarrow\nRequires-Dist: evil` holds a line break", try refusal(a, in));
    in = try fixture.input(a);
    in.project_urls = &.{.{ .label = "a,b", .url = "https://example.com" }};
    try t.expectEqualStrings("metadata: the project URL label `a,b` holds `,`, which ends the label in METADATA", try refusal(a, in));
    in = try fixture.input(a);
    in.project_urls = &.{.{ .label = "abcdefghijklmnopqrstuvwxyz0123456", .url = "https://example.com" }};
    try t.expectEqualStrings("metadata: the project URL label `abcdefghijklmnopqrstuvwxyz0123456` is over 32 characters, which the core metadata spec allows", try refusal(a, in));
    in = try fixture.input(a);
    in.licenses = &.{};
    try t.expectEqualStrings("metadata: no licence file: a wheel carries its licence text (PEP 639)", try refusal(a, in));
    in = try fixture.input(a);
    in.licenses = &.{ .{ .path = "LICENSE", .data = "" }, .{ .path = "LICENSE", .data = "" } };
    try t.expectEqualStrings("metadata: the licence file `LICENSE` is given twice", try refusal(a, in));
    in = try fixture.input(a);
    in.licenses = &.{.{ .path = "sub/LICENSE", .data = "" }};
    try t.expectEqualStrings("metadata: the licence file `sub/LICENSE` is not a bare file name", try refusal(a, in));
}

test "files the wheel cannot carry are refused, and a wheel of no files" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { path: []const u8, want: []const u8 };
    for ([_]Case{
        .{ .path = "/abs", .want = "path: `/abs` is not a relative path" },
        .{ .path = "a,b", .want = "path: `a,b` holds a comma, a quote or a backslash" },
        .{ .path = "caf\xc3\xa9.py", .want = "path: `caf\xc3\xa9.py` holds a byte outside printable ASCII" },
        .{ .path = "a\nb", .want = "path: `a\nb` holds a byte outside printable ASCII" },
        .{ .path = "a/../b", .want = "path: `a/../b` has an empty, `.` or `..` part" },
        .{ .path = "a//b", .want = "path: `a//b` has an empty, `.` or `..` part" },
        .{ .path = "komira-0.1.57.dist-info/entry_points.txt", .want = "path: `komira-0.1.57.dist-info/entry_points.txt` is under a .dist-info or .data directory, which the wheel rule writes itself" },
        .{ .path = "komira-0.1.57.data/scripts/x", .want = "path: `komira-0.1.57.data/scripts/x` is under a .dist-info or .data directory, which the wheel rule writes itself" },
        .{ .path = "komira/__init__.py", .want = "path: `komira/__init__.py` is given twice" },
    }) |c| {
        var in = try fixture.input(a);
        in.files = try std.mem.concat(a, wheel.File, &.{ in.files, &.{.{ .path = c.path, .data = "" }} });
        try t.expectEqualStrings(c.want, try refusal(a, in));
    }
    var in = try fixture.input(a);
    in.files = &.{};
    try t.expectEqualStrings("path: the wheel has no files", try refusal(a, in));
    // The policy runs before anything is written (policy_test.zig has each check).
    in = try fixture.input(a);
    in.external_needed = &.{};
    try t.expectEqualStrings("needed: komira/_lib/libkomira.so needs libKGENCompilerRTShared.so, which is not in the wheel, not a manylinux system library, and not in external_needed", try refusal(a, in));
    in = try fixture.input(a);
    in.tag = "py3-none-any";
    try t.expectEqualStrings("the tag `py3-none-any` says any platform, but a wheel holding a native library is built for one", try refusal(a, in));
}

test "a macOS wheel of the dylib and the runtime dylibs is written under the macosx tag" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const in = try fixture.macosInput(a);
    try t.expectEqualStrings("komira-0.1.57-py3-none-macosx_11_0_arm64.whl", try wheel.fileName(a, in.name, in.version, in.tag));
    const ms = try zip.read(a, &d, try wheel.build(a, &d, in, .{}));
    const names = [_][]const u8{
        "komira/__init__.py",
        "komira/_lib/lib/libAsyncRTRuntimeGlobals.dylib",
        "komira/_lib/lib/libKGENCompilerRTShared.dylib",
        "komira/_lib/lib/libMSupportGlobals.dylib",
        "komira/_lib/libkomira.dylib",
        "komira-0.1.57.dist-info/METADATA",
        "komira-0.1.57.dist-info/WHEEL",
        "komira-0.1.57.dist-info/licenses/LICENSE",
        "komira-0.1.57.dist-info/licenses/NOTICE",
        "komira-0.1.57.dist-info/RECORD",
    };
    try t.expectEqual(names.len, ms.len);
    for (names, ms) |n, m| try t.expectEqualStrings(n, m.name);
    try t.expectEqualStrings("Wheel-Version: 1.0\nGenerator: komira_wheel\nRoot-Is-Purelib: false\nTag: py3-none-macosx_11_0_arm64\n", ms[6].data);
}

test "a macOS wheel whose dylib needs a newer macOS than the tag is refused by the build" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const lib = try fixture.machO(a, .{ .install_name = "@rpath/libkomira.dylib", .minos = fixture.macosVersion(13, 0, 0) });
    try t.expectError(error.Refused, wheel.build(a, &d, try fixture.macosInputOf(a, lib), .{}));
    try t.expectEqualStrings("minos: komira/_lib/libkomira.dylib needs macOS 13.0, newer than the tag's macOS 11.0", d.msg);
}
