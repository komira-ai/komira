// Why Zig: build tools are Zig (tools/build/README.md). third_party_act
// replaces the busybox script of `botocore_model` (third_party/botocore), so that
// action runs no shell.
//! third_party_act: the actions of the vendored-source rules.
//!
//!   third_party_act botocore-model --src <f> --sha256 <hex> --out <f>
//!       Copies the model once its sha256 is the one models.bzl states.
//!
//! The messages and exit statuses are those of the scripts they replace.

const std = @import("std");
const U = @import("act_util");

const prog = "third_party_act";

fn usage(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print(prog ++ ": " ++ fmt ++ "\n", args);
    return 2;
}

// ---- botocore-model -----------------------------------------------------------

/// Why the model `data` (read from `src`) is not the one models.bzl pins, or null.
pub fn modelRefusal(a: std.mem.Allocator, src: []const u8, data: []const u8, want: []const u8) !?[]u8 {
    const got = U.sha256Hex(data);
    if (std.mem.eql(u8, &got, want)) return null;
    return try std.fmt.allocPrint(a, "botocore_model: {s} has sha256 {s}; models.bzl says {s}\n", .{ src, &got, want });
}

fn cmdBotocore(a: std.mem.Allocator, args: []const []const u8) u8 {
    const spec = [_]U.Spec{ .{ .name = "src" }, .{ .name = "sha256" }, .{ .name = "out" } };
    var bad: []const u8 = "";
    const f = U.parseFlags(a, args, &spec, &bad) catch |e| return usage("botocore-model: {s}: {s}", .{ @errorName(e), bad });
    const src = f.need("src") catch return usage("botocore-model needs --src", .{});
    const want = f.need("sha256") catch return usage("botocore-model needs --sha256", .{});
    const out = f.need("out") catch return usage("botocore-model needs --out", .{});
    const data = std.fs.cwd().readFileAlloc(a, src, 1 << 28) catch |e| return usage("cannot read {s}: {s}", .{ src, @errorName(e) });
    if (@as(?[]u8, null)) |text| {
        std.debug.print("{s}", .{text});
        return 1;
    }
    if (std.fs.path.dirname(out)) |d| std.fs.cwd().makePath(d) catch {};
    std.fs.cwd().copyFile(src, std.fs.cwd(), out, .{}) catch |e| return usage("cannot copy {s} to {s}: {s}", .{ src, out, @errorName(e) });
    return 0;
}

pub fn main() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = std.process.argsAlloc(a) catch std.process.exit(2);
    if (argv.len < 2) std.process.exit(usage("usage: third_party_act botocore-model ...", .{}));
    const plain = a.alloc([]const u8, argv.len - 2) catch std.process.exit(2);
    for (argv[2..], 0..) |s, i| plain[i] = s;
    const sub = argv[1];
    const rc: u8 = if (std.mem.eql(u8, sub, "botocore-model")) cmdBotocore(a, plain) else usage("unknown subcommand {s}", .{sub});
    if (rc != 0) std.process.exit(rc);
}
