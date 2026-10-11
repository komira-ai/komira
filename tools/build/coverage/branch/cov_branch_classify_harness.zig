//! The harness of cov_branch_classify's cases (README.md#tests), imported by
//! the cov_branch_classify_*_test.zig files, each `zig test` of one run as a
//! build action by a `zig_test` that names the shipped executable in `exes`
//! (a validation of `:cov_branch_classify`). A case runs that executable as
//! a child process, with an empty environment, in a directory of its own:
//! the library's sources (fixtures/{a,b,c,d,gen,t}.src) staged as
//! `<SRC>/<name>.mojo`, the made-up [src] the fixtures' IR names, and the IR
//! of the case in `v.ll`. It reads back the exit status, stdout, stderr and
//! the output file, so a case checks what `main` adds (argv[1..], messages
//! on stderr, the exit status, the output written or not) as well as the
//! classification. The IR edits (`Ir`) are line edits, each failing the case
//! when it changes nothing, so no case checks an unedited fixture.

const std = @import("std");
const exes = @import("exes");
const Alloc = std.mem.Allocator;

pub const case_ll = @embedFile("fixtures/case.ll");
pub const case_golden = @embedFile("fixtures/case.golden.info");
pub const rules_ll = @embedFile("fixtures/rules.ll");
pub const rules_golden = @embedFile("fixtures/rules.golden.info");
pub const try_ll = @embedFile("fixtures/try.ll");
pub const try_golden = @embedFile("fixtures/try.golden.info");
pub const c_src = @embedFile("fixtures/c.src");
pub const d_src = @embedFile("fixtures/d.src");
pub const t_src = @embedFile("fixtures/t.src");

const Source = struct { name: []const u8, bytes: []const u8 };
const sources = [_]Source{
    .{ .name = "a", .bytes = @embedFile("fixtures/a.src") },
    .{ .name = "b", .bytes = @embedFile("fixtures/b.src") },
    .{ .name = "c", .bytes = c_src },
    .{ .name = "d", .bytes = d_src },
    .{ .name = "gen", .bytes = @embedFile("fixtures/gen.src") },
    .{ .name = "t", .bytes = t_src },
};

/// The library's [src] as the fixtures' IR names it, relative to the
/// directory the classifier runs in.
pub const SRC = "buck-out/v2/art/cell/src/pkg/__pkg__/0123456789abcdef/src/pkg";
pub const MAP = [_][]const u8{ "--map", SRC ++ "/=src/pkg/" };
pub const STD = [_][]const u8{ "--stdlib", "oss/modular/" };
pub const EXC = STD ++ [_][]const u8{ "--exclude", "oss/modular/", "--exclude", "buck-out/", "--exclude-file", "tests/test_a.mojo", "--exclude-file", "<unknown>", "--gen", "gen.mojo" };
pub const OUT = "out.info";
pub const IO = [_][]const u8{ "--ir", "v.ll", "--out", OUT };

pub const Run = struct {
    name: []const u8,
    code: u8,
    stdout: []const u8,
    stderr: []const u8,
    out: ?[]const u8,

    fn bad(r: Run, comptime fmt: []const u8, args: anytype) error{TestUnexpectedResult} {
        std.debug.print("{s}: " ++ fmt ++ "\n--- exit {d}; stdout:\n{s}\n--- stderr:\n{s}\n", .{r.name} ++ args ++ .{ r.code, r.stdout, r.stderr });
        return error.TestUnexpectedResult;
    }

    /// Exit `code`, nothing on stdout.
    pub fn exits(r: Run, code: u8) !void {
        if (r.code != code) return r.bad("exit {d}, want {d}", .{ r.code, code });
        if (r.stdout.len != 0) return r.bad("something on stdout", .{});
    }

    /// `msg` on stderr.
    pub fn says(r: Run, msg: []const u8) !void {
        if (std.mem.indexOf(u8, r.stderr, msg) == null) return r.bad("stderr does not say '{s}'", .{msg});
    }

    /// `msg` not on stderr.
    pub fn silent(r: Run, msg: []const u8) !void {
        if (std.mem.indexOf(u8, r.stderr, msg) != null) return r.bad("stderr says '{s}'", .{msg});
    }

    pub fn output(r: Run) ![]const u8 {
        return r.out orelse return r.bad("no output was written", .{});
    }

    pub fn nothing_written(r: Run) !void {
        if (r.out != null) return r.bad("an output was written", .{});
    }

    /// The output is `want` byte for byte.
    pub fn golden(r: Run, want: []const u8, why: []const u8) !void {
        const got = try r.output();
        if (!std.mem.eql(u8, got, want)) {
            std.debug.print("{s}: {s}\n--- want:\n{s}\n--- got:\n{s}\n", .{ r.name, why, want, got });
            return error.TestUnexpectedResult;
        }
    }

    /// The output holds the line `line` (grep -x).
    pub fn has(r: Run, line: []const u8, why: []const u8) !void {
        if (count(try r.output(), line, .exact) == 0) return r.bad("{s} (no line '{s}' in the output:\n{s})", .{ why, line, r.out.? });
    }

    /// The output holds no line starting with `prefix`.
    pub fn lacks(r: Run, prefix: []const u8, why: []const u8) !void {
        if (count(try r.output(), prefix, .prefix) != 0) return r.bad("{s} (a line starts '{s}' in the output:\n{s})", .{ why, prefix, r.out.? });
    }

    /// The output holds `s` nowhere.
    pub fn lacksText(r: Run, s: []const u8, why: []const u8) !void {
        if (std.mem.indexOf(u8, try r.output(), s) != null) return r.bad("{s} ('{s}' is in the output)", .{ why, s });
    }

    /// The output holds `n` lines starting with `prefix`.
    pub fn counts(r: Run, prefix: []const u8, n: usize, why: []const u8) !void {
        const got = count(try r.output(), prefix, .prefix);
        if (got != n) return r.bad("{s} ({d} lines start '{s}', want {d})", .{ why, got, prefix, n });
    }
};

pub const Match = enum { exact, prefix, contains };

pub fn count(text: []const u8, s: []const u8, m: Match) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        const hit = switch (m) {
            .exact => std.mem.eql(u8, l, s),
            .prefix => std.mem.startsWith(u8, l, s),
            .contains => std.mem.indexOf(u8, l, s) != null,
        };
        if (hit) n += 1;
    }
    return n;
}

/// One case: a directory of its own with the library's sources staged.
pub const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    name: []const u8 = "",

    pub fn init(name: []const u8) !Case {
        var c = Case{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator), .tmp = std.testing.tmpDir(.{}), .name = name };
        errdefer c.deinit();
        for (sources) |s| try c.source(s.name, s.bytes);
        return c;
    }

    pub fn deinit(self: *Case) void {
        self.tmp.cleanup();
        self.arena.deinit();
    }

    pub fn a(self: *Case) Alloc {
        return self.arena.allocator();
    }

    pub fn write(self: *Case, path: []const u8, bytes: []const u8) !void {
        if (std.fs.path.dirname(path)) |d| try self.tmp.dir.makePath(d);
        var f = try self.tmp.dir.createFile(path, .{});
        defer f.close();
        try f.writeAll(bytes);
    }

    pub fn read(self: *Case, path: []const u8) ![]const u8 {
        return self.tmp.dir.readFileAlloc(self.a(), path, 1 << 24);
    }

    pub fn remove(self: *Case, path: []const u8) !void {
        try self.tmp.dir.deleteFile(path);
    }

    pub fn mkdir(self: *Case, path: []const u8) !void {
        try self.tmp.dir.makePath(path);
    }

    /// `<SRC>/<name>.mojo` holding `bytes`.
    pub fn source(self: *Case, name: []const u8, bytes: []const u8) !void {
        try self.write(try std.fmt.allocPrint(self.a(), "{s}/{s}.mojo", .{ SRC, name }), bytes);
    }

    /// The executable run with `args`, the output file removed first.
    pub fn exec(self: *Case, args: []const []const u8) !Run {
        const al = self.a();
        self.tmp.dir.deleteFile(OUT) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
        const exe = try std.fs.cwd().realpathAlloc(al, exes.cov_branch_classify);
        var argv = std.ArrayList([]const u8).init(al);
        try argv.append(exe);
        try argv.appendSlice(args);
        var env = std.process.EnvMap.init(al);
        const r = try std.ChildProcess.run(.{
            .allocator = al,
            .argv = argv.items,
            .cwd_dir = self.tmp.dir,
            .env_map = &env,
            .max_output_bytes = 1 << 22,
        });
        const code: u8 = switch (r.term) {
            .Exited => |c| c,
            else => {
                std.debug.print("{s}: cov_branch_classify did not exit: {any}; stderr:\n{s}\n", .{ self.name, r.term, r.stderr });
                return error.TestUnexpectedResult;
            },
        };
        const out = self.tmp.dir.readFileAlloc(al, OUT, 1 << 24) catch |e| switch (e) {
            error.FileNotFound => null,
            else => return e,
        };
        return .{ .name = self.name, .code = code, .stdout = r.stdout, .stderr = r.stderr, .out = out };
    }

    /// `ir` in v.ll, classified with the cases' usual flags (the shell's
    /// `$MAP $EXC`).
    pub fn run(self: *Case, ir: []const u8) !Run {
        try self.write("v.ll", ir);
        return self.exec(&(IO ++ MAP ++ EXC));
    }

    /// Refused: exit 1, `msg` on stderr, no output.
    pub fn refused(self: *Case, name: []const u8, msg: []const u8, ir: []const u8) !Run {
        self.name = name;
        const r = try self.run(ir);
        try r.exits(1);
        try r.says(msg);
        try r.nothing_written();
        return r;
    }

    /// Accepted: exit 0, `msg` on stderr.
    pub fn accepted(self: *Case, name: []const u8, ir: []const u8, msg: []const u8) !Run {
        self.name = name;
        const r = try self.run(ir);
        try r.exits(0);
        try r.says(msg);
        return r;
    }
};

/// IR as lines, edited as sed and awk edit a file: every line is printed
/// with a newline. Each edit fails when it changes nothing.
pub const Ir = struct {
    al: Alloc,
    lines: std.ArrayList([]const u8),

    pub fn of(al: Alloc, bytes: []const u8) !Ir {
        var ir = Ir{ .al = al, .lines = std.ArrayList([]const u8).init(al) };
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |l| try ir.lines.append(l);
        if (bytes.len > 0 and bytes[bytes.len - 1] == '\n') _ = ir.lines.pop();
        return ir;
    }

    pub fn text(self: *const Ir) ![]const u8 {
        var b = std.ArrayList(u8).init(self.al);
        for (self.lines.items) |l| {
            try b.appendSlice(l);
            try b.append('\n');
        }
        return b.items;
    }

    fn unchanged(what: []const u8, s: []const u8) error{TestUnexpectedResult} {
        std.debug.print("the edit ({s} '{s}') changes nothing, so its case checks nothing\n", .{ what, s });
        return error.TestUnexpectedResult;
    }

    /// sed 's/^old/new/': the prefix `old` of each line replaced.
    pub fn subStart(self: *Ir, old: []const u8, new: []const u8) !void {
        var n: usize = 0;
        for (self.lines.items) |*l| {
            if (std.mem.startsWith(u8, l.*, old)) {
                l.* = try std.mem.concat(self.al, u8, &.{ new, l.*[old.len..] });
                n += 1;
            }
        }
        if (n == 0) return unchanged("subStart", old);
    }

    /// sed 's/^prefix.*/line/': each line starting with `prefix` replaced.
    pub fn subLine(self: *Ir, prefix: []const u8, line: []const u8) !void {
        var n: usize = 0;
        for (self.lines.items) |*l| {
            if (std.mem.startsWith(u8, l.*, prefix)) {
                l.* = line;
                n += 1;
            }
        }
        if (n == 0) return unchanged("subLine", prefix);
    }

    /// sed 's/^old$/new/': each line equal to `old` replaced.
    pub fn subExact(self: *Ir, old: []const u8, new: []const u8) !void {
        var n: usize = 0;
        for (self.lines.items) |*l| {
            if (std.mem.eql(u8, l.*, old)) {
                l.* = new;
                n += 1;
            }
        }
        if (n == 0) return unchanged("subExact", old);
    }

    /// sed 's/old/new/': the first `old` of each line replaced, in lines
    /// [from, to).
    pub fn subIn(self: *Ir, from: usize, to: usize, old: []const u8, new: []const u8) !usize {
        var n: usize = 0;
        for (self.lines.items[from..to]) |*l| {
            if (std.mem.indexOf(u8, l.*, old)) |i| {
                l.* = try std.mem.concat(self.al, u8, &.{ l.*[0..i], new, l.*[i + old.len ..] });
                n += 1;
            }
        }
        return n;
    }

    pub fn sub(self: *Ir, old: []const u8, new: []const u8) !void {
        if (try self.subIn(0, self.lines.items.len, old, new) == 0) return unchanged("sub", old);
    }

    /// awk '{ print } $0 == at { print add }': `add` after each line `at`.
    pub fn insertAfter(self: *Ir, at: []const u8, add: []const []const u8) !void {
        var i: usize = 0;
        var n: usize = 0;
        while (i < self.lines.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.lines.items[i], at)) {
                try self.lines.insertSlice(i + 1, add);
                i += add.len;
                n += 1;
            }
        }
        if (n == 0) return unchanged("insertAfter", at);
    }

    /// awk '/^prefix/ { print add } { print }': `add` before each line
    /// starting with `prefix`.
    pub fn insertBefore(self: *Ir, prefix: []const u8, add: []const []const u8) !void {
        var i: usize = 0;
        var n: usize = 0;
        while (i < self.lines.items.len) : (i += 1) {
            if (std.mem.startsWith(u8, self.lines.items[i], prefix)) {
                try self.lines.insertSlice(i, add);
                i += add.len;
                n += 1;
            }
        }
        if (n == 0) return unchanged("insertBefore", prefix);
    }

    pub fn append(self: *Ir, add: []const []const u8) !void {
        try self.lines.appendSlice(add);
    }

    /// grep -v: the lines matching `s` dropped.
    pub fn drop(self: *Ir, s: []const u8, m: Match) !void {
        var kept = std.ArrayList([]const u8).init(self.al);
        for (self.lines.items) |l| {
            const hit = switch (m) {
                .exact => std.mem.eql(u8, l, s),
                .prefix => std.mem.startsWith(u8, l, s),
                .contains => std.mem.indexOf(u8, l, s) != null,
            };
            if (!hit) try kept.append(l);
        }
        if (kept.items.len == self.lines.items.len) return unchanged("drop", s);
        self.lines = kept;
    }

    /// The lines [start, end) of the function whose `define` line holds
    /// `marker`, its `}` excluded (awk's `/^define .*marker/ { s = 1 }
    /// s && /^}$/ { s = 0 }`).
    pub fn function(self: *const Ir, marker: []const u8) ![2]usize {
        for (self.lines.items, 0..) |l, i| {
            if (!std.mem.startsWith(u8, l, "define ") or std.mem.indexOf(u8, l, marker) == null) continue;
            var j = i + 1;
            while (j < self.lines.items.len and !std.mem.eql(u8, self.lines.items[j], "}")) j += 1;
            return .{ i, j };
        }
        return unchanged("function", marker);
    }

    /// The index of the line equal to `line` in [from, to).
    pub fn find(self: *const Ir, from: usize, to: usize, line: []const u8) !usize {
        for (self.lines.items[from..to], from..) |l, i| {
            if (std.mem.eql(u8, l, line)) return i;
        }
        return unchanged("find", line);
    }
};
