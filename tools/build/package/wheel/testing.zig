//! What the komira_wheel tests share: a synthetic ELF shared library of
//! chosen DT_NEEDED, run path and symbol versions, a synthetic Mach-O dylib
//! of chosen install name, loads, run paths and minimum macOS (no real
//! library needed), and the input of a wheel holding a library, its owner and
//! a Python file, or of a macOS wheel holding a dylib and the Mojo runtime's.

const std = @import("std");
const wheel = @import("wheel.zig");
const Alloc = std.mem.Allocator;

pub const Verneed = struct { file: []const u8, versions: []const []const u8 };

pub const Elf = struct {
    needed: []const []const u8 = &.{},
    runpath: ?[]const u8 = null,
    rpath: ?[]const u8 = null,
    verneed: []const Verneed = &.{},
    /// e_machine: 62 x86-64, 183 AArch64.
    machine: u16 = 62,
    /// Non-zero: the file is two PT_LOAD segments, the header at address 0
    /// and the rest at its file offset plus `bias`, as a real library maps
    /// its data above its text; every address in the dynamic section is
    /// then an address, not an offset.
    bias: u64 = 0,
};

fn put(alloc: Alloc, out: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    try out.appendSlice(alloc, &b);
}

fn pad(alloc: Alloc, out: *std.ArrayList(u8), to: usize) !void {
    while (out.items.len % to != 0) try out.append(alloc, 0);
}

/// A 64-bit little-endian ELF shared library: a header, PT_LOAD segments
/// (one mapping the whole file at address 0, or two with `bias`), a
/// PT_DYNAMIC, then the string table, the DT_VERNEED entries and the dynamic
/// section.
pub fn elf(alloc: Alloc, e: Elf) ![]u8 {
    var strtab = std.ArrayList(u8).empty;
    try strtab.append(alloc, 0);
    const Str = struct {
        fn add(a: Alloc, t: *std.ArrayList(u8), s: []const u8) !u32 {
            const at: u32 = @intCast(t.items.len);
            try t.appendSlice(a, s);
            try t.append(a, 0);
            return at;
        }
    };
    var needed = std.ArrayList(u32).empty;
    for (e.needed) |n| try needed.append(alloc, try Str.add(alloc, &strtab, n));
    const runpath = if (e.runpath) |r| try Str.add(alloc, &strtab, r) else null;
    const rpath = if (e.rpath) |r| try Str.add(alloc, &strtab, r) else null;

    var names = std.ArrayList(u32).empty;
    var files = std.ArrayList(u32).empty;
    for (e.verneed) |vn| {
        try files.append(alloc, try Str.add(alloc, &strtab, vn.file));
        for (vn.versions) |v| try names.append(alloc, try Str.add(alloc, &strtab, v));
    }

    const phnum: u16 = if (e.bias != 0) 3 else 2;
    const header_len = 64 + @as(usize, phnum) * 56;
    const strtab_at = header_len;
    var body = std.ArrayList(u8).empty;
    try body.appendNTimes(alloc, 0, header_len);
    try body.appendSlice(alloc, strtab.items);
    try pad(alloc, &body, 4);
    // DT_VERNEED: one Verneed per file, its Vernaux entries right after it.
    const vn_at = body.items.len;
    var name_i: usize = 0;
    for (e.verneed, 0..) |vn, i| {
        const size: u32 = 16 + 16 * @as(u32, @intCast(vn.versions.len));
        try put(alloc, &body, u16, 1); // vn_version
        try put(alloc, &body, u16, @intCast(vn.versions.len));
        try put(alloc, &body, u32, files.items[i]);
        try put(alloc, &body, u32, 16); // vn_aux
        try put(alloc, &body, u32, if (i + 1 < e.verneed.len) size else 0);
        for (vn.versions, 0..) |_, k| {
            try put(alloc, &body, u32, 0); // vna_hash
            try put(alloc, &body, u16, 0);
            try put(alloc, &body, u16, @intCast(2 + name_i));
            try put(alloc, &body, u32, names.items[name_i]);
            try put(alloc, &body, u32, if (k + 1 < vn.versions.len) 16 else 0);
            name_i += 1;
        }
    }
    try pad(alloc, &body, 8);
    const dyn_at = body.items.len;
    const Dyn = struct {
        fn entry(a: Alloc, o: *std.ArrayList(u8), tag: i64, val: u64) !void {
            try put(a, o, i64, tag);
            try put(a, o, u64, val);
        }
    };
    for (needed.items) |n| try Dyn.entry(alloc, &body, 1, n);
    if (runpath) |r| try Dyn.entry(alloc, &body, 29, r);
    if (rpath) |r| try Dyn.entry(alloc, &body, 15, r);
    try Dyn.entry(alloc, &body, 5, strtab_at + e.bias);
    try Dyn.entry(alloc, &body, 10, strtab.items.len);
    if (e.verneed.len != 0) {
        try Dyn.entry(alloc, &body, 0x6ffffffe, vn_at + e.bias);
        try Dyn.entry(alloc, &body, 0x6fffffff, e.verneed.len);
    }
    try Dyn.entry(alloc, &body, 0, 0);
    const dyn_len = body.items.len - dyn_at;
    const total = body.items.len;

    var h = std.ArrayList(u8).empty;
    try h.appendSlice(alloc, "\x7fELF\x02\x01\x01");
    try h.appendNTimes(alloc, 0, 9);
    try put(alloc, &h, u16, 3); // ET_DYN
    try put(alloc, &h, u16, e.machine);
    try put(alloc, &h, u32, 1);
    try put(alloc, &h, u64, 0); // entry
    try put(alloc, &h, u64, 64); // phoff
    try put(alloc, &h, u64, 0); // shoff
    try put(alloc, &h, u32, 0);
    try put(alloc, &h, u16, 64);
    try put(alloc, &h, u16, 56);
    try put(alloc, &h, u16, phnum);
    try put(alloc, &h, u16, 64);
    try put(alloc, &h, u16, 0);
    try put(alloc, &h, u16, 0);
    // {type, offset, address, size}: PT_LOAD of the whole file at address 0,
    // or of the header at 0 and the rest at offset + bias; then PT_DYNAMIC.
    const one = [_][4]u64{ .{ 1, 0, 0, total }, .{ 2, dyn_at, dyn_at, dyn_len } };
    const two = [_][4]u64{ .{ 1, 0, 0, header_len }, .{ 1, header_len, header_len + e.bias, total - header_len }, .{ 2, dyn_at, dyn_at + e.bias, dyn_len } };
    const phs: []const [4]u64 = if (e.bias != 0) &two else &one;
    for (phs) |ph| {
        try put(alloc, &h, u32, @intCast(ph[0]));
        try put(alloc, &h, u32, 4);
        try put(alloc, &h, u64, ph[1]);
        try put(alloc, &h, u64, ph[2]);
        try put(alloc, &h, u64, ph[2]);
        try put(alloc, &h, u64, ph[3]);
        try put(alloc, &h, u64, ph[3]);
        try put(alloc, &h, u64, 8);
    }
    @memcpy(body.items[0..header_len], h.items);
    return body.toOwnedSlice(alloc);
}

/// A library the policy passes: it needs glibc 2.34, libstdc++ (GLIBCXX
/// 3.4.29, CXXABI 1.3.13), its owner beside it and the Mojo runtime, with the
/// run path `$ORIGIN/lib:$ORIGIN`.
pub fn goodLibrary(alloc: Alloc) ![]u8 {
    return elf(alloc, .{
        .needed = &.{ "libkomira_fs_native.so.1", "libKGENCompilerRTShared.so", "libstdc++.so.6", "libc.so.6" },
        .runpath = "$ORIGIN/lib:$ORIGIN",
        .verneed = &.{
            .{ .file = "libc.so.6", .versions = &.{ "GLIBC_2.2.5", "GLIBC_2.34" } },
            .{ .file = "libstdc++.so.6", .versions = &.{ "GLIBCXX_3.4.29", "CXXABI_1.3.13", "CXXABI_TM_1" } },
        },
    });
}

pub const external = [_][]const u8{ "libAsyncRTRuntimeGlobals.so", "libKGENCompilerRTShared.so", "libMSupportGlobals.so" };

pub const readme = "# komira\n\nSQL over local files.\n";

/// A wheel's input: a Python file, the library and its owner (both 0755),
/// two licence files, in an order the build must sort.
pub fn input(alloc: Alloc) !wheel.Input {
    const files = try alloc.dupe(wheel.File, &.{
        .{ .path = "komira/_lib/libkomira.so", .data = try goodLibrary(alloc), .mode = 0o755 },
        .{ .path = "komira/__init__.py", .data = "__all__: list[str] = []\n" },
        .{ .path = "komira/_lib/lib/libkomira_fs_native.so.1", .data = try elf(alloc, .{ .needed = &.{"libc.so.6"}, .runpath = "$ORIGIN" }), .mode = 0o755 },
    });
    const lics = try alloc.dupe(wheel.File, &.{
        .{ .path = "NOTICE", .data = "komira notice\n" },
        .{ .path = "LICENSE", .data = "Apache License text\n" },
    });
    return .{
        .name = "komira",
        .version = "0.1.57",
        .summary = "SQL over local files",
        .readme = readme,
        .requires_python = ">=3.13",
        .requires_dist = &.{ "pyarrow", "mojo-compiler==1.0.0" },
        .classifiers = &.{ "Programming Language :: Python :: 3.13", "Typing :: Typed" },
        .project_urls = &.{.{ .label = "Homepage", .url = "https://github.com/komira-ai/komira" }},
        .license_expression = "Apache-2.0",
        .licenses = lics,
        .files = files,
        .tag = "py3-none-manylinux_2_34_x86_64",
        .max_glibcxx = "3.4.30",
        .max_cxxabi = "1.3.13",
        .external_needed = &external,
    };
}

pub const LC_LOAD_DYLIB: u32 = 0xc;

pub const MachO = struct {
    /// CPU_TYPE_ARM64.
    cputype: u32 = 0x0100000c,
    /// MH_DYLIB.
    filetype: u32 = 6,
    install_name: ?[]const u8 = null,
    loads: []const []const u8 = &.{},
    /// The load command of each of `loads`, by index; LC_LOAD_DYLIB where
    /// this is shorter.
    load_kinds: []const u32 = &.{},
    rpaths: []const []const u8 = &.{},
    /// The minimum macOS, `xxxx.yy.zz` packed (11.0 is 0x000b0000).
    minos: u32 = 0x000b0000,
    /// LC_VERSION_MIN_MACOSX instead of LC_BUILD_VERSION.
    version_min: bool = false,
    /// No version command at all.
    no_version: bool = false,
};

/// The packed `xxxx.yy.zz` of a macOS version.
pub fn macosVersion(major: u32, minor: u32, patch: u32) u32 {
    return major << 16 | minor << 8 | patch;
}

fn lcStr(alloc: Alloc, out: *std.ArrayList(u8), cmd: u32, str_off: u32, s: []const u8) !void {
    const size: u32 = @intCast(std.mem.alignForward(usize, str_off + s.len + 1, 8));
    const start = out.items.len;
    try put(alloc, out, u32, cmd);
    try put(alloc, out, u32, size);
    try put(alloc, out, u32, str_off);
    if (str_off == 24) {
        try put(alloc, out, u32, 2); // timestamp
        try put(alloc, out, u32, 0); // current_version
        try put(alloc, out, u32, 0); // compatibility_version
    }
    try out.appendSlice(alloc, s);
    try out.append(alloc, 0);
    while (out.items.len - start < size) try out.append(alloc, 0);
}

/// A thin 64-bit little-endian Mach-O file: a 32-byte header and the load
/// commands of `m` (each string NUL-terminated, each command padded to a
/// multiple of 8, `sizeofcmds` exact).
pub fn machO(alloc: Alloc, m: MachO) ![]u8 {
    var cmds = std.ArrayList(u8).empty;
    var n: u32 = 0;
    if (m.install_name) |name| {
        try lcStr(alloc, &cmds, 0xd, 24, name);
        n += 1;
    }
    for (m.loads, 0..) |l, i| {
        try lcStr(alloc, &cmds, if (i < m.load_kinds.len) m.load_kinds[i] else LC_LOAD_DYLIB, 24, l);
        n += 1;
    }
    for (m.rpaths) |r| {
        try lcStr(alloc, &cmds, 0x8000001c, 12, r);
        n += 1;
    }
    if (!m.no_version) {
        if (m.version_min) {
            try put(alloc, &cmds, u32, 0x24);
            try put(alloc, &cmds, u32, 16);
            try put(alloc, &cmds, u32, m.minos);
            try put(alloc, &cmds, u32, 0); // sdk
        } else {
            try put(alloc, &cmds, u32, 0x32);
            try put(alloc, &cmds, u32, 24);
            try put(alloc, &cmds, u32, 1); // PLATFORM_MACOS
            try put(alloc, &cmds, u32, m.minos);
            try put(alloc, &cmds, u32, 0); // sdk
            try put(alloc, &cmds, u32, 0); // ntools
        }
        n += 1;
    }
    var out = std.ArrayList(u8).empty;
    try put(alloc, &out, u32, 0xfeedfacf);
    try put(alloc, &out, u32, m.cputype);
    try put(alloc, &out, u32, 0); // cpusubtype
    try put(alloc, &out, u32, m.filetype);
    try put(alloc, &out, u32, n);
    try put(alloc, &out, u32, @intCast(cmds.items.len));
    try put(alloc, &out, u32, 0); // flags
    try put(alloc, &out, u32, 0); // reserved
    try out.appendSlice(alloc, cmds.items);
    return out.toOwnedSlice(alloc);
}

/// The Mojo runtime libraries a macOS wheel carries beside libkomira.
pub const runtime_dylibs = [_][]const u8{ "libAsyncRTRuntimeGlobals.dylib", "libKGENCompilerRTShared.dylib", "libMSupportGlobals.dylib" };

/// A dylib the macOS policy passes: install name `@rpath/libkomira.dylib`,
/// the runtime libraries by `@rpath`, the system's libSystem and libc++, the
/// run path `@loader_path/lib`, minimum macOS 11.0.
pub fn goodDylib(alloc: Alloc) ![]u8 {
    return machO(alloc, .{
        .install_name = "@rpath/libkomira.dylib",
        .loads = &.{ "@rpath/libKGENCompilerRTShared.dylib", "@rpath/libAsyncRTRuntimeGlobals.dylib", "/usr/lib/libSystem.B.dylib", "/usr/lib/libc++.1.dylib" },
        .rpaths = &.{"@loader_path/lib"},
    });
}

/// One of the runtime dylibs: install name `@rpath/<name>`, minimum macOS 11.0.
pub fn runtimeDylib(alloc: Alloc, name: []const u8) ![]u8 {
    return machO(alloc, .{
        .install_name = try std.fmt.allocPrint(alloc, "@rpath/{s}", .{name}),
        .loads = &.{"/usr/lib/libSystem.B.dylib"},
    });
}

/// The macOS wheel's input: libkomira.dylib and the three runtime dylibs
/// (0755), and a Python file, under the tag py3-none-macosx_11_0_arm64, with
/// `lib` as libkomira.dylib.
pub fn macosInputOf(alloc: Alloc, lib: []const u8) !wheel.Input {
    var in = try input(alloc);
    var files = std.ArrayList(wheel.File).empty;
    try files.append(alloc, .{ .path = "komira/__init__.py", .data = "__all__: list[str] = []\n" });
    try files.append(alloc, .{ .path = "komira/_lib/libkomira.dylib", .data = lib, .mode = 0o755 });
    for (runtime_dylibs) |n| {
        try files.append(alloc, .{ .path = try std.fmt.allocPrint(alloc, "komira/_lib/lib/{s}", .{n}), .data = try runtimeDylib(alloc, n), .mode = 0o755 });
    }
    in.files = try files.toOwnedSlice(alloc);
    in.tag = "py3-none-macosx_11_0_arm64";
    in.requires_dist = &.{"pyarrow"};
    in.max_glibcxx = null;
    in.max_cxxabi = null;
    in.external_needed = &.{};
    return in;
}

/// The macOS wheel's input with the good libkomira.dylib.
pub fn macosInput(alloc: Alloc) !wheel.Input {
    return macosInputOf(alloc, try goodDylib(alloc));
}
