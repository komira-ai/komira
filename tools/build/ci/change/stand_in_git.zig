//! A stand-in for `git` in the cases of the change tool's executable (//tools/build/ci:change_cli_cases).
//! Run in a case's directory, it appends its arguments, joined by one space, as one line to the file
//! `asked`, writes `stand-in git: <arguments>` to stderr, and answers from the file `answers`: one
//! line per command, `<exit code>\t<arguments joined by one space>\t<stdout>`, where `\n` in stdout
//! stands for a newline. The first line whose arguments match is the answer. A command with no
//! answer exits 99. It runs nothing.
const std = @import("std");

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try std.process.argsAlloc(a);
    const args = try a.alloc([]const u8, raw.len -| 1);
    for (args, 0..) |*o, i| o.* = raw[i + 1];
    const joined = try std.mem.join(a, " ", args);

    var asked = try std.fs.cwd().createFile("asked", .{ .truncate = false });
    defer asked.close();
    try asked.seekFromEnd(0);
    try asked.writeAll(try std.fmt.allocPrint(a, "{s}\n", .{joined}));
    try std.fs.File.stderr().writeAll(try std.fmt.allocPrint(a, "stand-in git: {s}\n", .{joined}));

    const answers = try std.fs.cwd().readFileAlloc(a, "answers", 1 << 20);
    var lines = std.mem.splitScalar(u8, answers, '\n');
    while (lines.next()) |line| {
        var cols = std.mem.splitScalar(u8, line, '\t');
        const code = cols.next() orelse continue;
        const want = cols.next() orelse continue;
        const stdout = cols.next() orelse "";
        if (!std.mem.eql(u8, want, joined)) continue;
        try std.fs.File.stdout().writeAll(try std.mem.replaceOwned(u8, a, stdout, "\\n", "\n"));
        return try std.fmt.parseInt(u8, code, 10);
    }
    return 99;
}
