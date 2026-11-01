//! A stand-in for `./buck2` in the cases of the buck2-farm action
//! (//:buck2_farm_cases): `stand_in_buck2 <recorded-log> [--fail]` prints the
//! recorded buck2 output and exits 0, or 1 with `--fail` (a buck2 that
//! printed a good summary and then failed). It runs nothing.
const std = @import("std");

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const a = gpa.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len < 2 or args.len > 3) return 2;
    const log = try std.fs.cwd().readFileAlloc(a, args[1], 1 << 24);
    try std.fs.File.stdout().writeAll(log);
    return if (args.len == 3 and std.mem.eql(u8, args[2], "--fail")) 1 else 0;
}
