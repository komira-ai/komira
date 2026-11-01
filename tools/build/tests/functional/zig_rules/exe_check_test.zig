// A driver test over built executables (exec_tools): the optimization mode
// and the strip flag of zig_exe reach the compile. Each tool is run, and its
// bytes are searched for the section name a build that keeps debug
// information carries.
const std = @import("std");

fn env(name: []const u8) ![]u8 {
    return std.process.getEnvVarOwned(std.testing.allocator, name);
}

fn runs(path: []const u8) ![]u8 {
    const r = try std.process.Child.run(.{ .allocator = std.testing.allocator, .argv = &.{path} });
    defer std.testing.allocator.free(r.stderr);
    return r.stdout;
}

fn expectOutput(var_name: []const u8, want: []const u8) !void {
    const path = try env(var_name);
    defer std.testing.allocator.free(path);
    const got = try runs(path);
    defer std.testing.allocator.free(got);
    const trimmed = std.mem.trim(u8, got, "\n");
    if (!std.mem.eql(u8, trimmed, want)) {
        std.debug.print("got '{s}', expected '{s}'\n", .{ trimmed, want });
        return error.WrongMode;
    }
}

fn expectStripped(var_name: []const u8, stripped: bool) !void {
    const path = try env(var_name);
    defer std.testing.allocator.free(path);
    const bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, path, 1 << 28);
    defer std.testing.allocator.free(bytes);
    const has = std.mem.indexOf(u8, bytes, ".debug_info") != null;
    if (has == stripped) {
        std.debug.print("{s} is {s}, expected {s}\n", .{ std.fs.path.basename(path), if (has) "unstripped" else "stripped", if (stripped) "stripped" else "unstripped" });
        return error.WrongStrip;
    }
}

test "optimize reaches the compile" {
    try expectOutput("APP_SAFE", "42 ReleaseSafe");
    try expectOutput("APP_DEBUG", "42 Debug");
    try expectOutput("APP_SMALL", "42 ReleaseSmall");
}

test "strip reaches the compile" {
    try expectStripped("APP_SAFE", true);
    try expectStripped("APP_SMALL", true);
    try expectStripped("APP_DEBUG", false);
}
