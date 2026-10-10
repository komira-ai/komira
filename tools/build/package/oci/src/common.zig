//! What every module of komira_oci shares: one arena (the tool runs once and
//! exits, so nothing is freed), the refusal message, file helpers, and the
//! spellings the messages use (an OS error as `<text> (os error <n>)`, a
//! value's debug form) so a refusal reads the same on every path.

const std = @import("std");

pub const posix = if (@hasDecl(std, "posix")) std.posix else std.os;
const linux = std.os.linux;

/// A refusal: its text is `msg`.
pub const Fail = error{Fail};

pub var msg: []const u8 = "";

var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);

pub fn a() std.mem.Allocator {
    return arena_state.allocator();
}

pub fn oom() noreturn {
    @panic("out of memory");
}

pub fn List(comptime T: type) type {
    return std.ArrayList(T);
}

pub fn list(comptime T: type) std.ArrayList(T) {
    return std.ArrayList(T).init(a());
}

pub fn fmt(comptime f: []const u8, args: anytype) []u8 {
    return std.fmt.allocPrint(a(), f, args) catch oom();
}

/// Sets the refusal text and returns the error that carries it.
pub fn fail(comptime f: []const u8, args: anytype) Fail {
    msg = fmt(f, args);
    return error.Fail;
}

pub fn failS(s: []const u8) Fail {
    msg = s;
    return error.Fail;
}

pub fn dupe(s: []const u8) []u8 {
    return a().dupe(u8, s) catch oom();
}

pub fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

pub fn startsWith(s: []const u8, p: []const u8) bool {
    return std.mem.startsWith(u8, s, p);
}

pub fn endsWith(s: []const u8, p: []const u8) bool {
    return std.mem.endsWith(u8, s, p);
}

pub fn contains(s: []const u8, p: []const u8) bool {
    return std.mem.indexOf(u8, s, p) != null;
}

pub fn utf8Valid(s: []const u8) bool {
    return std.unicode.utf8ValidateSlice(s);
}

pub fn push(comptime T: type, l: *std.ArrayList(T), v: T) void {
    l.append(v) catch oom();
}

pub fn add(l: *std.ArrayList(u8), s: []const u8) void {
    l.appendSlice(s) catch oom();
}

pub fn add2(comptime T: type, l: *std.ArrayList(T), s: []const T) void {
    l.appendSlice(s) catch oom();
}

/// `parts` joined by `sep`.
pub fn join(parts: []const []const u8, sep: []const u8) []u8 {
    return std.mem.join(a(), sep, parts) catch oom();
}

/// An unsigned number as Rust's `from_str_radix` reads one: an optional
/// `+`, then one digit or more, no overflow.
pub fn parseUnsigned(comptime T: type, s: []const u8, radix: u8) ?T {
    if (s.len == 0) return null;
    var d = s;
    if (s[0] == '+' or s[0] == '-') {
        if (s.len == 1) return null;
        // `-` is a sign only for a signed type: here it is a bad digit.
        if (s[0] == '+') d = s[1..];
    }
    var v: T = 0;
    for (d) |c| {
        const dig: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'z' => c - 'a' + 10,
            'A'...'Z' => c - 'A' + 10,
            else => return null,
        };
        if (dig >= radix) return null;
        v = std.math.mul(T, v, radix) catch return null;
        v = std.math.add(T, v, dig) catch return null;
    }
    return v;
}

/// `s` without leading and trailing ASCII whitespace.
pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\n\r\x0b\x0c");
}

/// The lines of `s`: split at `\n` or `\r\n`, the last line ending optional.
pub fn lines(s: []const u8) [][]const u8 {
    var out = list([]const u8);
    var at: usize = 0;
    while (at < s.len) {
        const nl = std.mem.indexOfScalarPos(u8, s, at, '\n');
        const end = nl orelse s.len;
        var l = s[at..end];
        if (nl != null and l.len > 0 and l[l.len - 1] == '\r') l = l[0 .. l.len - 1];
        push([]const u8, &out, l);
        at = if (nl) |n| n + 1 else s.len;
    }
    return out.items;
}

/// `x` and `y` as one path, as Rust's `Path::join` makes it: `y` if it is
/// absolute, else one `/` between them.
pub fn pathJoin(x: []const u8, y: []const u8) []u8 {
    if (x.len == 0 or (y.len > 0 and y[0] == '/')) return dupe(y);
    if (x[x.len - 1] == '/') return fmt("{s}{s}", .{ x, y });
    return fmt("{s}/{s}", .{ x, y });
}

/// An OS error as Rust's `io::Error` displays it.
pub fn ioErr(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory (os error 2)",
        error.AccessDenied => "Permission denied (os error 13)",
        error.PathAlreadyExists => "File exists (os error 17)",
        error.NotDir => "Not a directory (os error 20)",
        error.IsDir => "Is a directory (os error 21)",
        error.NoSpaceLeft => "No space left on device (os error 28)",
        error.BrokenPipe => "Broken pipe (os error 32)",
        error.NameTooLong => "File name too long (os error 36)",
        error.SymLinkLoop => "Too many levels of symbolic links (os error 40)",
        error.FileTooBig => "File too large (os error 27)",
        else => @errorName(err),
    };
}

pub const Stat = struct {
    mode: u32,
    size: u64,

    pub fn isDir(s: Stat) bool {
        return s.mode & linux.S.IFMT == linux.S.IFDIR;
    }

    pub fn isFile(s: Stat) bool {
        return s.mode & linux.S.IFMT == linux.S.IFREG;
    }
};

fn statAt(path: []const u8, flags: u32) !Stat {
    const st = try posix.fstatat(std.fs.cwd().fd, path, flags);
    return .{ .mode = @intCast(st.mode), .size = @intCast(st.size) };
}

/// The status of `path` itself (a symbolic link is not followed).
pub fn lstat(path: []const u8) !Stat {
    return statAt(path, linux.AT.SYMLINK_NOFOLLOW);
}

/// The status of what `path` names (symbolic links followed).
pub fn stat(path: []const u8) !Stat {
    return statAt(path, 0);
}

pub fn readFile(path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(a(), path, std.math.maxInt(usize));
}

/// `data` at `path`, created or truncated (mode 0666 less the umask).
pub fn writeFile(path: []const u8, data: []const u8) !void {
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(data);
}

/// `path`'s mode set to `mode`.
pub fn chmod(path: []const u8, mode: u32) !void {
    const st = try stat(path);
    if (st.isDir()) {
        // Opened for reading: fchmod refuses the O_PATH handle a plain openDir gives.
        var d = try std.fs.cwd().openDir(path, .{ .iterate = true });
        defer d.close();
        try d.chmod(mode);
    } else {
        const f = try std.fs.cwd().openFile(path, .{});
        defer f.close();
        try f.chmod(mode);
    }
}

/// The valid prefix, the invalid bytes after it and the rest of `s`, as
/// Rust's `Utf8Chunks` splits it.
const Chunk = struct { valid: []const u8, invalid: []const u8, rest: []const u8 };

fn chunk(s: []const u8) Chunk {
    var i: usize = 0;
    var valid_up_to: usize = 0;
    const at = struct {
        fn f(src: []const u8, j: usize) u8 {
            return if (j < src.len) src[j] else 0;
        }
    }.f;
    const cont = struct {
        fn f(b: u8) bool {
            return @as(i8, @bitCast(b)) < -64;
        }
    }.f;
    while (i < s.len) {
        const b = s[i];
        i += 1;
        if (b >= 128) {
            const w: u8 = switch (b) {
                0xC2...0xDF => 2,
                0xE0...0xEF => 3,
                0xF0...0xF4 => 4,
                else => 0,
            };
            switch (w) {
                2 => {
                    if (!cont(at(s, i))) break;
                    i += 1;
                },
                3 => {
                    const n = at(s, i);
                    const ok = switch (b) {
                        0xE0 => n >= 0xA0 and n <= 0xBF,
                        0xE1...0xEC, 0xEE...0xEF => n >= 0x80 and n <= 0xBF,
                        0xED => n >= 0x80 and n <= 0x9F,
                        else => false,
                    };
                    if (!ok) break;
                    i += 1;
                    if (!cont(at(s, i))) break;
                    i += 1;
                },
                4 => {
                    const n = at(s, i);
                    const ok = switch (b) {
                        0xF0 => n >= 0x90 and n <= 0xBF,
                        0xF1...0xF3 => n >= 0x80 and n <= 0xBF,
                        0xF4 => n >= 0x80 and n <= 0x8F,
                        else => false,
                    };
                    if (!ok) break;
                    i += 1;
                    if (!cont(at(s, i))) break;
                    i += 1;
                    if (!cont(at(s, i))) break;
                    i += 1;
                },
                else => break,
            }
        }
        valid_up_to = i;
    }
    return .{ .valid = s[0..valid_up_to], .invalid = s[valid_up_to..i], .rest = s[i..] };
}

/// `s` with each invalid sequence replaced by U+FFFD, as Rust's
/// `String::from_utf8_lossy` does.
pub fn lossy(s: []const u8) []const u8 {
    if (utf8Valid(s)) return s;
    var out = list(u8);
    var rest = s;
    while (rest.len > 0) {
        const c = chunk(rest);
        add(&out, c.valid);
        if (c.invalid.len > 0) add(&out, "\u{FFFD}");
        rest = c.rest;
    }
    return out.items;
}

/// A character of valid UTF-8 text as Rust's `str` Debug writes it.
fn debugChar(out: *std.ArrayList(u8), cp: u21, bytes: []const u8) void {
    switch (cp) {
        0 => add(out, "\\0"),
        '\t' => add(out, "\\t"),
        '\r' => add(out, "\\r"),
        '\n' => add(out, "\\n"),
        '\\' => add(out, "\\\\"),
        '"' => add(out, "\\\""),
        // Not printable: the controls; combining marks (grapheme extenders).
        0x01...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f...0x9f, 0xad, 0x300...0x36f => add(out, fmt("\\u{{{x}}}", .{cp})),
        else => add(out, bytes),
    }
}

fn debugValid(out: *std.ArrayList(u8), s: []const u8) void {
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepointSlice()) |cs| {
        const cp = std.unicode.utf8Decode(cs) catch unreachable;
        debugChar(out, cp, cs);
    }
}

/// `s` (UTF-8) quoted as Rust's Debug writes a `str`.
pub fn debugStr(s: []const u8) []const u8 {
    var out = list(u8);
    add(&out, "\"");
    debugValid(&out, s);
    add(&out, "\"");
    return out.items;
}

/// Bytes quoted as Rust's Debug writes an `OsStr`: invalid UTF-8 as `\xHH`.
pub fn debugOsStr(s: []const u8) []const u8 {
    var out = list(u8);
    add(&out, "\"");
    var rest = s;
    while (rest.len > 0) {
        const c = chunk(rest);
        debugValid(&out, c.valid);
        for (c.invalid) |b| add(&out, fmt("\\x{X:0>2}", .{b}));
        rest = c.rest;
    }
    add(&out, "\"");
    return out.items;
}

/// An optional list of strings as Rust's Debug writes `Option<&[&str]>`.
pub fn debugOptStrs(v: ?[]const []const u8) []const u8 {
    const l = v orelse return "None";
    var out = list(u8);
    add(&out, "Some([");
    for (l, 0..) |s, i| {
        if (i > 0) add(&out, ", ");
        add(&out, debugStr(s));
    }
    add(&out, "])");
    return out.items;
}

/// Bytes as Rust's `{:02x?}` writes a `&[u8]`.
pub fn debugHex(b: []const u8) []const u8 {
    var out = list(u8);
    add(&out, "[");
    for (b, 0..) |x, i| {
        if (i > 0) add(&out, ", ");
        add(&out, fmt("{x:0>2}", .{x}));
    }
    add(&out, "]");
    return out.items;
}
