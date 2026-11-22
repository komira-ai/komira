//! prefix_tool's command line: the arguments of each mode, and the files it
//! reads and writes (README.md). The archive is read in this process by
//! `native_objects` (native_elf.zig): a System V archive of ELF objects or a
//! BSD one of Mach-O objects.
//!
//!   prefix_tool header --archive <lib.a> --header <out> --symbols <out>
//!       --style boringssl|strip --prefix <p> [--strip <s>] --min <n>
//!       [--extra <name>]...
//!   prefix_tool check --archive <lib.a> --result <out> --prefix <p>
//!       --min <n> [--allow <pattern>]... [--names <file>]...
//!
//! `outcome` runs one command and returns its exit code and output: 0 when
//! it wrote its outputs, 1 on a refusal or a red check, 2 on bad arguments.

const std = @import("std");
const P = @import("prefix.zig");
const objects = @import("native_objects");

pub const Outcome = struct {
    code: u8,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
};

pub const usage =
    \\usage: prefix_tool header --archive <lib.a> --header <out> --symbols <out>
    \\           --style boringssl|strip --prefix <p> [--strip <s>] --min <n> [--extra <name>]...
    \\       prefix_tool check --archive <lib.a> --result <out> --prefix <p>
    \\           --min <n> [--allow <pattern>]... [--names <file>]...
    \\
;

const many = [_][]const u8{ "--extra", "--allow", "--names" };

/// The flags of one command: each single flag at most once, each of `many`
/// any number of times, in order.
pub const Args = struct {
    mode: []const u8,
    one: std.StringHashMap([]const u8),
    lists: std.StringHashMap(std.ArrayList([]const u8)),

    pub fn parse(argv: []const []const u8) P.Fail!Args {
        if (argv.len < 2) return P.fail("prefix_tool: no mode", .{});
        var r = Args{
            .mode = argv[1],
            .one = std.StringHashMap([]const u8).init(P.a()),
            .lists = std.StringHashMap(std.ArrayList([]const u8)).init(P.a()),
        };
        const single: []const []const u8 = if (std.mem.eql(u8, r.mode, "header"))
            &.{ "--archive", "--header", "--symbols", "--style", "--prefix", "--strip", "--min" }
        else if (std.mem.eql(u8, r.mode, "check"))
            &.{ "--archive", "--result", "--prefix", "--min" }
        else
            return P.fail("prefix_tool: unknown mode {s}", .{r.mode});
        const multi: []const []const u8 = if (std.mem.eql(u8, r.mode, "header")) many[0..1] else many[1..];
        var i: usize = 2;
        while (i < argv.len) : (i += 2) {
            const k = argv[i];
            if (i + 1 >= argv.len) return P.fail("prefix_tool: {s} needs a value", .{k});
            const v = argv[i + 1];
            if (has(multi, k)) {
                const e = r.lists.getOrPut(k) catch P.oom();
                if (!e.found_existing) e.value_ptr.* = std.ArrayList([]const u8).empty;
                e.value_ptr.append(P.a(), v) catch P.oom();
            } else if (has(single, k)) {
                if (r.one.contains(k)) return P.fail("prefix_tool: {s} given twice", .{k});
                r.one.put(k, v) catch P.oom();
            } else return P.fail("prefix_tool {s}: unknown flag {s}", .{ r.mode, k });
        }
        for (single) |k| {
            if (std.mem.eql(u8, k, "--strip")) continue;
            if (!r.one.contains(k)) return P.fail("prefix_tool {s}: {s} is required", .{ r.mode, k });
        }
        return r;
    }

    pub fn get(self: Args, k: []const u8) []const u8 {
        return self.one.get(k) orelse "";
    }

    pub fn list(self: Args, k: []const u8) []const []const u8 {
        return if (self.lists.get(k)) |l| l.items else &.{};
    }

    pub fn min(self: Args) P.Fail!u64 {
        const s = self.get("--min");
        return std.fmt.parseUnsigned(u64, s, 10) catch P.fail("prefix_tool: --min {s} is not a number", .{s});
    }
};

fn has(set: []const []const u8, k: []const u8) bool {
    for (set) |s| {
        if (std.mem.eql(u8, s, k)) return true;
    }
    return false;
}

/// `path` as the messages name it: absolute, from the working directory.
pub fn shown(cwd: []const u8, path: []const u8) []const u8 {
    if (path.len > 0 and path[0] == '/') return path;
    return P.fmt("{s}/{s}", .{ cwd, path });
}

fn read(path: []const u8) P.Fail![]const u8 {
    return std.fs.cwd().readFileAlloc(P.a(), path, std.math.maxInt(usize)) catch |e|
        P.fail("prefix_tool: cannot read {s}: {s}", .{ path, @errorName(e) });
}

/// The symbols of every member of the archive `bytes` (`native_objects`'s
/// `readArchive`); refused, naming `shown_path` and what is wrong, when a
/// member cannot be read: a reader that skips what it cannot read must not
/// pass a check.
pub fn archiveSymbols(bytes: []const u8, shown_path: []const u8) P.Fail![]const P.Sym {
    return objects.readArchive(P.a(), bytes) catch |e| switch (e) {
        error.BadObject => P.fail("prefix_tool: {s}: {s}", .{ shown_path, objects.why }),
        error.OutOfMemory => P.oom(),
    };
}

fn write(path: []const u8, data: []const u8) P.Fail!void {
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = data }) catch |e| return P.fail("prefix_tool: cannot write {s}: {s}", .{ path, @errorName(e) });
}

fn header(args: Args, cwd: []const u8) P.Fail!Outcome {
    const style = std.meta.stringToEnum(P.Style, args.get("--style")) orelse
        return P.fail("prefix_tool: unknown style {s}", .{args.get("--style")});
    const min = try args.min();
    const archive = shown(cwd, args.get("--archive"));
    const syms = try archiveSymbols(try read(args.get("--archive")), archive);
    const names = try P.symbols(P.definedNames(syms), args.list("--extra"), archive, min);
    const text = try P.header(style, args.get("--prefix"), args.get("--strip"), names);
    try write(args.get("--symbols"), P.symbolsFile(names));
    try write(args.get("--header"), text);
    return .{ .code = 0 };
}

fn check(args: Args, cwd: []const u8) P.Fail!Outcome {
    const min = try args.min();
    const archive = shown(cwd, args.get("--archive"));
    const syms = try archiveSymbols(try read(args.get("--archive")), archive);
    var files = std.ArrayList([]const u8).empty;
    for (args.list("--names")) |f| files.append(P.a(), try read(f)) catch P.oom();
    const v = try P.check(syms, files.items, archive, args.get("--prefix"), min, args.list("--allow"));
    if (v.red) return .{ .code = 1, .stderr = v.stderr };
    try write(args.get("--result"), v.result);
    return .{ .code = 0, .stdout = v.stdout };
}

/// Runs the command `argv` (argv[0] is the program) in the working
/// directory `cwd`.
pub fn outcome(argv: []const []const u8, cwd: []const u8) Outcome {
    const args = Args.parse(argv) catch return .{ .code = 2, .stderr = P.fmt("{s}\n{s}", .{ P.msg, usage }) };
    const r = if (std.mem.eql(u8, args.mode, "header")) header(args, cwd) else check(args, cwd);
    return r catch .{ .code = 1, .stderr = P.fmt("{s}\n", .{P.msg}) };
}
