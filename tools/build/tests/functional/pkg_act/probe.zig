//! A stand-in for the programs pkg_act runs: the launcher level test's
//! program and kci's manifest probe. PROBE_MODE says what it does:
//!   level       report on stdout, a note on stderr, exit 0
//!   level_fail  report on stdout, exit 3
//!   ok          the manifest probe's line for the manifest named by argv[1]
//!   elsewhere   that line, but naming a metadata.json in another directory
//!   refuse      a message on stderr, exit 1
//!   env         the line, with the environment the probe saw in place of
//!               the package name: the two library-path variables, and
//!               whether TMPDIR and HOME name existing directories
const std = @import("std");

fn line(out: anytype, what: []const u8, dir: []const u8) !void {
    try out.print("OK CONDA {s} 1.0 metadata=metadata.json metadata_path={s}/metadata.json render-identical=yes\n", .{ what, dir });
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    const out = std.fs.File.stdout().deprecatedWriter();
    const mode = std.process.getEnvVarOwned(a, "PROBE_MODE") catch "ok";
    if (std.mem.eql(u8, mode, "level")) {
        try out.writeAll("level report\n");
        std.debug.print("a note on stderr\n", .{});
        return;
    }
    if (std.mem.eql(u8, mode, "level_fail")) {
        try out.writeAll("level report: wrong\n");
        std.process.exit(3);
    }
    if (std.mem.eql(u8, mode, "refuse")) {
        std.debug.print("cannot parse the manifest\n", .{});
        std.process.exit(1);
    }
    const dir = std.fs.path.dirname(args[args.len - 1]) orelse ".";
    if (std.mem.eql(u8, mode, "elsewhere")) return line(out, "pkg", "/elsewhere");
    if (std.mem.eql(u8, mode, "env")) {
        const ld = if (std.process.hasEnvVarConstant("LD_LIBRARY_PATH")) "ld=set" else "ld=unset";
        const pre = if (std.process.hasEnvVarConstant("LD_PRELOAD")) "preload=set" else "preload=unset";
        const tmp = std.process.getEnvVarOwned(a, "TMPDIR") catch "";
        const home = std.process.getEnvVarOwned(a, "HOME") catch "";
        const tmp_ok = if (tmp.len > 0 and isDir(tmp)) "tmp=dir" else "tmp=none";
        const home_ok = if (home.len > 0 and isDir(home)) "home=dir" else "home=none";
        const what = try std.fmt.allocPrint(a, "{s}_{s}_{s}_{s}", .{ ld, pre, tmp_ok, home_ok });
        return line(out, what, dir);
    }
    try line(out, "pkg", dir);
}

fn isDir(p: []const u8) bool {
    var d = std.fs.cwd().openDir(p, .{}) catch return false;
    d.close();
    return true;
}
