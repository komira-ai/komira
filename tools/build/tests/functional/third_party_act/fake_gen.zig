//! A stand-in for third_party_srcs' :gen. It is run as `<library> <tar> <out>
//! <gen-label> <drift-label> <committed-path>`; it writes, to <out>, what it was
//! given and the first bytes of the tar it was handed. The library `fail3` makes
//! it exit 3 and write nothing.
const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len != 7) std.process.exit(9);
    if (std.mem.eql(u8, args[1], "fail3")) std.process.exit(3);
    const tar = try std.fs.cwd().readFileAlloc(a, args[2], 1 << 24);
    const f = try std.fs.cwd().createFile(args[3], .{});
    defer f.close();
    const w = f.writer();
    try w.print("library={s}\ntar_bytes={d}\ntar_name={s}\ngen_label={s}\ndrift_label={s}\ncommitted={s}\n", .{
        args[1], tar.len, std.mem.sliceTo(tar[0..@min(tar.len, 100)], 0), args[4], args[5], args[6],
    });
    try w.print("tar_path_is_absolute={s}\n", .{if (std.fs.path.isAbsolute(args[2])) "yes" else "no"});
}
