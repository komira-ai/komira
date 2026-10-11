//! The lint kind whose reader is an awk program run by the pinned busybox:
//! public_boundary (public_boundary.awk). This file lists the tree and runs
//! the reader.

const std = @import("std");
const lint = @import("lint.zig");
const Ctx = lint.Ctx;

const binary_suffixes = [_][]const u8{
    "arrow", "orc",  "parquet", "avro", "tensor", "frame", "request", "whl",   "conda",   "gz",  "tgz",
    "xz",    "zst",  "bz2",     "tar",  "zip",    "jar",   "png",     "jpg",   "jpeg",    "gif", "ico",
    "pdf",   "der",  "so",      "a",    "o",      "dylib", "wasm",    "mojoc", "mojopkg",
};

/// Whether `path` is binary data, by its suffix: its path is read, not its bytes.
pub fn isBinary(path: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    const ext = path[dot + 1 ..];
    for (binary_suffixes) |s| if (std.mem.eql(u8, ext, s)) return true;
    return false;
}

fn writeList(c: *Ctx, name: []const u8, items: []const []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(c.alloc);
    for (items) |p| {
        try out.appendSlice(p);
        try out.append('\n');
    }
    const path = try c.scratchPath(name);
    try std.fs.cwd().writeFile(path, out.items);
    return path;
}

/// kind public_boundary, tools <public_boundary.awk>, args <holds> <holds
/// name> <hosts> <hosts name> <deny> <from> <public>: what a public
/// repository may not hold, read from every file under the stage but binary
/// data (by suffix: .arrow, .orc, .parquet, .avro, .tensor, .frame,
/// .request, .whl, .conda and archive, image and object formats), and from
/// the path of every file, binary data included. Nothing is skipped as
/// upstream bytes: upstream sources are pinned downloads, never committed,
/// and what third_party/ and the third_party_srcs test trees commit was
/// written here. No date from the year <from> up to <public>, the first day
/// of the public history (date), home directory naming a person (home_path),
/// private or written-out network address (ip), URL host outside the
/// reserved example names and <hosts> (host), email address outside the
/// reserved example domains (email), commit id in prose (commit_sha), or word
/// of <deny> (deny). public_boundary.awk, the reader, says what each rule
/// matches. <holds>, rows `<rule> <file> <count> <reason>`, holds the
/// findings a file must keep (fixtures, test vectors), at an exact count, so
/// it only shrinks; <hosts>, rows `<domain> <reason>`, the domains whose
/// hosts a URL may name, each used by the tree; `#` lines and blank lines are
/// comments in both. <deny> is `-` or a list of words kept outside the
/// repository (one per line), which no row may hold. The <name>s are what
/// findings call the ledgers.
pub fn publicBoundary(c: *Ctx, tools: []const []const u8, args: []const []const u8) !void {
    if (tools.len != 1 or args.len != 7) return error.Usage;
    const awk = try c.abs(tools[0]);
    const holds = try c.abs(args[0]);
    const hosts = try c.abs(args[2]);
    const deny = if (std.mem.eql(u8, args[4], "-")) "/dev/null" else try c.abs(args[4]);

    const paths = try lint.listFiles(c.alloc, c.stage);
    var files = std.ArrayList([]const u8).init(c.alloc);
    for (paths) |p| if (!isBinary(p)) try files.append(p);
    c.checked = files.items.len;
    const files_list = try writeList(c, "files", files.items);
    const paths_list = try writeList(c, "paths", paths);

    const a = c.alloc;
    const argv = [_][]const u8{
        c.busybox, "awk", "-F", "\t",
        "-v", try std.fmt.allocPrint(a, "P={s}/", .{c.stage}),
        "-v", try std.fmt.allocPrint(a, "HN={s}", .{args[1]}),
        "-v", try std.fmt.allocPrint(a, "AN={s}", .{args[3]}),
        "-v", try std.fmt.allocPrint(a, "FROM={s}", .{args[5]}),
        "-v", try std.fmt.allocPrint(a, "PUBLIC={s}", .{args[6]}),
        "-f", awk,
        files_list, paths_list, hosts, deny, holds,
    };
    const r = try lint.runTool(c.alloc, &argv, c.stage);
    // A reader that fails is a finding, never a pass.
    if (r.code != 0) {
        var head = std.ArrayList(u8).init(c.alloc);
        var el = lint.Lines.init(r.stderr);
        while (el.next()) |line| {
            if (el.n > 3) break;
            if (el.n > 1) try head.append('\n');
            try head.appendSlice(line);
        }
        try c.finding("public_boundary: the reader failed: {s}", .{head.items});
    }
    try c.report.appendSlice(try lint.sortLines(c.alloc, r.stdout));
}
