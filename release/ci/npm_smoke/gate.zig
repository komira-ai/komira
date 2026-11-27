//! The publish gate: release/npm_publish.txt, the file that says whether npm.yml's `publish` job runs. npm
//! publishing starts only on the owner's go (docs/design/typescript_package.md, D4), and the go is a reviewed
//! change of that file from `publish: off` to `publish: on`.
//!
//! The file is lines: blank lines and lines starting with `#` are comments, and exactly one other line is
//! `publish: off` or `publish: on`. Anything else is refused, naming the line, so a file a merge or a typo left
//! unreadable fails the build job and publishes nothing.
const std = @import("std");
const common = @import("common.zig");

const Allocator = common.Allocator;
const Error = common.Error;
const refuse = common.refuse;

pub const Gate = enum { off, on };

/// The gate `text` (the file at `path`) says.
pub fn parse(a: Allocator, why: *[]const u8, path: []const u8, text: []const u8) Error!Gate {
    var found: ?Gate = null;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        n += 1;
        if (line.len == 0 or line[0] == '#') continue;
        const g: Gate = if (std.mem.eql(u8, line, "publish: off"))
            .off
        else if (std.mem.eql(u8, line, "publish: on"))
            .on
        else
            return refuse(a, why, "{s}:{d}: \"{s}\" is neither `publish: off` nor `publish: on` (nor a comment)", .{ path, n, line });
        if (found != null) return refuse(a, why, "{s}:{d}: a second publish line: the file says off or on once", .{ path, n });
        found = g;
    }
    return found orelse return refuse(a, why, "{s} holds no `publish: off` or `publish: on` line", .{path});
}
