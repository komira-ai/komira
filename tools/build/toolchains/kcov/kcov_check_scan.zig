// Why Zig: build tools are Zig (tools/build/README.md). The readers of kcov_check.zig
// (kcov_check.sh was a busybox shell script of sed, grep, od, dd, cmp and strings).
//! kcov_check_scan: what the kcov checks read from reports, loader records and ELF
//! files. Each function has a unit test (kcov_check_test.zig).

const std = @import("std");
const A = std.mem.Allocator;

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// `xml` with every `dir` written `name` and the first `timestamp="<digits>"`
/// of each line written `timestamp="0"`.
pub fn normalize(a: A, xml: []const u8, dir: []const u8, name: []const u8) ![]u8 {
    const replaced = if (dir.len == 0) try a.dupe(u8, xml) else try std.mem.replaceOwned(u8, a, xml, dir, name);
    var out = std.ArrayList(u8).init(a);
    var lines = std.mem.splitScalar(u8, replaced, '\n');
    const key = "timestamp=\"";
    while (lines.next()) |l| {
        var done = false;
        var from: usize = 0;
        while (!done) {
            const at = std.mem.indexOfPos(u8, l, from, key) orelse break;
            var e = at + key.len;
            while (e < l.len and l[e] >= '0' and l[e] <= '9') e += 1;
            if (e < l.len and l[e] == '"') {
                try out.appendSlice(l[0..at]);
                try out.appendSlice("timestamp=\"0\"");
                try out.appendSlice(l[e + 1 ..]);
                done = true;
            } else from = at + 1;
        }
        if (!done) try out.appendSlice(l);
        if (lines.peek() != null) try out.append('\n');
    }
    return out.toOwnedSlice();
}

/// The lines of the `<class ...filename="...<file>">` elements of a Cobertura
/// report, from the opening line to the closing `</class>`.
pub fn classLines(a: A, xml: []const u8, file: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    var in_class = false;
    const suffix = try std.fmt.allocPrint(a, "/{s}\"", .{file});
    var lines = std.mem.splitScalar(u8, xml, '\n');
    while (lines.next()) |l| {
        if (!in_class and opensClass(l, suffix)) in_class = true;
        if (in_class) {
            try out.appendSlice(l);
            try out.append('\n');
            if (std.mem.indexOf(u8, l, "</class>") != null) in_class = false;
        }
    }
    return out.toOwnedSlice();
}

/// `<class [^>]*filename="[^"]*/file"`: a `<class ` whose attributes (before
/// any `>`) have a filename ending in `/file"`.
fn opensClass(l: []const u8, suffix: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, l, from, "<class ")) |at| {
        const gt = std.mem.indexOfScalarPos(u8, l, at, '>') orelse l.len;
        const attrs = l[at..gt];
        if (std.mem.indexOf(u8, attrs, "filename=\"")) |f| {
            const rest = attrs[f + "filename=\"".len ..];
            if (std.mem.indexOfScalar(u8, rest, '"')) |q| {
                if (std.mem.endsWith(u8, rest[0 .. q + 1], suffix)) return true;
            }
        }
        from = at + 1;
    }
    return false;
}

/// Whether `class` holds `<line number="<n>" hits="<hits>"/>`; `hits` is `0`
/// for a missed line, or null for any positive count.
pub fn lineHits(a: A, class: []const u8, n: usize, zero: bool) !bool {
    const pre = try std.fmt.allocPrint(a, "<line number=\"{d}\" hits=\"", .{n});
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, class, from, pre)) |at| {
        const s = at + pre.len;
        var e = s;
        while (e < class.len and class[e] >= '0' and class[e] <= '9') e += 1;
        if (e > s and std.mem.startsWith(u8, class[e..], "\"/>")) {
            const digits = class[s..e];
            if (zero) {
                if (std.mem.eql(u8, digits, "0")) return true;
            } else if (digits[0] >= '1' and digits[0] <= '9') return true;
        }
        from = at + 1;
    }
    return false;
}

/// The 1-based numbers of the lines of `src` holding `/* COV:<kind> */`.
pub fn markerLines(a: A, src: []const u8, kind: []const u8) ![]usize {
    const m = try std.fmt.allocPrint(a, "/* COV:{s} */", .{kind});
    var out = std.ArrayList(usize).init(a);
    var lines = std.mem.splitScalar(u8, src, '\n');
    var n: usize = 0;
    while (lines.next()) |l| {
        n += 1;
        if (std.mem.indexOf(u8, l, m) != null) try out.append(n);
    }
    return out.toOwnedSlice();
}

/// The objects an `LD_DEBUG=libs` record initialised: the text after the last
/// `calling init: ` of each line, sorted and unique.
pub fn inits(a: A, record: []const u8) ![][]const u8 {
    var set = std.StringHashMap(void).init(a);
    var lines = std.mem.splitScalar(u8, record, '\n');
    const key = "calling init: ";
    while (lines.next()) |l| {
        if (std.mem.lastIndexOf(u8, l, key)) |at| try set.put(l[at + key.len ..], {});
    }
    var out = std.ArrayList([]const u8).init(a);
    var it = set.keyIterator();
    while (it.next()) |k| try out.append(k.*);
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.toOwnedSlice();
}

fn glibcOutside(path: []const u8, dir: []const u8, decoy: []const u8) bool {
    const base = std.fs.path.basename(path);
    var ok = false;
    for ([_][]const u8{ "libc.so.6", "libm.so.6", "libdl.so.2", "libpthread.so.0", "librt.so.1", "ld-linux-x86-64.so.2" }) |g| {
        if (std.mem.eql(u8, base, g)) ok = true;
    }
    if (!ok) return false;
    if (underDir(path, dir) or underDir(path, decoy)) return false;
    return path.len > 0 and path[0] == '/';
}

fn underDir(path: []const u8, dir: []const u8) bool {
    return path.len > dir.len and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/';
}

/// The first of `paths` (initialised objects) that is neither one of the
/// program's own libraries `own` (`<dir>/bin/../lib/<name>`) nor a glibc
/// library outside `dir` and `decoy`; null when there is none.
pub fn initsStray(a: A, paths: []const []const u8, dir: []const u8, decoy: []const u8, own: []const []const u8) !?[]const u8 {
    outer: for (paths) |p| {
        for (own) |o| {
            const want = try std.fmt.allocPrint(a, "{s}/bin/../lib/{s}", .{ dir, o });
            if (std.mem.eql(u8, p, want)) continue :outer;
        }
        if (glibcOutside(p, dir, decoy)) continue;
        return p;
    }
    return null;
}

/// Whether some run of at least `min` printable bytes (`strings`) of `data` is
/// exactly `word`.
pub fn hasString(data: []const u8, min: usize, word: []const u8) bool {
    var start: ?usize = null;
    var i: usize = 0;
    while (i <= data.len) : (i += 1) {
        const printable = i < data.len and (data[i] == '\t' or (data[i] >= 0x20 and data[i] < 0x7f));
        if (printable) {
            if (start == null) start = i;
        } else if (start) |s| {
            if (i - s >= min and std.mem.eql(u8, data[s..i], word)) return true;
            start = null;
        }
    }
    return false;
}

/// The file offset of the first entry tagged `want` in the PT_DYNAMIC segment
/// of the ELF64 little-endian `d`, or null.
pub fn dynTagOff(d: []const u8, want: u32) ?usize {
    if (d.len < 64) return null;
    const phoff = std.mem.readInt(u32, d[32..36], .little);
    const phent = std.mem.readInt(u16, d[54..56], .little);
    const phnum = std.mem.readInt(u16, d[56..58], .little);
    var i: usize = 0;
    while (i < phnum) : (i += 1) {
        const ph = phoff + i * phent;
        if (ph + 40 > d.len) return null;
        if (std.mem.readInt(u32, d[ph..][0..4], .little) != 2) continue;
        var at: usize = std.mem.readInt(u32, d[ph + 8 ..][0..4], .little);
        const end = at + std.mem.readInt(u32, d[ph + 32 ..][0..4], .little);
        while (at + 16 <= end and at + 16 <= d.len) : (at += 16) {
            const lo = std.mem.readInt(u32, d[at..][0..4], .little);
            const hi = std.mem.readInt(u32, d[at + 4 ..][0..4], .little);
            if (lo == 0 and hi == 0) return null;
            if (lo == want and hi == 0) return at;
        }
        return null;
    }
    return null;
}

/// A zip local header and the data of member `name`: compression `method`,
/// sizes 32-bit, or 0xffffffff with a zip64 extra field holding them.
pub fn zipMember(a: A, name: []const u8, method: u16, zip64: bool, data: []const u8) ![]u8 {
    var o = std.ArrayList(u8).init(a);
    const w = o.writer();
    try w.writeAll(&.{ 0x50, 0x4b, 0x03, 0x04, 0x0a, 0x00, 0x00, 0x00 });
    try w.writeInt(u16, method, .little);
    try w.writeAll(&[_]u8{0} ** 8);
    if (zip64) {
        try w.writeAll(&[_]u8{0xff} ** 8);
    } else {
        try w.writeInt(u32, @intCast(data.len), .little);
        try w.writeInt(u32, @intCast(data.len), .little);
    }
    try w.writeInt(u16, @intCast(name.len), .little);
    try w.writeInt(u16, if (zip64) 20 else 0, .little);
    try w.writeAll(name);
    if (zip64) {
        try w.writeAll(&.{ 0x01, 0x00, 0x10, 0x00 });
        try w.writeInt(u32, @intCast(data.len), .little);
        try w.writeInt(u32, 0, .little);
        try w.writeInt(u32, @intCast(data.len), .little);
        try w.writeInt(u32, 0, .little);
    }
    try w.writeAll(data);
    return o.toOwnedSlice();
}

/// `ls -ld`'s ten-character mode of a file kind and permission bits.
pub fn modeString(kind: std.fs.File.Kind, mode: std.fs.File.Mode) [10]u8 {
    var s: [10]u8 = undefined;
    s[0] = switch (kind) {
        .directory => 'd',
        .sym_link => 'l',
        else => '-',
    };
    const bits = "rwxrwxrwx";
    for (bits, 0..) |c, i| {
        const on = (mode >> @intCast(8 - i)) & 1 == 1;
        s[1 + i] = if (on) c else '-';
    }
    if (mode & 0o4000 != 0) s[3] = if (s[3] == 'x') 's' else 'S';
    if (mode & 0o2000 != 0) s[6] = if (s[6] == 'x') 's' else 'S';
    if (mode & 0o1000 != 0) s[9] = if (s[9] == 'x') 't' else 'T';
    return s;
}

