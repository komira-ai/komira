//! `komira_wheel same` (compare.zig) on a Linux wheel and a macOS wheel of
//! one package built from the same Python files and metadata: they pass with
//! each one's native libraries named as its own, and every way the macOS
//! wheel can stop being the Linux wheel's package is refused by its exact
//! message: a Python file missing, added, changed or of another mode on one
//! side, a Python file or a member of both named as one side's own, a native
//! file named but absent, a native file not named, another version, another
//! Python tag, a WHEEL differing beyond its Tag, and a wheel with no
//! `.dist-info`.

const std = @import("std");
const compare = @import("compare.zig");
const diag = @import("native_policy").diag;
const wheel = @import("wheel.zig");
const zip = @import("zip.zig");
const fixture = @import("testing.zig");
const t = std.testing;
const Alloc = std.mem.Allocator;

const linux_own = [_][]const u8{ "komira/_lib/libkomira.so", "komira/_lib/lib/libkomira_fs_native.so.1" };
const mac_own = [_][]const u8{
    "komira/_lib/libkomira.dylib",
    "komira/_lib/lib/libAsyncRTRuntimeGlobals.dylib",
    "komira/_lib/lib/libKGENCompilerRTShared.dylib",
    "komira/_lib/lib/libMSupportGlobals.dylib",
};

fn dateOf(a: Alloc) !zip.Stamp {
    var d = diag.Diag{};
    return zip.stampOf(a, &d, 1795186129000);
}

fn members(a: Alloc, in: wheel.Input) ![]zip.Read {
    var d = diag.Diag{};
    const bytes = wheel.build(a, &d, in, try dateOf(a)) catch |e| {
        std.debug.print("build refused: {s}\n", .{d.msg});
        return e;
    };
    return zip.read(a, &d, bytes);
}

/// The Linux fixture's Python file with `extra` beside it, and its natives.
fn linuxInput(a: Alloc, extra: []const wheel.File) !wheel.Input {
    var in = try fixture.input(a);
    var files = std.ArrayList(wheel.File).empty;
    try files.appendSlice(a, in.files);
    try files.appendSlice(a, extra);
    in.files = try files.toOwnedSlice(a);
    return in;
}

/// The same package for macOS: the Linux input's Python files (`python`) and
/// metadata, with the dylib and the runtime dylibs, under the macosx tag.
fn macInput(a: Alloc, python: []const wheel.File) !wheel.Input {
    var in = try fixture.input(a);
    const mac = try fixture.macosInput(a);
    var files = std.ArrayList(wheel.File).empty;
    try files.appendSlice(a, python);
    for (mac.files) |f| if (std.mem.endsWith(u8, f.path, ".dylib")) try files.append(a, f);
    in.files = try files.toOwnedSlice(a);
    in.tag = mac.tag;
    in.max_glibcxx = null;
    in.max_cxxabi = null;
    in.external_needed = &.{};
    return in;
}

const init_py = wheel.File{ .path = "komira/__init__.py", .data = "__all__: list[str] = []\n" };

fn refusal(a: Alloc, mac: []const zip.Read, linux: []const zip.Read, only_mac: []const []const u8, only_linux: []const []const u8) ![]const u8 {
    var d = diag.Diag{};
    try t.expectError(error.Refused, compare.check(a, &d, mac, linux, only_mac, only_linux));
    return d.msg;
}

test "the macOS and Linux wheels of one package pass, each with its native libraries as its own" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const mac = try members(a, try macInput(a, &.{init_py}));
    const linux = try members(a, try linuxInput(a, &.{}));
    const marker = try compare.check(a, &d, mac, linux, &mac_own, &linux_own);
    try t.expectEqualStrings(
        "4 members alike (macosx_11_0_arm64 and manylinux_2_34_x86_64); WHEEL differs only in its Tag, py3-none-macosx_11_0_arm64 and py3-none-manylinux_2_34_x86_64\n" ++
            "only in macosx_11_0_arm64: komira/_lib/libkomira.dylib\n" ++
            "only in macosx_11_0_arm64: komira/_lib/lib/libAsyncRTRuntimeGlobals.dylib\n" ++
            "only in macosx_11_0_arm64: komira/_lib/lib/libKGENCompilerRTShared.dylib\n" ++
            "only in macosx_11_0_arm64: komira/_lib/lib/libMSupportGlobals.dylib\n" ++
            "only in manylinux_2_34_x86_64: komira/_lib/libkomira.so\n" ++
            "only in manylinux_2_34_x86_64: komira/_lib/lib/libkomira_fs_native.so.1\n",
        marker,
    );
}

test "a Python file missing, added, changed or of another mode on one side is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const extra = wheel.File{ .path = "komira/extra.py", .data = "X = 1\n" };
    const linux = try members(a, try linuxInput(a, &.{}));
    const linux_extra = try members(a, try linuxInput(a, &.{extra}));
    const mac = try members(a, try macInput(a, &.{init_py}));
    const mac_extra = try members(a, try macInput(a, &.{ init_py, extra }));
    try t.expectEqualStrings(
        "members: komira/extra.py is in manylinux_2_34_x86_64 and not in macosx_11_0_arm64",
        try refusal(a, mac, linux_extra, &mac_own, &linux_own),
    );
    try t.expectEqualStrings(
        "members: komira/extra.py is in macosx_11_0_arm64 and not in manylinux_2_34_x86_64",
        try refusal(a, mac_extra, linux, &mac_own, &linux_own),
    );
    const changed = try members(a, try macInput(a, &.{.{ .path = "komira/__init__.py", .data = "__all__ = ['x']\n" }}));
    try t.expectEqualStrings(
        "members: komira/__init__.py differs between macosx_11_0_arm64 and manylinux_2_34_x86_64",
        try refusal(a, changed, linux, &mac_own, &linux_own),
    );
    const mode = try members(a, try macInput(a, &.{.{ .path = init_py.path, .data = init_py.data, .mode = 0o755 }}));
    try t.expectEqualStrings(
        "members: komira/__init__.py is mode 755 in macosx_11_0_arm64 and 644 in manylinux_2_34_x86_64",
        try refusal(a, mode, linux, &mac_own, &linux_own),
    );
}

test "a native library not named as its wheel's own, named but absent, or a member of both named, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const linux = try members(a, try linuxInput(a, &.{}));
    const mac = try members(a, try macInput(a, &.{init_py}));
    // The Linux libkomira.so left out of the list: a native file nobody named.
    try t.expectEqualStrings(
        "members: komira/_lib/lib/libkomira_fs_native.so.1 is in manylinux_2_34_x86_64 and not in macosx_11_0_arm64",
        try refusal(a, mac, linux, &mac_own, linux_own[0..1]),
    );
    try t.expectEqualStrings(
        "members: komira/_lib/libkomira.so is named as macosx_11_0_arm64's own, and macosx_11_0_arm64 has no such member",
        try refusal(a, mac, linux, &(mac_own ++ [_][]const u8{"komira/_lib/libkomira.so"}), &linux_own),
    );
    try t.expectEqualStrings(
        "members: komira/__init__.py is named as manylinux_2_34_x86_64's own, and macosx_11_0_arm64 has it too",
        try refusal(a, mac, linux, &mac_own, &(linux_own ++ [_][]const u8{"komira/__init__.py"})),
    );
}

test "a Python file named as one wheel's own is refused: only native files may differ" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const linux = try members(a, try linuxInput(a, &.{}));
    const mac = try members(a, try macInput(a, &.{ init_py, .{ .path = "komira/_macos.py", .data = "MAC = True\n" } }));
    try t.expectEqualStrings(
        "members: komira/_macos.py is named as macosx_11_0_arm64's own, and it is not a native library (Mach-O or ELF): only native files may differ",
        try refusal(a, mac, linux, &(mac_own ++ [_][]const u8{"komira/_macos.py"}), &linux_own),
    );
}

/// `ms` with the member ending in `suffix` holding `data`, zipped and read back.
fn swapped(a: Alloc, ms: []const zip.Read, suffix: []const u8, data: []const u8) ![]zip.Read {
    var out = std.ArrayList(zip.Member).empty;
    for (ms) |m| try out.append(a, .{ .name = m.name, .data = if (std.mem.endsWith(u8, m.name, suffix)) data else m.data, .mode = m.mode });
    var d = diag.Diag{};
    return zip.read(a, &d, try zip.write(a, &d, out.items, try dateOf(a)));
}

test "another version, another Python tag, a WHEEL differing beyond its Tag and a wheel with no dist-info are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const linux = try members(a, try linuxInput(a, &.{}));
    var newer = try macInput(a, &.{init_py});
    newer.version = "0.1.58";
    try t.expectEqualStrings(
        "dist-info: macosx_11_0_arm64 is komira-0.1.58.dist-info and manylinux_2_34_x86_64 is komira-0.1.57.dist-info: not the same distribution at the same version",
        try refusal(a, try members(a, newer), linux, &mac_own, &linux_own),
    );
    const mac = try members(a, try macInput(a, &.{init_py}));
    const cp = try swapped(a, mac, "/WHEEL", "Wheel-Version: 1.0\nGenerator: komira_wheel\nRoot-Is-Purelib: false\nTag: cp313-abi3-macosx_11_0_arm64\n");
    try t.expectEqualStrings(
        "WHEEL: the Python and ABI tags differ: cp313-abi3 for macosx_11_0_arm64, py3-none for manylinux_2_34_x86_64",
        try refusal(a, cp, linux, &mac_own, &linux_own),
    );
    const pure = try swapped(a, mac, "/WHEEL", "Wheel-Version: 1.0\nGenerator: komira_wheel\nRoot-Is-Purelib: true\nTag: py3-none-macosx_11_0_arm64\n");
    try t.expectEqualStrings(
        "WHEEL: komira-0.1.57.dist-info/WHEEL differs beyond its Tag line",
        try refusal(a, pure, linux, &mac_own, &linux_own),
    );
    var no_info = std.ArrayList(zip.Read).empty;
    for (mac) |m| if (std.mem.indexOf(u8, m.name, ".dist-info/") == null) try no_info.append(a, m);
    try t.expectEqualStrings("dist-info: the wheel has no .dist-info directory", try refusal(a, no_info.items, linux, &mac_own, &linux_own));
}

test "the command reads both wheels and writes the marker; a missing flag is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const Files = struct {
        mac: []const u8,
        linux: []const u8,
        pub fn read(f: @This(), _: Alloc, _: *diag.Diag, path: []const u8) diag.Refused![]const u8 {
            return if (std.mem.eql(u8, path, "mac.whl")) f.mac else f.linux;
        }
    };
    var e = diag.Diag{};
    const files = Files{
        .mac = try wheel.build(a, &e, try macInput(a, &.{init_py}), try dateOf(a)),
        .linux = try wheel.build(a, &e, try linuxInput(a, &.{}), try dateOf(a)),
    };
    var argv = std.ArrayList([]const u8).empty;
    try argv.appendSlice(a, &.{ "--wheel", "mac.whl", "--like", "linux.whl", "--out", "same.txt" });
    for (mac_own) |m| try argv.appendSlice(a, &.{ "--only-in-wheel", m });
    for (linux_own) |m| try argv.appendSlice(a, &.{ "--only-in-like", m });
    const r = try compare.command(a, &d, argv.items, files);
    try t.expectEqualStrings("same.txt", r.out);
    try t.expectStringStartsWith(r.marker, "4 members alike (macosx_11_0_arm64 and manylinux_2_34_x86_64)");
    try t.expectError(error.Refused, compare.command(a, &d, &.{ "--wheel", "mac.whl", "--out", "same.txt" }, files));
    try t.expectEqualStrings("missing --like", d.msg);
}

test "a member twice, two dist-info directories, no WHEEL, a WHEEL of two Tags or a Tag without its platform part is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const linux = try members(a, try linuxInput(a, &.{}));
    const mac = try members(a, try macInput(a, &.{init_py}));
    const twice = try std.mem.concat(a, zip.Read, &.{ mac, mac[0..1] });
    const want_twice = try std.fmt.allocPrint(a, "members: the wheel holds {s} twice", .{mac[0].name});
    try t.expectEqualStrings(want_twice, try refusal(a, twice, linux, &mac_own, &linux_own));
    var other = mac[0];
    other.name = "other-0.1.dist-info/METADATA";
    const two_info = try std.mem.concat(a, zip.Read, &.{ mac, &.{other} });
    try t.expectEqualStrings("dist-info: the wheel has two .dist-info directories, komira-0.1.57.dist-info and other-0.1.dist-info", try refusal(a, two_info, linux, &mac_own, &linux_own));
    var no_wheel = std.ArrayList(zip.Read).empty;
    for (mac) |m| if (!std.mem.endsWith(u8, m.name, "/WHEEL")) try no_wheel.append(a, m);
    try t.expectEqualStrings("WHEEL: the wheel has no komira-0.1.57.dist-info/WHEEL", try refusal(a, no_wheel.items, linux, &mac_own, &linux_own));
    const two_tags = try swapped(a, mac, "/WHEEL", "Wheel-Version: 1.0\nTag: py3-none-macosx_11_0_arm64\nTag: py3-none-macosx_12_0_arm64\n");
    try t.expectEqualStrings("WHEEL: the wheel has 2 Tag lines, not one", try refusal(a, two_tags, linux, &mac_own, &linux_own));
    const one_part = try swapped(a, mac, "/WHEEL", "Wheel-Version: 1.0\nGenerator: komira_wheel\nRoot-Is-Purelib: false\nTag: py3\n");
    try t.expectEqualStrings("WHEEL: the wheel has the Tag `py3`, which is not <python>-<abi>-<platform>", try refusal(a, one_part, linux, &mac_own, &linux_own));
    const two_parts = try swapped(a, mac, "/WHEEL", "Wheel-Version: 1.0\nGenerator: komira_wheel\nRoot-Is-Purelib: false\nTag: py3-none\n");
    try t.expectEqualStrings("WHEEL: the wheel has the Tag `py3-none`, which is not <python>-<abi>-<platform>", try refusal(a, two_parts, linux, &mac_own, &linux_own));
}

test "the command refuses a missing --wheel or --out" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Files = struct {
        data: []const u8,
        pub fn read(f: @This(), _: Alloc, _: *diag.Diag, _: []const u8) diag.Refused![]const u8 {
            return f.data;
        }
    };
    var e = diag.Diag{};
    const files = Files{ .data = try wheel.build(a, &e, try linuxInput(a, &.{}), try dateOf(a)) };
    var d = diag.Diag{};
    try t.expectError(error.Refused, compare.command(a, &d, &.{ "--like", "l.whl", "--out", "o" }, files));
    try t.expectEqualStrings("missing --wheel", d.msg);
    try t.expectError(error.Refused, compare.command(a, &d, &.{ "--wheel", "w.whl", "--like", "l.whl" }, files));
    try t.expectEqualStrings("missing --out", d.msg);
}
