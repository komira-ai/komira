//! The Mach-O reader on synthetic dylibs: the install name, the loads (all
//! five load command kinds, in command order), the run paths and the minimum
//! macOS (from LC_BUILD_VERSION and from LC_VERSION_MIN_MACOSX) read back as
//! written; a file with no version command states none; a universal file, a
//! file that is not Mach-O, a header cut short, a command outside sizeofcmds,
//! a string outside its command or without its NUL, two version commands and
//! a build version for another platform are each refused by name; and
//! `isMachO` tells Mach-O files from ELF files and Java class files.

const std = @import("std");
const diag = @import("diag.zig");
const macho = @import("macho.zig");
const fixture = @import("testing.zig");
const t = std.testing;

fn expectStrings(want: []const []const u8, got: []const []const u8) !void {
    try t.expectEqual(want.len, got.len);
    for (want, got) |w, g| try t.expectEqualStrings(w, g);
}

fn refusal(a: std.mem.Allocator, data: []const u8) ![]const u8 {
    var d = diag.Diag{};
    try t.expectError(error.Refused, macho.read(a, &d, "libx.dylib", data));
    return d.msg;
}

fn put32(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .little);
}

test "install name, loads in command order, run paths and minimum macOS read back" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const info = try macho.read(a, &d, "libkomira.dylib", try fixture.goodDylib(a));
    try t.expectEqual(macho.CPU_TYPE_ARM64, info.cputype);
    try t.expectEqual(macho.MH_DYLIB, info.filetype);
    try t.expectEqualStrings("@rpath/libkomira.dylib", info.install_name.?);
    try expectStrings(&.{ "@rpath/libKGENCompilerRTShared.dylib", "@rpath/libAsyncRTRuntimeGlobals.dylib", "/usr/lib/libSystem.B.dylib", "/usr/lib/libc++.1.dylib" }, info.loads);
    try expectStrings(&.{"@loader_path/lib"}, info.rpaths);
    try t.expectEqual(@as(?u32, 0x000b0000), info.minos);
}

test "every kind of load command that loads a library is listed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const names = [_][]const u8{ "/usr/lib/a.dylib", "/usr/lib/b.dylib", "/usr/lib/c.dylib", "/usr/lib/d.dylib", "/usr/lib/e.dylib" };
    const kinds = [_]u32{ 0xc, 0x80000018, 0x8000001f, 0x20, 0x80000023 };
    const info = try macho.read(a, &d, "libx.dylib", try fixture.machO(a, .{ .loads = &names, .load_kinds = &kinds }));
    try expectStrings(&names, info.loads);
    try t.expect(info.install_name == null);
    try t.expectEqual(@as(usize, 0), info.rpaths.len);
}

test "the minimum macOS reads from LC_VERSION_MIN_MACOSX, and a file with no version command states none" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const old = try macho.read(a, &d, "libx.dylib", try fixture.machO(a, .{ .version_min = true, .minos = fixture.macosVersion(10, 15, 4) }));
    try t.expectEqual(@as(?u32, 0x000a0f04), old.minos);
    const none = try macho.read(a, &d, "libx.dylib", try fixture.machO(a, .{ .no_version = true }));
    try t.expect(none.minos == null);
}

test "a version is written as dotted text, with its patch only when it has one" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("11.0", try macho.versionText(a, fixture.macosVersion(11, 0, 0)));
    try t.expectEqualStrings("11.0.1", try macho.versionText(a, fixture.macosVersion(11, 0, 1)));
    try t.expectEqualStrings("13.2", try macho.versionText(a, fixture.macosVersion(13, 2, 0)));
}

test "a header cut short, or a file that is not Mach-O, is refused by name" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try fixture.goodDylib(a);
    try t.expectEqualStrings("libx.dylib: a malformed Mach-O file (a header shorter than 32 bytes)", try refusal(a, good[0..31]));
    try t.expectEqualStrings("libx.dylib: a malformed Mach-O file (no 64-bit little-endian Mach-O magic)", try refusal(a, "\x7fELF\x02\x01\x01\x00 and then some more bytes"));
    try t.expectEqualStrings("libx.dylib: a malformed Mach-O file (no 64-bit little-endian Mach-O magic)", try refusal(a, ""));
}

test "a universal file is refused: a macosx arm64 wheel carries thin arm64 files" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fat = "\xca\xfe\xba\xbe\x00\x00\x00\x02" ++ ("\x00" ** 40);
    try t.expectEqualStrings("libx.dylib: a universal (fat) Mach-O file: a macosx arm64 wheel carries thin arm64 files", try refusal(a, fat));
    const fat64 = "\xca\xfe\xba\xbf\x00\x00\x00\x02" ++ ("\x00" ** 40);
    try t.expectEqualStrings("libx.dylib: a universal (fat) Mach-O file: a macosx arm64 wheel carries thin arm64 files", try refusal(a, fat64));
}

test "a load command outside sizeofcmds is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const want = "libx.dylib: a malformed Mach-O file (a load command outside sizeofcmds)";
    const good = try a.dupe(u8, try fixture.goodDylib(a));
    // sizeofcmds one command short: the last command runs past it.
    const cut = try a.dupe(u8, good);
    put32(cut, 20, std.mem.readInt(u32, cut[20..24], .little) - 8);
    try t.expectEqualStrings(want, try refusal(a, cut));
    // One more command than there are bytes for.
    const more = try a.dupe(u8, good);
    put32(more, 16, std.mem.readInt(u32, more[16..20], .little) + 1);
    try t.expectEqualStrings(want, try refusal(a, more));
    // A command size under the 8 bytes of its own header.
    const tiny = try a.dupe(u8, good);
    put32(tiny, 36, 4);
    try t.expectEqualStrings(want, try refusal(a, tiny));
    // sizeofcmds past the end of the file.
    const far = try a.dupe(u8, good);
    put32(far, 20, @intCast(good.len));
    try t.expectEqualStrings("libx.dylib: a malformed Mach-O file (load commands past the end of the file)", try refusal(a, far));
}

test "a string outside its command, or without its NUL, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try fixture.machO(a, .{ .install_name = "@rpath/a.dylib" });
    const outside = try a.dupe(u8, base);
    put32(outside, 40, 4096); // the install name's offset
    try t.expectEqualStrings("libx.dylib: a malformed Mach-O file (a string outside its load command)", try refusal(a, outside));
    const inside_header = try a.dupe(u8, base);
    put32(inside_header, 40, 4);
    try t.expectEqualStrings("libx.dylib: a malformed Mach-O file (a string outside its load command)", try refusal(a, inside_header));
    const unterminated = try a.dupe(u8, base);
    @memset(unterminated[32 + 24 .. 32 + 40], 'x');
    try t.expectEqualStrings("libx.dylib: a malformed Mach-O file (a string without its NUL)", try refusal(a, unterminated));
}

test "a dylib command too short to hold its string offset is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const short = try a.dupe(u8, try fixture.machO(a, .{ .install_name = "@rpath/a.dylib" }));
    put32(short, 36, 16);
    try t.expectEqualStrings("libx.dylib: a malformed Mach-O file (a dylib command shorter than 24 bytes)", try refusal(a, short));
}

test "a load, run path or version command too short for its fields is refused, each by its kind" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Each fixture's first command is at 32, its cmdsize at 36.
    const load = try a.dupe(u8, try fixture.machO(a, .{ .loads = &.{"@rpath/a.dylib"}, .no_version = true }));
    put32(load, 36, 16);
    try t.expectEqualStrings("libx.dylib: a malformed Mach-O file (a dylib command shorter than 24 bytes)", try refusal(a, load));
    const rpath = try a.dupe(u8, try fixture.machO(a, .{ .rpaths = &.{"@loader_path"}, .no_version = true }));
    put32(rpath, 36, 8);
    try t.expectEqualStrings("libx.dylib: a malformed Mach-O file (an LC_RPATH shorter than 12 bytes)", try refusal(a, rpath));
    const version = try a.dupe(u8, try fixture.machO(a, .{ .version_min = true }));
    put32(version, 36, 8);
    try t.expectEqualStrings("libx.dylib: a malformed Mach-O file (a version command shorter than 16 bytes)", try refusal(a, version));
}

test "a dylib with two install names is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The second LC_ID_DYLIB is written as the kind of the one load.
    const two = try fixture.machO(a, .{ .install_name = "@rpath/a.dylib", .loads = &.{"@rpath/b.dylib"}, .load_kinds = &.{0xd} });
    try t.expectEqualStrings("libx.dylib: a malformed Mach-O file (two LC_ID_DYLIB commands)", try refusal(a, two));
}

test "two minimum-OS commands, and a build version for another platform, are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Unsigned: the file is the header and its one command, nothing after.
    const one = try fixture.machO(a, .{ .version_min = true, .unsigned = true });
    // The same 16-byte LC_VERSION_MIN_MACOSX again, then the counts to match.
    const two = try a.alloc(u8, one.len + 16);
    @memcpy(two[0..one.len], one);
    @memcpy(two[one.len..], one[32..48]);
    put32(two, 16, 2);
    put32(two, 20, 32);
    try t.expectEqualStrings("libx.dylib: a malformed Mach-O file (two minimum-OS version commands)", try refusal(a, two));
    const ios = try a.dupe(u8, try fixture.machO(a, .{}));
    put32(ios, 40, 2); // the platform of the LC_BUILD_VERSION at 32
    try t.expectEqualStrings("libx.dylib: a malformed Mach-O file (an LC_BUILD_VERSION for a platform other than macOS)", try refusal(a, ios));
}

test "isMachO: thin and universal files are, ELF files and Java class files are not" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect(macho.isMachO(try fixture.goodDylib(a)));
    try t.expect(macho.isMachO("\xca\xfe\xba\xbe\x00\x00\x00\x01rest"));
    try t.expect(macho.isMachO("\xca\xfe\xba\xbe\x00\x00\x00\x10rest"));
    try t.expect(macho.isMachO("\xca\xfe\xba\xbf\x00\x00\x00\x02rest"));
    // A class file: the same magic, then minor 0 and major 52 (0x34).
    try t.expect(!macho.isMachO("\xca\xfe\xba\xbe\x00\x00\x00\x34rest"));
    try t.expect(!macho.isMachO("\xca\xfe\xba\xbe\x00\x00\x00\x11rest"));
    try t.expect(!macho.isMachO("\xca\xfe\xba\xbe\x00\x00\x00\x00rest"));
    try t.expect(!macho.isMachO("\xca\xfe\xba\xbe"));
    try t.expect(!macho.isMachO(try fixture.elf(a, .{})));
    try t.expect(!macho.isMachO("\xcf\xfa\xed"));
    try t.expect(!macho.isMachO(""));
}
