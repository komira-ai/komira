//! The text files of a parity case (runner.zig's header says what a case
//! is): quoted words, bodies, `case.txt`, `transcript.txt` and the call log
//! the replay appends to. One parser for the runner and the replay, so the two
//! can never read a transcript differently.
//!
//! A line is words separated by spaces. A word is bare (`exit`, `buck2`,
//! `@stdout`) or quoted: `"..."` with the escapes `\\`, `\"`, `\n`, `\r`,
//! `\t`, `\0` and `\xHH`; every other byte stands for itself, so a quoted
//! word holds any bytes. `quote` writes the form `parseLine` reads back.
const std = @import("std");

pub const Error = error{Syntax} || std.mem.Allocator.Error;

/// The reason of the last error.Syntax, with its line (1-based; 0 when the
/// error is not about one line).
pub const Diag = struct {
    line: usize = 0,
    msg: []const u8 = "",
};

fn fail(diag: *Diag, line: usize, msg: []const u8) Error {
    diag.* = .{ .line = line, .msg = msg };
    return error.Syntax;
}

// ---- words ---------------------------------------------------------------

pub const Word = struct {
    quoted: bool,
    bytes: []const u8,
};

/// The words of one line.
pub fn parseLine(a: std.mem.Allocator, line: []const u8, line_no: usize, diag: *Diag) Error![]Word {
    var out = std.ArrayList(Word).empty;
    var i: usize = 0;
    while (true) {
        while (i < line.len and line[i] == ' ') i += 1;
        if (i == line.len) break;
        if (line[i] != '"') {
            const start = i;
            while (i < line.len and line[i] != ' ') i += 1;
            try out.append(a, .{ .quoted = false, .bytes = line[start..i] });
            continue;
        }
        i += 1;
        var w = std.ArrayList(u8).empty;
        var closed = false;
        while (i < line.len) {
            const c = line[i];
            if (c == '"') {
                closed = true;
                i += 1;
                break;
            }
            if (c != '\\') {
                try w.append(a, c);
                i += 1;
                continue;
            }
            if (i + 1 >= line.len) return fail(diag, line_no, "a quoted word ends in a lone backslash");
            const e = line[i + 1];
            i += 2;
            switch (e) {
                '\\' => try w.append(a, '\\'),
                '"' => try w.append(a, '"'),
                'n' => try w.append(a, '\n'),
                'r' => try w.append(a, '\r'),
                't' => try w.append(a, '\t'),
                '0' => try w.append(a, 0),
                'x' => {
                    if (i + 2 > line.len) return fail(diag, line_no, "\\x needs two hex digits");
                    const v = std.fmt.parseInt(u8, line[i .. i + 2], 16) catch return fail(diag, line_no, "\\x needs two hex digits");
                    try w.append(a, v);
                    i += 2;
                },
                else => return fail(diag, line_no, "unknown escape in a quoted word"),
            }
        }
        if (!closed) return fail(diag, line_no, "a quoted word is not closed");
        if (i < line.len and line[i] != ' ') return fail(diag, line_no, "a quoted word runs into the next one");
        try out.append(a, .{ .quoted = true, .bytes = try w.toOwnedSlice(a) });
    }
    return out.toOwnedSlice(a);
}

/// Appends `bytes` as one quoted word. A valid UTF-8 sequence of more than
/// one byte is kept as it is, so non-ASCII text stays readable; every other
/// byte outside printable ASCII is escaped.
pub fn quote(a: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    try out.append(a, '"');
    var i: usize = 0;
    while (i < bytes.len) {
        const c = bytes[i];
        if (c >= 0x80) {
            const n = std.unicode.utf8ByteSequenceLength(c) catch 0;
            if (n > 1 and i + n <= bytes.len and std.unicode.utf8ValidateSlice(bytes[i .. i + n])) {
                try out.appendSlice(a, bytes[i .. i + n]);
                i += n;
                continue;
            }
            try out.writer(a).print("\\x{x:0>2}", .{c});
            i += 1;
            continue;
        }
        switch (c) {
            '\\' => try out.appendSlice(a, "\\\\"),
            '"' => try out.appendSlice(a, "\\\""),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            else => if (c < 0x20 or c == 0x7f) try out.writer(a).print("\\x{x:0>2}", .{c}) else try out.append(a, c),
        }
        i += 1;
    }
    try out.append(a, '"');
}

/// `argv` as quoted words separated by spaces (for messages and the log).
pub fn quoteArgv(a: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    for (argv, 0..) |w, k| {
        if (k > 0) try out.append(a, ' ');
        try quote(a, &out, w);
    }
    return out.toOwnedSlice(a);
}

// ---- bodies --------------------------------------------------------------

/// Where `@name` and `%name` words of a body are read from: the case's own
/// directory and the cases' shared one. Null: such a word is an error (the
/// replay reads a transcript the runner resolved).
pub const Files = struct {
    case_dir: ?[]const u8 = null,
    common_dir: ?[]const u8 = null,
};

/// The bytes of a body: the concatenation of its words, each a quoted word,
/// `*<n>` then a quoted word (that word n times), `@<file>` (a file of the
/// case) or `%<file>` (a file of the shared directory). No word: empty.
pub fn body(a: std.mem.Allocator, words: []const Word, files: Files, line_no: usize, diag: *Diag) Error![]u8 {
    var out = std.ArrayList(u8).empty;
    var k: usize = 0;
    while (k < words.len) : (k += 1) {
        const w = words[k];
        if (w.quoted) {
            try out.appendSlice(a, w.bytes);
            continue;
        }
        if (w.bytes.len > 1 and w.bytes[0] == '*') {
            const n = std.fmt.parseInt(usize, w.bytes[1..], 10) catch return fail(diag, line_no, "`*<n>` needs a count");
            if (k + 1 >= words.len or !words[k + 1].quoted) return fail(diag, line_no, "`*<n>` needs a quoted word after it");
            k += 1;
            for (0..n) |_| try out.appendSlice(a, words[k].bytes);
            continue;
        }
        if (w.bytes.len > 1 and (w.bytes[0] == '@' or w.bytes[0] == '%')) {
            const dir = (if (w.bytes[0] == '@') files.case_dir else files.common_dir) orelse
                return fail(diag, line_no, "a file word where no directory is given");
            if (!safeRelative(w.bytes[1..])) return fail(diag, line_no, "a file word must be a relative path inside its directory");
            const path = try std.fs.path.join(a, &.{ dir, w.bytes[1..] });
            const bytes = std.fs.cwd().readFileAlloc(a, path, 1 << 28) catch return fail(diag, line_no, "a file word names a file that cannot be read");
            try out.appendSlice(a, bytes);
            continue;
        }
        return fail(diag, line_no, "a body word is a quoted word, `*<n>`, `@<file>` or `%<file>`");
    }
    return out.toOwnedSlice(a);
}

/// A relative path with no empty, `.` or `..` component.
pub fn safeRelative(p: []const u8) bool {
    if (p.len == 0 or p[0] == '/') return false;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |c| {
        if (c.len == 0 or std.mem.eql(u8, c, ".") or std.mem.eql(u8, c, "..")) return false;
    }
    return true;
}

fn number(comptime T: type, words: []const Word, line_no: usize, diag: *Diag) Error!T {
    if (words.len != 2 or words[1].quoted) return fail(diag, line_no, "expected one number");
    return std.fmt.parseInt(T, words[1].bytes, 10) catch return fail(diag, line_no, "expected one number");
}

// ---- case.txt ------------------------------------------------------------

pub const Stream = enum { stdout, stderr };

/// A file of the tree the subject runs in, at `path` from its root.
pub const File = struct { path: []const u8, bytes: []const u8 };

/// A file the argv names: `{name}` in an `arg` is its path.
pub const Input = struct { name: []const u8, bytes: []const u8 };

/// A declared divergence: in `stream`, the subject may print `other` where
/// the golden holds `golden`.
pub const Alt = struct { stream: Stream, golden: []const u8, other: []const u8 };

pub const Case = struct {
    args: []const []const u8,
    files: []const File,
    inputs: []const Input,
    exit: u8,
    alts: []const Alt,
};

/// case.txt: one directive per line; `#` starts a comment line.
///
///   arg "<word>"                one word of the subject's argv, in order;
///                               `{name}` in it is the path of input `name`
///   input <name> <body>         a file the argv names
///   file "<path>" <body>        a file of the tree (no body: an empty file)
///   exit <n>                    the golden exit code
///   alt stdout|stderr "<golden>" "<other>"
///                               an allowed divergence (runner.zig: `applyAlts`)
pub fn parseCase(a: std.mem.Allocator, text: []const u8, files: Files, diag: *Diag) Error!Case {
    var args = std.ArrayList([]const u8).empty;
    var tree = std.ArrayList(File).empty;
    var inputs = std.ArrayList(Input).empty;
    var alts = std.ArrayList(Alt).empty;
    var exit: ?u8 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (it.next()) |line| {
        n += 1;
        if (line.len == 0 or line[0] == '#') continue;
        const w = try parseLine(a, line, n, diag);
        if (w.len == 0) continue;
        if (w[0].quoted) return fail(diag, n, "a line starts with its directive");
        const d = w[0].bytes;
        if (std.mem.eql(u8, d, "arg")) {
            if (w.len != 2 or !w[1].quoted) return fail(diag, n, "`arg` takes one quoted word");
            try args.append(a, w[1].bytes);
        } else if (std.mem.eql(u8, d, "input")) {
            if (w.len < 2 or w[1].quoted or w[1].bytes.len == 0) return fail(diag, n, "`input` takes a bare name, then a body");
            for (inputs.items) |x| if (std.mem.eql(u8, x.name, w[1].bytes)) return fail(diag, n, "an input is declared twice");
            try inputs.append(a, .{ .name = w[1].bytes, .bytes = try body(a, w[2..], files, n, diag) });
        } else if (std.mem.eql(u8, d, "file")) {
            if (w.len < 2 or !w[1].quoted) return fail(diag, n, "`file` takes a quoted path, then a body");
            if (!safeRelative(w[1].bytes) or std.mem.startsWith(u8, w[1].bytes, ".parity/") or std.mem.eql(u8, w[1].bytes, "buck2"))
                return fail(diag, n, "a file's path is relative, inside the tree, and not the replay's");
            for (tree.items) |x| if (std.mem.eql(u8, x.path, w[1].bytes)) return fail(diag, n, "a file is declared twice");
            try tree.append(a, .{ .path = w[1].bytes, .bytes = try body(a, w[2..], files, n, diag) });
        } else if (std.mem.eql(u8, d, "exit")) {
            if (exit != null) return fail(diag, n, "`exit` is given twice");
            exit = try number(u8, w, n, diag);
        } else if (std.mem.eql(u8, d, "alt")) {
            if (w.len != 4 or w[1].quoted or !w[2].quoted or !w[3].quoted) return fail(diag, n, "`alt` takes stdout|stderr and two quoted words");
            const s: Stream = if (std.mem.eql(u8, w[1].bytes, "stdout")) .stdout else if (std.mem.eql(u8, w[1].bytes, "stderr")) .stderr else return fail(diag, n, "`alt` names stdout or stderr");
            if (w[3].bytes.len == 0) return fail(diag, n, "an `alt`'s other text is not empty");
            try alts.append(a, .{ .stream = s, .golden = w[2].bytes, .other = w[3].bytes });
        } else return fail(diag, n, "unknown directive");
    }
    return .{
        .args = try args.toOwnedSlice(a),
        .files = try tree.toOwnedSlice(a),
        .inputs = try inputs.toOwnedSlice(a),
        .exit = exit orelse return fail(diag, 0, "case.txt gives no `exit`"),
        .alts = try alts.toOwnedSlice(a),
    };
}

// ---- transcript.txt ------------------------------------------------------

pub const End = union(enum) { exit: u8, signal: u8 };

/// One recorded call: `argv[0]` is the program's basename.
pub const Entry = struct {
    argv: []const []const u8,
    end: End,
    stdout: []const u8,
    stderr: []const u8,
};

/// transcript.txt: entries, each opened by a `call` line.
///
///   call <program> "<arg>"...   the program's basename (bare or quoted) and
///                               every argument, exactly
///   exit <n> | signal <n>       how the call ends (one of them)
///   stdout <body>               what it prints (lines concatenate)
///   stderr <body>
pub fn parseTranscript(a: std.mem.Allocator, text: []const u8, files: Files, diag: *Diag) Error![]Entry {
    var out = std.ArrayList(Entry).empty;
    var argv: ?[]const []const u8 = null;
    var end: ?End = null;
    var so = std.ArrayList(u8).empty;
    var se = std.ArrayList(u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    var opened_at: usize = 0;
    while (true) {
        const next = it.next();
        n += 1;
        const line = next orelse "";
        const w: []const Word = if (next == null or line.len == 0 or line[0] == '#') &.{} else try parseLine(a, line, n, diag);
        const opens = w.len > 0 and !w[0].quoted and std.mem.eql(u8, w[0].bytes, "call");
        if (next == null or opens) {
            if (argv) |v| {
                try out.append(a, .{
                    .argv = v,
                    .end = end orelse return fail(diag, opened_at, "a call has no `exit` or `signal`"),
                    .stdout = try so.toOwnedSlice(a),
                    .stderr = try se.toOwnedSlice(a),
                });
            }
            if (next == null) break;
            if (w.len < 2) return fail(diag, n, "`call` names the program");
            if (w[1].bytes.len == 0 or std.mem.indexOfScalar(u8, w[1].bytes, '/') != null) return fail(diag, n, "a call's program is a basename");
            var v = std.ArrayList([]const u8).empty;
            for (w[1..], 0..) |x, k| {
                if (k > 0 and !x.quoted) return fail(diag, n, "a call's arguments are quoted words");
                try v.append(a, x.bytes);
            }
            argv = try v.toOwnedSlice(a);
            end = null;
            opened_at = n;
            continue;
        }
        if (w.len == 0) continue;
        if (argv == null) return fail(diag, n, "a line before the first `call`");
        if (w[0].quoted) return fail(diag, n, "a line starts with its directive");
        const d = w[0].bytes;
        if (std.mem.eql(u8, d, "exit") or std.mem.eql(u8, d, "signal")) {
            if (end != null) return fail(diag, n, "a call ends twice");
            const v = try number(u8, w, n, diag);
            end = if (d[0] == 'e') .{ .exit = v } else .{ .signal = v };
        } else if (std.mem.eql(u8, d, "stdout")) {
            try so.appendSlice(a, try body(a, w[1..], files, n, diag));
        } else if (std.mem.eql(u8, d, "stderr")) {
            try se.appendSlice(a, try body(a, w[1..], files, n, diag));
        } else return fail(diag, n, "unknown directive");
    }
    return out.toOwnedSlice(a);
}

/// The transcript as `parseTranscript` reads it back with no file words:
/// what the runner hands the replay.
pub fn renderTranscript(a: std.mem.Allocator, entries: []const Entry) ![]u8 {
    var out = std.ArrayList(u8).empty;
    for (entries) |e| {
        try out.appendSlice(a, "call ");
        try out.appendSlice(a, try quoteArgv(a, e.argv));
        switch (e.end) {
            .exit => |v| try out.writer(a).print("\nexit {d}\n", .{v}),
            .signal => |v| try out.writer(a).print("\nsignal {d}\n", .{v}),
        }
        try out.appendSlice(a, "stdout ");
        try quote(a, &out, e.stdout);
        try out.appendSlice(a, "\nstderr ");
        try quote(a, &out, e.stderr);
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

/// Whether two argvs are the same call: the same program basename and the
/// same arguments, byte for byte.
pub fn sameCall(x: []const []const u8, y: []const []const u8) bool {
    if (x.len != y.len or x.len == 0) return false;
    if (!std.mem.eql(u8, std.fs.path.basename(x[0]), std.fs.path.basename(y[0]))) return false;
    for (x[1..], y[1..]) |p, q| if (!std.mem.eql(u8, p, q)) return false;
    return true;
}

/// The index of the entry answering `argv` when `prior` calls with the same
/// argv were answered before it: the (prior+1)-th entry for that argv, in
/// transcript order. Null: the transcript does not hold it.
pub fn answerIndex(entries: []const Entry, argv: []const []const u8, prior: usize) ?usize {
    var seen: usize = 0;
    for (entries, 0..) |e, k| {
        if (!sameCall(e.argv, argv)) continue;
        if (seen == prior) return k;
        seen += 1;
    }
    return null;
}

// ---- the call log --------------------------------------------------------

/// One call the subject made, as the replay logged it: `recorded` is false
/// for a call the transcript could not answer.
pub const Call = struct { recorded: bool, argv: []const []const u8 };

/// The log line of a call: `call` or `unrecorded`, then the argv quoted.
pub fn logLine(a: std.mem.Allocator, recorded: bool, argv: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, if (recorded) "call " else "unrecorded ");
    try out.appendSlice(a, try quoteArgv(a, argv));
    try out.append(a, '\n');
    return out.toOwnedSlice(a);
}

pub fn parseLog(a: std.mem.Allocator, text: []const u8, diag: *Diag) Error![]Call {
    var out = std.ArrayList(Call).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (it.next()) |line| {
        n += 1;
        if (line.len == 0) continue;
        const w = try parseLine(a, line, n, diag);
        if (w.len < 2 or w[0].quoted) return fail(diag, n, "a log line is `call` or `unrecorded`, then the argv");
        const recorded = std.mem.eql(u8, w[0].bytes, "call");
        if (!recorded and !std.mem.eql(u8, w[0].bytes, "unrecorded")) return fail(diag, n, "a log line is `call` or `unrecorded`, then the argv");
        var v = std.ArrayList([]const u8).empty;
        for (w[1..]) |x| try v.append(a, x.bytes);
        try out.append(a, .{ .recorded = recorded, .argv = try v.toOwnedSlice(a) });
    }
    return out.toOwnedSlice(a);
}

/// How many calls of `log` are recorded calls with the same argv as `argv`.
pub fn priorCalls(log: []const Call, argv: []const []const u8) usize {
    var n: usize = 0;
    for (log) |c| {
        if (c.recorded and sameCall(c.argv, argv)) n += 1;
    }
    return n;
}
