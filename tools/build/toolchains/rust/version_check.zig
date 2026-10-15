//! rust_version_check's checker: runs `<rustc> --version` and refuses unless
//! it prints exactly the line the pin states (BUCK). Usage:
//!
//!     version_check <rustc> <expected line> <result.json>
//!
//! rustc runs with an empty environment: it finds its libraries through its
//! own run path ($ORIGIN/../lib), as it does under rustc_wrapper.sh. Exit 1
//! when the line differs (or rustc does not run), 2 on a usage error. Only a
//! match writes <result.json>, the validation result of the sysroot.
const std = @import("std");

/// Whether `got`, the stdout of `rustc --version`, is `want` and one newline.
pub fn matches(got: []const u8, want: []const u8) bool {
    const line = std.mem.trimRight(u8, got, "\n");
    return want.len != 0 and got.len == want.len + 1 and std.mem.eql(u8, line, want) and got[got.len - 1] == '\n';
}

pub const result_json =
    \\{"data":{"message":"rustc --version prints the pinned version","status":"success"},"version":1}
    \\
;

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const a = gpa.allocator();
    const args = std.process.argsAlloc(a) catch std.process.exit(2);
    if (args.len != 4) {
        std.debug.print("version_check: usage: version_check <rustc> <expected line> <result.json>\n", .{});
        std.process.exit(2);
    }
    var env = std.process.EnvMap.init(a);
    // An absolute path, as rustc_wrapper.sh gives it: $ORIGIN is the
    // directory of the path rustc was started by.
    const rustc = std.fs.path.resolve(a, &.{args[1]}) catch std.process.exit(2);
    const r = std.ChildProcess.run(.{
        .allocator = a,
        .argv = &.{ rustc, "--version" },
        .env_map = &env,
    }) catch |e| {
        std.debug.print("version_check: REFUSING: cannot run {s}: {s}\n", .{ rustc, @errorName(e) });
        std.process.exit(1);
    };
    const ok = switch (r.term) {
        .Exited => |c| c == 0,
        else => false,
    };
    if (!ok or !matches(r.stdout, args[2])) {
        std.debug.print("version_check: REFUSING: `rustc --version` printed '{s}' (stderr '{s}'), the pin says '{s}'\n", .{
            std.mem.trimRight(u8, r.stdout, "\n"),
            std.mem.trimRight(u8, r.stderr, "\n"),
            args[2],
        });
        std.process.exit(1);
    }
    std.fs.cwd().writeFile(args[3], result_json) catch |e| {
        std.debug.print("version_check: cannot write {s}: {s}\n", .{ args[3], @errorName(e) });
        std.process.exit(1);
    };
}
