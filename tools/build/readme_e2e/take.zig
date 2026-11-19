//! `readme_e2e take`: a staged set the build did not make, copied as it is into
//! an output of the build.
//!
//! The release's staged set is files on the machine that runs buck2 (`mopm stage`
//! writes them there; //release/staged_set). An action that takes such files as
//! inputs uploads them before it runs, and buck2 does not share one upload among
//! actions: every `readme_e2e` target that took the set as its `staged` uploaded
//! the whole set itself, all of them at once. Copied by one action first, the set
//! is uploaded once, by that action, and the e2e targets take its output, which
//! the farm already holds.
//!
//! Every regular file below `--staged` is written at the same path below `--out`
//! with the same bytes; a directory is followed, and so is a symbolic link (the set
//! a filegroup hands an action can be links to the files). Nothing is checked or
//! left out: what the set holds is the `verify` command's to judge. Any other kind
//! of entry (a device, a socket, a link to nothing), a directory nested deeper than
//! `max_depth`, or a file that cannot be read or written refuses the set, naming
//! the path.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    staged: []const u8,
    out: []const u8,
};

/// Deeper than any staged set (`<namespace>/<name>/README.md`); a link that leads
/// back to a directory above it would be followed forever.
pub const max_depth: usize = 16;

const Copied = struct { files: usize = 0, bytes: u64 = 0 };

fn refuse(a: Allocator, log: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !bool {
    const line = try std.fmt.allocPrint(a, "readme_e2e take: " ++ fmt ++ "\n", args);
    try log.appendSlice(a, line);
    return false;
}

fn lessThan(_: void, l: []const u8, r: []const u8) bool {
    return std.mem.lessThan(u8, l, r);
}

/// Copies the directory `from` (at `rel` below the set) into `to`. False, with the
/// reason in `log`, when an entry is refused.
fn copyDir(a: Allocator, from: std.fs.Dir, to: std.fs.Dir, rel: []const u8, depth: usize, copied: *Copied, log: *std.ArrayList(u8)) !bool {
    if (depth > max_depth) return refuse(a, log, "{s}: directories nested deeper than {d} (a link back to a directory above it?)", .{ rel, max_depth });
    var names: std.ArrayList([]const u8) = .empty;
    var it = from.iterate();
    while (it.next() catch |e| return refuse(a, log, "cannot list {s}: {s}", .{ rel, @errorName(e) })) |entry| {
        try names.append(a, try a.dupe(u8, entry.name));
    }
    // In name order, so a refusal names the same path every time.
    std.mem.sort([]const u8, names.items, {}, lessThan);
    for (names.items) |name| {
        const path = if (rel.len == 0) name else try std.fs.path.join(a, &.{ rel, name });
        // statFile follows a symbolic link: the kind is that of what it points at.
        const st = from.statFile(name) catch |e| return refuse(a, log, "{s}: {s}", .{ path, @errorName(e) });
        switch (st.kind) {
            .directory => {
                var sub_from = from.openDir(name, .{ .iterate = true }) catch |e| return refuse(a, log, "cannot open {s}: {s}", .{ path, @errorName(e) });
                defer sub_from.close();
                to.makeDir(name) catch |e| return refuse(a, log, "cannot write {s}: {s}", .{ path, @errorName(e) });
                var sub_to = to.openDir(name, .{}) catch |e| return refuse(a, log, "cannot write {s}: {s}", .{ path, @errorName(e) });
                defer sub_to.close();
                if (!try copyDir(a, sub_from, sub_to, path, depth + 1, copied, log)) return false;
            },
            .file => {
                from.copyFile(name, to, name, .{}) catch |e| return refuse(a, log, "cannot copy {s}: {s}", .{ path, @errorName(e) });
                copied.files += 1;
                copied.bytes += st.size;
            },
            else => return refuse(a, log, "{s} is a {s}, not a file or a directory", .{ path, @tagName(st.kind) }),
        }
    }
    return true;
}

/// Writes the copy. False, with the reason in `log`, when the set is refused (the
/// output is then incomplete, and the action fails, so nothing reads it).
pub fn take(a: Allocator, opts: Options, log: *std.ArrayList(u8)) !bool {
    const cwd = std.fs.cwd();
    var from = cwd.openDir(opts.staged, .{ .iterate = true }) catch |e| return refuse(a, log, "cannot open the staged set {s}: {s}", .{ opts.staged, @errorName(e) });
    defer from.close();
    cwd.makePath(opts.out) catch |e| return refuse(a, log, "cannot write {s}: {s}", .{ opts.out, @errorName(e) });
    var to = cwd.openDir(opts.out, .{}) catch |e| return refuse(a, log, "cannot write {s}: {s}", .{ opts.out, @errorName(e) });
    defer to.close();
    var copied: Copied = .{};
    if (!try copyDir(a, from, to, "", 0, &copied, log)) return false;
    const line = try std.fmt.allocPrint(a, "readme_e2e take: {d} file(s), {d} bytes, from {s}\n", .{ copied.files, copied.bytes, opts.staged });
    try log.appendSlice(a, line);
    return true;
}
