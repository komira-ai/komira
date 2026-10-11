//! unzst: decompress one zstd file into one executable file.
//!
//! usage: unzst <in.zst> <out>
//!
//! The scenarios' buck2 (tools/build/selftest/BUCK, `:buck2`) is the pinned
//! release asset `tools/buck2` names, a zstd file. This tool writes its one
//! frame's bytes to <out> with mode 0755, and refuses an input that holds
//! no bytes or is not zstd. Built by the pinned zig, using only its standard
//! library, so the unpack needs nothing from the worker.
const std = @import("std");

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.io.getStdErr().writer().print("unzst: " ++ fmt ++ "\n", args) catch {};
    std.process.exit(1);
}

/// The decompressed bytes of `data`, or an error naming why not.
pub fn decompress(a: std.mem.Allocator, data: []const u8) ![]u8 {
    if (data.len == 0) return error.EmptyInput;
    var fbs = std.io.fixedBufferStream(data);
    const window = try a.alloc(u8, 1 << 27);
    defer a.free(window);
    var dz = std.compress.zstd.decompressor(fbs.reader(), .{ .window_buffer = window });
    const out = try dz.reader().readAllAlloc(a, 1 << 31);
    if (out.len == 0) return error.EmptyOutput;
    return out;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len != 3) fail("usage: unzst <in.zst> <out>", .{});
    const data = std.fs.cwd().readFileAlloc(a, args[1], 1 << 31) catch |e|
        fail("cannot read {s}: {s}", .{ args[1], @errorName(e) });
    const out = decompress(a, data) catch |e| fail("{s}: not one zstd file with bytes in it: {s}", .{ args[1], @errorName(e) });
    const f = std.fs.cwd().createFile(args[2], .{ .mode = 0o755 }) catch |e|
        fail("cannot create {s}: {s}", .{ args[2], @errorName(e) });
    defer f.close();
    f.writeAll(out) catch |e| fail("cannot write {s}: {s}", .{ args[2], @errorName(e) });
}

test "an empty input is refused" {
    try std.testing.expectError(error.EmptyInput, decompress(std.testing.allocator, ""));
}

test "bytes that are not zstd are refused" {
    try std.testing.expect(std.meta.isError(decompress(std.testing.allocator, "plain text, not a zstd frame")));
}

test "a zstd frame decompresses to its bytes" {
    // `printf 'buck2\n' | zstd -c | od -An -tx1`: one frame, one raw block, a checksum.
    const frame = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0x04, 0x58, 0x31, 0x00, 0x00, 0x62, 0x75, 0x63, 0x6b, 0x32, 0x0a, 0xa1, 0x48, 0x33, 0xc9 };
    const out = try decompress(std.testing.allocator, &frame);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("buck2\n", out);
}
