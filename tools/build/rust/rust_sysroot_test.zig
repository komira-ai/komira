//! Unit tests of rust_sysroot.zig, over tar and gzip archives built in memory:
//! which members of the rustc and rust-std releases a sysroot keeps and where
//! they land, modes and links, the refusals, and the check of the result.
const std = @import("std");
const S = @import("rust_sysroot.zig");
const t = std.testing;

// ---- archives built in memory --------------------------------------------------

pub const Entry = struct {
    name: []const u8,
    /// '0' file, '5' directory, '2' symlink.
    kind: u8 = '0',
    mode: u32 = 0o644,
    data: []const u8 = "",
    link: []const u8 = "",
};

fn octal(buf: []u8, v: u64) void {
    @memset(buf, '0');
    var i: usize = buf.len - 1; // the last byte is the terminator
    buf[i] = 0;
    var x = v;
    while (i > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(x & 7));
        x >>= 3;
        if (x == 0) break;
    }
}

pub fn tar(a: std.mem.Allocator, entries: []const Entry) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    for (entries) |e| {
        var h = [_]u8{0} ** 512;
        // A name over 100 bytes is split at a `/` into the ustar prefix field and the name.
        var name_part = e.name;
        if (e.name.len > 100) {
            var i = e.name.len - 1;
            if (e.name[i] == '/') i -= 1;
            while (i > 0) : (i -= 1) {
                if (e.name[i] == '/' and e.name.len - i - 1 <= 100 and i <= 155) break;
            }
            @memcpy(h[345 .. 345 + i], e.name[0..i]);
            name_part = e.name[i + 1 ..];
        }
        @memcpy(h[0..name_part.len], name_part);
        octal(h[100..108], e.mode);
        octal(h[108..116], 0);
        octal(h[116..124], 0);
        octal(h[124..136], e.data.len);
        octal(h[136..148], 0);
        @memset(h[148..156], ' ');
        h[156] = e.kind;
        @memcpy(h[157 .. 157 + e.link.len], e.link);
        @memcpy(h[257..262], "ustar");
        h[262] = 0;
        @memcpy(h[263..265], "00");
        var sum: u64 = 0;
        for (h) |b| sum += b;
        octal(h[148..155], sum);
        h[154] = 0;
        h[155] = ' ';
        try out.appendSlice(&h);
        try out.appendSlice(e.data);
        const pad = (512 - e.data.len % 512) % 512;
        try out.appendNTimes(0, pad);
    }
    try out.appendNTimes(0, 1024);
    return out.toOwnedSlice();
}

/// A gzip stream of `bytes` in stored (uncompressed) deflate blocks.
pub fn gzip(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    try out.appendSlice(&.{ 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3 });
    var off: usize = 0;
    while (true) {
        const n = @min(bytes.len - off, 65535);
        const last = off + n == bytes.len;
        try out.append(if (last) 1 else 0);
        try out.writer().writeInt(u16, @intCast(n), .little);
        try out.writer().writeInt(u16, @intCast(~@as(u16, @intCast(n))), .little);
        try out.appendSlice(bytes[off .. off + n]);
        off += n;
        if (last) break;
    }
    try out.writer().writeInt(u32, std.hash.Crc32.hash(bytes), .little);
    try out.writer().writeInt(u32, @intCast(bytes.len), .little);
    return out.toOwnedSlice();
}

fn gz(a: std.mem.Allocator, entries: []const Entry) ![]u8 {
    return gzip(a, try tar(a, entries));
}

// ---- the tests --------------------------------------------------------------------

const V = "1.99.0";
const T = "x86_64-unknown-linux-gnu";

fn lay(a: std.mem.Allocator) !S.Layout {
    return S.layout(a, V, T);
}

fn mode(dir: std.fs.Dir, path: []const u8) !u32 {
    const st = try dir.statFile(path);
    return @intCast(st.mode & 0o777);
}

fn expectFile(dir: std.fs.Dir, path: []const u8, want: []const u8) !void {
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings(want, try dir.readFile(path, &buf));
}

test "layout: the member prefixes of the two releases and where the standard library lands" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const l = try lay(arena.allocator());
    try t.expectEqualStrings("rustc-1.99.0-x86_64-unknown-linux-gnu/rustc/", l.rustc_prefix);
    try t.expectEqualStrings("rust-std-1.99.0-x86_64-unknown-linux-gnu/rust-std-x86_64-unknown-linux-gnu/lib/rustlib/x86_64-unknown-linux-gnu/lib/", l.std_prefix);
    try t.expectEqualStrings("lib/rustlib/x86_64-unknown-linux-gnu/lib", l.std_dest);
}

test "below: a path under a prefix, trailing slash trimmed; none outside; .. refused" {
    try t.expectEqualStrings("bin/rustc", (try S.below("p/rustc/bin/rustc", "p/rustc/")).?);
    try t.expectEqualStrings("lib", (try S.below("p/rustc/lib/", "p/rustc/")).?);
    try t.expectEqualStrings("", (try S.below("p/rustc/", "p/rustc/")).?);
    try t.expect((try S.below("p/other/bin", "p/rustc/")) == null);
    try t.expect((try S.below("p/rustc", "p/rustc/")) == null);
    try t.expectError(error.PathEscapes, S.below("p/rustc/lib/../../x", "p/rustc/"));
}

test "isRustcLib: one component with .so in it" {
    try t.expect(S.isRustcLib("librustc_driver-0123.so"));
    try t.expect(S.isRustcLib("libLLVM.so.20.1-rust-1.99.0-stable"));
    try t.expect(!S.isRustcLib("libfoo.a"));
    try t.expect(!S.isRustcLib("rustlib/libz.so"));
    try t.expect(!S.isRustcLib(""));
}

test "modeOf: executable or not" {
    try t.expectEqual(@as(u32, 0o755), S.modeOf(0o755));
    try t.expectEqual(@as(u32, 0o755), S.modeOf(0o700 | 0o010));
    try t.expectEqual(@as(u32, 0o644), S.modeOf(0o600));
    try t.expectEqual(@as(u32, 0o644), S.modeOf(0o444));
}

fn rustcArchive(a: std.mem.Allocator) ![]u8 {
    const p = "rustc-1.99.0-x86_64-unknown-linux-gnu/rustc/";
    return gz(a, &.{
        .{ .name = "rustc-1.99.0-x86_64-unknown-linux-gnu/", .kind = '5', .mode = 0o755 },
        .{ .name = p, .kind = '5', .mode = 0o755 },
        .{ .name = p ++ "bin/", .kind = '5', .mode = 0o755 },
        .{ .name = p ++ "bin/rustc", .mode = 0o755, .data = "the driver" },
        .{ .name = p ++ "bin/rustdoc", .mode = 0o755, .data = "not kept" },
        .{ .name = p ++ "lib/librustc_driver-ab.so", .mode = 0o755, .data = "driver lib" },
        .{ .name = p ++ "lib/libLLVM.so.20", .mode = 0o644, .data = "llvm" },
        .{ .name = p ++ "lib/libLLVM.so", .kind = '2', .link = "libLLVM.so.20" },
        .{ .name = p ++ "lib/libstatic.a", .data = "not kept" },
        .{ .name = p ++ "lib/rustlib/etc/libnested.so", .data = "not kept" },
        .{ .name = p ++ "share/man/rustc.1", .data = "not kept" },
        .{ .name = "rustc-1.99.0-x86_64-unknown-linux-gnu/components", .data = "not kept" },
    });
}

fn takeRustcFrom(out: std.fs.Dir, a: std.mem.Allocator, bytes: []const u8) !S.Stats {
    var fbs = std.io.fixedBufferStream(bytes);
    var dec = std.compress.gzip.decompressor(fbs.reader());
    var stats = S.Stats{};
    try S.takeRustc(out, dec.reader(), try lay(a), &stats);
    return stats;
}

test "takeRustc: bin/rustc and the shared libraries directly under lib/, nothing else" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("bin");
    try tmp.dir.makePath("lib");
    const st = try takeRustcFrom(tmp.dir, a, try rustcArchive(a));
    try t.expectEqual(@as(usize, 1), st.bin);
    try t.expectEqual(@as(usize, 3), st.libs);
    try expectFile(tmp.dir, "bin/rustc", "the driver");
    try t.expectEqual(@as(u32, 0o755), try mode(tmp.dir, "bin/rustc"));
    try expectFile(tmp.dir, "lib/librustc_driver-ab.so", "driver lib");
    try t.expectEqual(@as(u32, 0o755), try mode(tmp.dir, "lib/librustc_driver-ab.so"));
    try expectFile(tmp.dir, "lib/libLLVM.so.20", "llvm");
    try t.expectEqual(@as(u32, 0o644), try mode(tmp.dir, "lib/libLLVM.so.20"));
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("libLLVM.so.20", try tmp.dir.readLink("lib/libLLVM.so", &buf));
    for ([_][]const u8{ "bin/rustdoc", "lib/libstatic.a", "lib/rustlib", "share", "components" }) |gone| {
        try t.expectError(error.FileNotFound, tmp.dir.statFile(gone));
    }
}

test "takeRustc: a member that escapes is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const z = try gz(a, &.{.{ .name = "rustc-1.99.0-x86_64-unknown-linux-gnu/rustc/lib/../../evil.so", .data = "x" }});
    try t.expectError(error.PathEscapes, takeRustcFrom(tmp.dir, a, z));
}

test "takeRustc: bin/rustc that is not a file is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const z = try gz(a, &.{.{ .name = "rustc-1.99.0-x86_64-unknown-linux-gnu/rustc/bin/rustc", .kind = '2', .link = "/bin/sh" }});
    try t.expectError(error.NotAFile, takeRustcFrom(tmp.dir, a, z));
}

fn stdArchive(a: std.mem.Allocator) ![]u8 {
    const p = "rust-std-1.99.0-x86_64-unknown-linux-gnu/rust-std-x86_64-unknown-linux-gnu/lib/rustlib/x86_64-unknown-linux-gnu/";
    return gz(a, &.{
        .{ .name = p ++ "lib/", .kind = '5', .mode = 0o755 },
        .{ .name = p ++ "lib/libstd-ab.rlib", .data = "std rlib" },
        .{ .name = p ++ "lib/libstd-ab.so", .mode = 0o755, .data = "std so" },
        .{ .name = p ++ "lib/self-contained/", .kind = '5', .mode = 0o755 },
        .{ .name = p ++ "lib/self-contained/crt1.o", .data = "crt" },
        .{ .name = p ++ "lib/libstd.so", .kind = '2', .link = "libstd-ab.so" },
        .{ .name = p ++ "bin/not-kept", .data = "x" },
        .{ .name = "rust-std-1.99.0-x86_64-unknown-linux-gnu/manifest.in", .data = "x" },
    });
}

fn takeStdFrom(out: std.fs.Dir, a: std.mem.Allocator, bytes: []const u8) !S.Stats {
    var fbs = std.io.fixedBufferStream(bytes);
    var dec = std.compress.gzip.decompressor(fbs.reader());
    var stats = S.Stats{};
    try S.takeStd(out, dec.reader(), try lay(a), &stats);
    return stats;
}

test "takeStd: everything under the target's lib, nowhere else" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const st = try takeStdFrom(tmp.dir, a, try stdArchive(a));
    try t.expectEqual(@as(usize, 5), st.std_entries);
    const d = "lib/rustlib/x86_64-unknown-linux-gnu/lib/";
    try expectFile(tmp.dir, d ++ "libstd-ab.rlib", "std rlib");
    try t.expectEqual(@as(u32, 0o644), try mode(tmp.dir, d ++ "libstd-ab.rlib"));
    try t.expectEqual(@as(u32, 0o755), try mode(tmp.dir, d ++ "libstd-ab.so"));
    try expectFile(tmp.dir, d ++ "self-contained/crt1.o", "crt");
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("libstd-ab.so", try tmp.dir.readLink(d ++ "libstd.so", &buf));
    try t.expectError(error.FileNotFound, tmp.dir.statFile("lib/rustlib/x86_64-unknown-linux-gnu/bin"));
    try t.expectError(error.FileNotFound, tmp.dir.statFile("manifest.in"));
}

fn put(dir: std.fs.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.makePath(d);
    const f = try dir.createFile(path, .{});
    defer f.close();
    try f.writeAll(data);
}

test "takeLibs: copies each library into lib/; a name rustc already has is refused" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("out/lib");
    try put(tmp.dir, "libs/libgcc_s.so.1", "gcc");
    try put(tmp.dir, "libs/libz.so.1", "zlib");
    var out = try tmp.dir.openDir("out", .{ .iterate = true });
    defer out.close();
    var libs = try tmp.dir.openDir("libs", .{ .iterate = true });
    defer libs.close();
    var name: [std.fs.MAX_NAME_BYTES]u8 = undefined;
    var len: usize = 0;
    try t.expectEqual(@as(usize, 2), try S.takeLibs(out, libs, &name, &len));
    try expectFile(out, "lib/libgcc_s.so.1", "gcc");
    try expectFile(out, "lib/libz.so.1", "zlib");
    // Again: both are there now.
    try t.expectError(error.Duplicate, S.takeLibs(out, libs, &name, &len));
    try t.expect(std.mem.eql(u8, "libgcc_s.so.1", name[0..len]) or std.mem.eql(u8, "libz.so.1", name[0..len]));
}

test "check: rustc must be executable and the standard library must have a libstd-" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const l = try lay(arena.allocator());
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try t.expectError(error.NoRustc, S.check(tmp.dir, l));
    try put(tmp.dir, "bin/rustc", "driver");
    var f = try tmp.dir.openFile("bin/rustc", .{});
    try f.chmod(0o644);
    f.close();
    try t.expectError(error.NoRustc, S.check(tmp.dir, l));
    f = try tmp.dir.openFile("bin/rustc", .{});
    try f.chmod(0o755);
    f.close();
    try t.expectError(error.NoLibstd, S.check(tmp.dir, l));
    try put(tmp.dir, "lib/rustlib/x86_64-unknown-linux-gnu/lib/libcore-ab.rlib", "core");
    try t.expectError(error.NoLibstd, S.check(tmp.dir, l));
    try put(tmp.dir, "lib/rustlib/x86_64-unknown-linux-gnu/lib/libstd-ab.rlib", "std");
    try S.check(tmp.dir, l);
}
