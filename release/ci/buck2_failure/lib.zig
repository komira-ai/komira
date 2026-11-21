//! What buck2_failure says about a failed buck2 step: the block of the log
//! buck2 wrote last, the message and the summary built from it, and the
//! command line. Pure: no file is read or written here (buck2_failure.zig
//! does that).
const std = @import("std");
const main_red = @import("main_red_lib");

const stripLogLine = main_red.logs.stripLogLine;

/// The most lines of the block.
pub const MAX_LINES = 12;
/// The most bytes of the block, its lines joined by one newline each.
pub const MAX_BYTES = 3000;

pub const USAGE =
    \\usage: buck2_failure --log <path> --step <name> --github-output <path>
    \\                     --summary-file <path>
    \\
;

pub const Args = struct {
    log: []const u8,
    step: []const u8,
    github_output: []const u8,
    summary_file: []const u8,
};

pub const ArgError = error{
    UnknownArgument,
    MissingValue,
    DuplicateArgument,
    MissingLog,
    MissingStep,
    MissingGithubOutput,
    MissingSummaryFile,
};

/// The usage line's reason for `e`.
pub fn argErrorText(e: ArgError) []const u8 {
    return switch (e) {
        error.UnknownArgument => "unknown argument",
        error.MissingValue => "a flag has no value",
        error.DuplicateArgument => "a flag is given twice",
        error.MissingLog => "--log is required",
        error.MissingStep => "--step is required",
        error.MissingGithubOutput => "--github-output is required",
        error.MissingSummaryFile => "--summary-file is required",
    };
}

/// The four flags, each given once with a value.
pub fn parseArgs(argv: []const []const u8) ArgError!Args {
    var log: ?[]const u8 = null;
    var step: ?[]const u8 = null;
    var github_output: ?[]const u8 = null;
    var summary_file: ?[]const u8 = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        const slot: *?[]const u8 = if (std.mem.eql(u8, arg, "--log"))
            &log
        else if (std.mem.eql(u8, arg, "--step"))
            &step
        else if (std.mem.eql(u8, arg, "--github-output"))
            &github_output
        else if (std.mem.eql(u8, arg, "--summary-file"))
            &summary_file
        else
            return error.UnknownArgument;
        i += 1;
        if (i >= argv.len) return error.MissingValue;
        if (slot.* != null) return error.DuplicateArgument;
        slot.* = argv[i];
    }
    return .{
        .log = log orelse return error.MissingLog,
        .step = step orelse return error.MissingStep,
        .github_output = github_output orelse return error.MissingGithubOutput,
        .summary_file = summary_file orelse return error.MissingSummaryFile,
    };
}

/// Whether a stripped line is where buck2 starts to say why it failed.
fn isMarker(line: []const u8) bool {
    return std.mem.eql(u8, line, "BUILD FAILED") or
        std.mem.eql(u8, line, "BXL FAILED") or
        std.mem.eql(u8, line, "TEST FAILED") or
        std.mem.startsWith(u8, line, "Command failed:");
}

/// The longest prefix of `line` that is at most `cap` bytes and does not end
/// inside a UTF-8 sequence.
fn clip(line: []const u8, cap: usize) []const u8 {
    if (line.len <= cap) return line;
    var n = cap;
    while (n > 0 and (line[n] & 0xC0) == 0x80) n -= 1;
    return line[0..n];
}

/// The lines buck2 said about the failure: the stripped, non-empty lines
/// after the last `BUILD FAILED`, `BXL FAILED`, `TEST FAILED` or `Command
/// failed:` line, runner lines (`##[`) skipped, at most MAX_LINES and
/// MAX_BYTES; with no such line, the last MAX_LINES such lines of the log.
/// Empty when the log has none.
pub fn failureBlock(a: std.mem.Allocator, log: []const u8) ![]const []const u8 {
    var lines = std.ArrayList([]const u8).empty;
    var marker: ?usize = null;
    var it = std.mem.splitScalar(u8, log, '\n');
    while (it.next()) |raw| {
        const line = try stripLogLine(a, raw);
        if (isMarker(line)) marker = lines.items.len;
        try lines.append(a, line);
    }
    const from: usize = if (marker) |m| m + 1 else 0;
    var kept = std.ArrayList([]const u8).empty;
    for (lines.items[from..]) |line| {
        if (line.len == 0 or std.mem.startsWith(u8, line, "##[")) continue;
        try kept.append(a, line);
    }
    var cands: []const []const u8 = kept.items;
    if (marker == null and cands.len > MAX_LINES) cands = cands[cands.len - MAX_LINES ..];
    var out = std.ArrayList([]const u8).empty;
    var bytes: usize = 0;
    for (cands) |line| {
        if (out.items.len == MAX_LINES) break;
        const sep: usize = if (out.items.len == 0) 0 else 1;
        if (bytes + sep + line.len > MAX_BYTES) {
            if (out.items.len == 0) try out.append(a, clip(line, MAX_BYTES));
            break;
        }
        bytes += sep + line.len;
        try out.append(a, line);
    }
    return out.toOwnedSlice(a);
}

/// The message: what the step did and what buck2 said.
pub fn message(a: std.mem.Allocator, step: []const u8, block: []const []const u8) ![]u8 {
    if (block.len == 0) {
        return std.fmt.allocPrint(a, "step `{s}` failed and wrote no buck2 output", .{step});
    }
    const body = try std.mem.join(a, "\n", block);
    return std.fmt.allocPrint(a, "step `{s}` failed; buck2 said:\n{s}", .{ step, body });
}

/// `text` as GitHub's workflow-command data: `%` as `%25`, CR as `%0D`, LF
/// as `%0A`, so it is one line.
pub fn escapeData(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    for (text) |c| switch (c) {
        '%' => try out.appendSlice(a, "%25"),
        '\r' => try out.appendSlice(a, "%0D"),
        '\n' => try out.appendSlice(a, "%0A"),
        else => try out.append(a, c),
    };
    return out.toOwnedSlice(a);
}

/// The line to append to $GITHUB_OUTPUT: `message=<escaped message>`.
pub fn outputLine(a: std.mem.Allocator, msg: []const u8) ![]u8 {
    const escaped = try escapeData(a, msg);
    return std.fmt.allocPrint(a, "message={s}\n", .{escaped});
}

/// The text to append to the step summary: the failed step, then the block
/// as a markdown code block (each line indented by four spaces).
pub fn summaryText(a: std.mem.Allocator, step: []const u8, block: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, try std.fmt.allocPrint(a, "release-macos FAILED: step `{s}`.\n", .{step}));
    if (block.len > 0) {
        try out.append(a, '\n');
        for (block) |line| {
            try out.appendSlice(a, "    ");
            try out.appendSlice(a, line);
            try out.append(a, '\n');
        }
    }
    return out.toOwnedSlice(a);
}
