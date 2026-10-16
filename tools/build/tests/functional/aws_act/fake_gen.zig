//! A stand-in for aws-client-gen. It requires `--module M --out F --probe-out P`
//! first, writes M's code to F and the probe to P, and prints the rest of its
//! arguments on stdout, one per line after `rest:`. GEN_MODE (the first of the
//! rest, as `mode=<m>`) says what else: `ok`, `empty` (an empty module),
//! `extra` (a file nobody declared), `none` (writes nothing), `exit3`.
const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len < 7 or !std.mem.eql(u8, args[1], "--module") or !std.mem.eql(u8, args[3], "--out") or !std.mem.eql(u8, args[5], "--probe-out")) std.process.exit(9);
    const out = std.fs.File.stdout().deprecatedWriter();
    var mode: []const u8 = "ok";
    for (args[7..]) |x| {
        if (std.mem.startsWith(u8, x, "mode=")) mode = x[5..];
    }
    try out.print("module={s}\n", .{args[2]});
    for (args[7..]) |x| try out.print("rest:{s}\n", .{x});
    if (std.mem.eql(u8, mode, "exit3")) std.process.exit(3);
    if (std.mem.eql(u8, mode, "none")) return;
    const m = try std.fs.cwd().createFile(args[4], .{});
    defer m.close();
    if (!std.mem.eql(u8, mode, "empty")) try m.writeAll("# generated module\n");
    const p = try std.fs.cwd().createFile(args[6], .{});
    defer p.close();
    try p.writeAll("# probe\n");
    if (std.mem.eql(u8, mode, "extra")) {
        const dir = std.fs.path.dirname(args[4]) orelse ".";
        const e = try std.fs.cwd().createFile(try std.fs.path.join(a, &.{ dir, "stray.mojo" }), .{});
        e.close();
    }
}
