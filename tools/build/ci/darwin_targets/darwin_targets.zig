//! darwin_targets: writes the targets of the macOS part of the pull request's check
//! (.github/workflows/pr.yml, step `the macOS targets to build`) from the log of the step before it,
//! `select the macOS targets`, which ran tools/build/ci/darwin.bxl:select through the buck2-farm
//! action.
//!
//!     darwin_targets --log <buck2-farm.log> --out <darwin_targets.txt> --github-output <file>
//!
//! The log is buck2's output, stdout and stderr together. darwin.bxl prints one verdict line on
//! stderr, `darwin: <WHOLE|SOME|NONE>: <reason>` after buck2's `[time] ` prefix, and the targets on
//! stdout, one label per line. A target is a line that is a cell name (`[a-z_]+`), `//`, and no space
//! to the end of the line: the shape pr.yml's Linux step `the targets to build` reads.
//!
//! It refuses (exit 1, the reason as a `::error::` line on stderr, nothing written) a log with no
//! verdict line (not the selection's log, or a selection that failed), with more than one, with a
//! verdict other than the three, a NONE with targets, and a WHOLE or SOME without any. Otherwise it
//! writes the targets to --out, one per line (an empty file for NONE), appends `any=true` to
//! --github-output when there is at least one, says on stderr how many it wrote, and exits 0.
//! Exit 2: usage, or a file that cannot be read or written.
const std = @import("std");

pub const Kind = enum { WHOLE, SOME, NONE };

pub const Refusal = error{
    /// No verdict line: the log is not darwin.bxl:select's, or the selection failed.
    NoVerdict,
    /// More than one verdict line.
    ManyVerdicts,
    /// A verdict line whose verdict is not WHOLE, SOME or NONE.
    UnknownVerdict,
    /// A NONE verdict, and targets in the log.
    TargetsWithNone,
    /// A WHOLE or SOME verdict, and no target in the log.
    NoTargets,
};

pub const Usage = error{ UnknownArgument, MissingValue, MissingArgument, RepeatedArgument };

pub const Options = struct { log: []const u8, out: []const u8, github_output: []const u8 };

/// The options of `args` (without the program name). Each of --log, --out and --github-output is
/// given once, with a value.
pub fn parseArgs(args: []const []const u8) Usage!Options {
    var log: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var github_output: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const slot = if (std.mem.eql(u8, args[i], "--log"))
            &log
        else if (std.mem.eql(u8, args[i], "--out"))
            &out
        else if (std.mem.eql(u8, args[i], "--github-output"))
            &github_output
        else
            return error.UnknownArgument;
        if (i + 1 >= args.len) return error.MissingValue;
        if (slot.* != null) return error.RepeatedArgument;
        slot.* = args[i + 1];
    }
    return .{
        .log = log orelse return error.MissingArgument,
        .out = out orelse return error.MissingArgument,
        .github_output = github_output orelse return error.MissingArgument,
    };
}

/// Whether `line` is a target label: `[a-z_]+//`, then at least one character, none a space.
pub fn isLabel(line: []const u8) bool {
    const at = std.mem.indexOf(u8, line, "//") orelse return false;
    if (at == 0) return false;
    for (line[0..at]) |c| if (!(c >= 'a' and c <= 'z') and c != '_') return false;
    const rest = line[at + 2 ..];
    if (rest.len == 0) return false;
    return std.mem.indexOfScalar(u8, rest, ' ') == null;
}

const PREFIX = "darwin: ";

/// The verdict word of `line` when it is a verdict line (`darwin: <word>: ...`, after an optional
/// `[time] ` prefix), else null.
pub fn verdictWord(line: []const u8) ?[]const u8 {
    var body = line;
    if (body.len > 0 and body[0] == '[') {
        const close = std.mem.indexOf(u8, body, "] ") orelse return null;
        body = body[close + 2 ..];
    }
    if (!std.mem.startsWith(u8, body, PREFIX)) return null;
    const rest = body[PREFIX.len..];
    const end = std.mem.indexOf(u8, rest, ": ") orelse return null;
    return rest[0..end];
}

pub const Answer = struct { kind: Kind, targets: []const []const u8 };

/// The verdict and the targets of a selection's log (see the header).
pub fn read(a: std.mem.Allocator, log: []const u8) (Refusal || std.mem.Allocator.Error)!Answer {
    var word: ?[]const u8 = null;
    var targets = std.ArrayList([]const u8).empty;
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        if (verdictWord(line)) |w| {
            if (word != null) return error.ManyVerdicts;
            word = w;
        } else if (isLabel(line)) {
            try targets.append(a, line);
        }
    }
    const kind = std.meta.stringToEnum(Kind, word orelse return error.NoVerdict) orelse return error.UnknownVerdict;
    switch (kind) {
        .NONE => if (targets.items.len != 0) return error.TargetsWithNone,
        .WHOLE, .SOME => if (targets.items.len == 0) return error.NoTargets,
    }
    return .{ .kind = kind, .targets = targets.items };
}

/// The targets file: each target on its own line.
pub fn render(a: std.mem.Allocator, targets: []const []const u8) std.mem.Allocator.Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (targets) |t| {
        try out.appendSlice(a, t);
        try out.append(a, '\n');
    }
    return out.items;
}

/// The `::error::` line of a refusal; null for an error that is not one.
pub fn describe(e: anyerror) ?[]const u8 {
    return switch (e) {
        error.NoVerdict => "::error::the log holds no verdict of darwin.bxl:select: it is not the selection's log, or the selection failed",
        error.ManyVerdicts => "::error::the log holds more than one verdict of darwin.bxl:select",
        error.UnknownVerdict => "::error::the verdict of darwin.bxl:select is not WHOLE, SOME or NONE",
        error.TargetsWithNone => "::error::darwin.bxl:select said NONE and printed targets",
        error.NoTargets => "::error::darwin.bxl:select said WHOLE or SOME and printed no target",
        else => null,
    };
}

/// Appends `any=true` to the step's output file, after what earlier steps wrote there.
fn appendAny(path: []const u8) !void {
    const f = try std.fs.cwd().createFile(path, .{ .truncate = false });
    defer f.close();
    try f.seekFromEnd(0);
    try f.writeAll("any=true\n");
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [512]u8 = undefined;
    var err = std.fs.File.stderr().writer(&buf);
    const raw = try std.process.argsAlloc(a);
    const args = try a.alloc([]const u8, raw.len -| 1);
    for (args, 0..) |*o, i| o.* = raw[i + 1];
    const opts = parseArgs(args) catch {
        try err.interface.writeAll("usage: darwin_targets --log <buck2-farm.log> --out <darwin_targets.txt> --github-output <file>\n");
        try err.interface.flush();
        return 2;
    };
    const log = std.fs.cwd().readFileAlloc(a, opts.log, 1 << 28) catch {
        try err.interface.print("::error::the log {s} cannot be read\n", .{opts.log});
        try err.interface.flush();
        return 2;
    };
    const answer = read(a, log) catch |e| {
        const line = describe(e) orelse return e;
        try err.interface.print("{s}\n", .{line});
        try err.interface.flush();
        return 1;
    };
    std.fs.cwd().writeFile(.{ .sub_path = opts.out, .data = try render(a, answer.targets) }) catch {
        try err.interface.print("::error::the targets file {s} cannot be written\n", .{opts.out});
        try err.interface.flush();
        return 2;
    };
    if (answer.targets.len != 0) appendAny(opts.github_output) catch {
        try err.interface.print("::error::the step output {s} cannot be written\n", .{opts.github_output});
        try err.interface.flush();
        return 2;
    };
    try err.interface.print("darwin_targets: {s}: {d} target(s) for macOS\n", .{ @tagName(answer.kind), answer.targets.len });
    try err.interface.flush();
    return 0;
}
