//! What every lint kind shares: the context a kind writes its findings to,
//! the readers of files, lines and trees, the runner of a pinned tool, and
//! the validation result Buck2 reads.

const std = @import("std");
const Alloc = std.mem.Allocator;

/// The largest input read whole, and the most output kept from a tool.
pub const max_bytes = 1 << 30;

/// One lint run: the findings so far and how many inputs were checked.
pub const Ctx = struct {
    alloc: Alloc,
    /// The staged copies of the linted files (a buck-out directory). Findings
    /// name them under it; `result` renames them.
    stage: []const u8,
    /// A directory of this run's own, an absolute path, for lists the tools read.
    scratch: []const u8,
    /// The findings, one per line, each ending in a newline.
    report: std.ArrayList(u8),
    /// The inputs checked: a run that checks none fails.
    checked: usize = 0,

    pub fn init(alloc: Alloc, stage: []const u8, scratch: []const u8) Ctx {
        return .{ .alloc = alloc, .stage = stage, .scratch = scratch, .report = std.ArrayList(u8).init(alloc) };
    }

    /// Adds one finding line.
    pub fn finding(c: *Ctx, comptime fmt: []const u8, args: anytype) !void {
        try c.report.writer().print(fmt ++ "\n", args);
    }

    /// Adds what a tool printed, as lines.
    pub fn appendOutput(c: *Ctx, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try c.report.appendSlice(bytes);
        if (bytes[bytes.len - 1] != '\n') try c.report.append('\n');
    }

    /// `p`, made absolute against the working directory.
    pub fn abs(c: *Ctx, p: []const u8) ![]const u8 {
        if (std.fs.path.isAbsolute(p)) return p;
        const cwd = try std.process.getCwdAlloc(c.alloc);
        return std.fs.path.join(c.alloc, &.{ cwd, p });
    }

    /// A path under the scratch directory.
    pub fn scratchPath(c: *Ctx, name: []const u8) ![]const u8 {
        return std.fs.path.join(c.alloc, &.{ c.scratch, name });
    }
};

/// The whole of the file at `path` (relative to the working directory, or absolute).
pub fn readFile(alloc: Alloc, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(alloc, path, max_bytes) catch |err| {
        std.debug.print("lint: cannot read {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
}

/// The lines of `text`: newline-terminated lines, plus a last line without one.
pub const Lines = struct {
    it: std.mem.SplitIterator(u8, .scalar),
    /// The number of the line `next` returned last, from 1.
    n: usize = 0,

    pub fn init(text: []const u8) Lines {
        const body = if (text.len > 0 and text[text.len - 1] == '\n') text[0 .. text.len - 1] else text;
        var l = Lines{ .it = std.mem.splitScalar(u8, body, '\n') };
        if (text.len == 0) _ = l.it.next();
        return l;
    }

    pub fn next(l: *Lines) ?[]const u8 {
        const line = l.it.next() orelse return null;
        l.n += 1;
        return line;
    }
};

/// The number of lines of `text`, as `Lines` counts them.
pub fn countLines(text: []const u8) usize {
    var l = Lines.init(text);
    while (l.next()) |_| {}
    return l.n;
}

/// POSIX [[:space:]].
pub fn isSpace(b: u8) bool {
    return b == ' ' or (b >= '\t' and b <= '\r');
}

pub fn skipSpace(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len and isSpace(s[i])) i += 1;
    return i;
}

/// Whether `s` holds a non-space byte (awk `/[^[:space:]]/`).
pub fn hasNonSpace(s: []const u8) bool {
    return skipSpace(s, 0) < s.len;
}

/// Whether `s` is blank or a `#` comment (awk `/^[[:space:]]*(#|$)/`).
pub fn isComment(s: []const u8) bool {
    const i = skipSpace(s, 0);
    return i == s.len or s[i] == '#';
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Sorts byte-wise, as `sort` does with no locale.
pub fn sortStrings(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, lessThan);
}

/// Sorts the lines of `text` (each ending in a newline) and returns them so.
pub fn sortLines(alloc: Alloc, text: []const u8) ![]u8 {
    var list = std.ArrayList([]const u8).init(alloc);
    var l = Lines.init(text);
    while (l.next()) |line| try list.append(line);
    sortStrings(list.items);
    var out = std.ArrayList(u8).init(alloc);
    for (list.items) |line| {
        try out.appendSlice(line);
        try out.append('\n');
    }
    return out.toOwnedSlice();
}

/// Every file and symbolic link under `dir_path`, as paths relative to it,
/// sorted (`find . -type f -o -type l`, less the `./`).
pub fn listFiles(alloc: Alloc, dir_path: []const u8) ![][]const u8 {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("lint: cannot open {s}: {s}\n", .{ dir_path, @errorName(err) });
        return err;
    };
    defer dir.close();
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    var out = std.ArrayList([]const u8).init(alloc);
    while (try walker.next()) |e| {
        if (e.kind != .file and e.kind != .sym_link) continue;
        try out.append(try alloc.dupe(u8, e.path));
    }
    sortStrings(out.items);
    return out.toOwnedSlice();
}

/// Copies every file under `src_path` to the same path under `dest_path`,
/// making the directories.
pub fn copyTree(alloc: Alloc, src_path: []const u8, dest_path: []const u8) !void {
    try std.fs.cwd().makePath(dest_path);
    var dest = try std.fs.cwd().openDir(dest_path, .{});
    defer dest.close();
    var src = try std.fs.cwd().openDir(src_path, .{});
    defer src.close();
    for (try listFiles(alloc, src_path)) |p| {
        if (std.fs.path.dirname(p)) |d| try dest.makePath(d);
        try src.copyFile(p, dest, p, .{});
    }
}

/// What a tool did: its exit code (null when a signal ended it) and its
/// output, standard output then standard error.
pub const Ran = struct {
    code: ?u32,
    stdout: []const u8,
    stderr: []const u8,
};

/// Runs `argv` in `cwd` (null: the working directory) and returns what it did.
pub fn runTool(alloc: Alloc, argv: []const []const u8, cwd: ?[]const u8) !Ran {
    const r = std.ChildProcess.run(.{
        .allocator = alloc,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = max_bytes,
    }) catch |err| {
        std.debug.print("lint: cannot run {s}: {s}\n", .{ argv[0], @errorName(err) });
        return err;
    };
    const code: ?u32 = switch (r.term) {
        .Exited => |c| c,
        else => null,
    };
    return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
}

/// The lines of the report shown in the result's message.
pub const max_message_lines = 200;

/// The validation result Buck2 reads (ValidationInfo): status "failure" with
/// the findings as the message when there are any, "success" with the number
/// of inputs checked otherwise. Findings naming a file under `stage` name it
/// `prefix` + its path in the stage instead. A run that checked nothing is a
/// finding.
pub fn result(alloc: Alloc, kind: []const u8, stage: []const u8, prefix: []const u8, report: []const u8, checked: usize) ![]u8 {
    var text = std.ArrayList(u8).init(alloc);
    if (report.len > 0) {
        const from = try std.mem.concat(alloc, u8, &.{ stage, "/" });
        const n = std.mem.replacementSize(u8, report, from, prefix);
        try text.resize(n);
        _ = std.mem.replace(u8, report, from, prefix, text.items);
    }
    if (checked == 0) try text.writer().print("{s}: checked nothing (no inputs, or no lines to check)\n", .{kind});

    var out = std.ArrayList(u8).init(alloc);
    const w = out.writer();
    if (text.items.len == 0) {
        try w.print("{{\"version\": 1, \"data\": {{\"status\": \"success\", \"message\": \"{s}: {d} checked\"}}}}\n", .{ kind, checked });
        return out.toOwnedSlice();
    }
    try w.print("{{\"version\": 1, \"data\": {{\"status\": \"failure\", \"message\": \"{s}: {d} finding line(s)\\n", .{ kind, countLines(text.items) });
    var lines = Lines.init(text.items);
    while (lines.next()) |line| {
        if (lines.n > max_message_lines) break;
        for (line) |b| switch (b) {
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            '\t' => try w.writeAll("\\t"),
            0...8, 11...31 => {},
            else => try w.writeByte(b),
        };
        try w.writeAll("\\n");
    }
    try w.writeAll("\"}}\n");
    return out.toOwnedSlice();
}
