//! Small pieces shared by the release tools: ids, flags, and the files the
//! workflow reads back (a step output, a summary).
const std = @import("std");

/// A full commit id: 40 lowercase hex characters.
pub fn isFullCommitId(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| if (!isLowerHex(c)) return false;
    return true;
}

/// A sha256 as hex: 64 lowercase hex characters.
pub fn isSha256Hex(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| if (!isLowerHex(c)) return false;
    return true;
}

fn isLowerHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
}

/// The text of a git answer that is one line: the trailing newline removed.
/// More than one line is null.
pub fn oneLine(s: []const u8) ?[]const u8 {
    const t = if (std.mem.endsWith(u8, s, "\n")) s[0 .. s.len - 1] else s;
    if (std.mem.indexOfScalar(u8, t, '\n') != null) return null;
    return t;
}

/// `--name value` pairs. Each name is given once; a name not in `names` is
/// refused. `bad` says what was wrong, for the message.
pub const Flags = struct {
    names: []const []const u8,
    values: []?[]const u8,

    pub const Error = error{ UnknownFlag, MissingValue, DuplicateFlag };

    pub fn parse(a: std.mem.Allocator, argv: []const []const u8, names: []const []const u8, bad: *[]const u8) !Flags {
        const values = try a.alloc(?[]const u8, names.len);
        for (values) |*v| v.* = null;
        var i: usize = 0;
        while (i < argv.len) : (i += 1) {
            const arg = argv[i];
            const k = indexOf(names, arg) orelse {
                bad.* = arg;
                return error.UnknownFlag;
            };
            if (i + 1 >= argv.len) {
                bad.* = arg;
                return error.MissingValue;
            }
            if (values[k] != null) {
                bad.* = arg;
                return error.DuplicateFlag;
            }
            i += 1;
            values[k] = argv[i];
        }
        return .{ .names = names, .values = values };
    }

    pub fn get(self: Flags, name: []const u8) ?[]const u8 {
        const k = indexOf(self.names, name) orelse return null;
        return self.values[k];
    }

    /// The value, or "" when the flag was not given.
    pub fn getOr(self: Flags, name: []const u8) []const u8 {
        return self.get(name) orelse "";
    }
};

fn indexOf(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    return null;
}

/// Append `text` to the file at `path` (made if absent): the way a step
/// writes its output and its summary.
pub fn appendFile(path: []const u8, text: []const u8) !void {
    var f = try std.fs.cwd().createFile(path, .{ .truncate = false });
    defer f.close();
    try f.seekFromEnd(0);
    try f.writeAll(text);
}

/// The answer of one `git` call.
pub const GitOut = struct { code: u8, stdout: []const u8, stderr: []const u8 };

/// Real git, run in `work_dir` (`git -C <dir> <args>`; argv, never a shell).
pub const RealGit = struct {
    work_dir: []const u8,

    pub fn run(self: RealGit, a: std.mem.Allocator, args: []const []const u8) anyerror!GitOut {
        var argv = std.ArrayList([]const u8).empty;
        try argv.appendSlice(a, &.{ "git", "-C", self.work_dir });
        try argv.appendSlice(a, args);
        const r = try std.process.Child.run(.{ .allocator = a, .argv = argv.items, .max_output_bytes = 1 << 24 });
        const code: u8 = switch (r.term) {
            .Exited => |c| c,
            else => 255,
        };
        return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
    }
};
