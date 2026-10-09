//! A tar reader, enough for an image layer: ustar, GNU long names and pax
//! extended headers; and the writer of the layer and archive `image` adds.
//!
//! Every header's checksum is verified. A layer must end with a zero block,
//! so a truncated layer is refused rather than read short. A long name, long
//! link or pax header is for the next entry only; one given twice before an
//! entry, or with no entry after it, is refused.

const std = @import("std");
const C = @import("common.zig");
const Fail = C.Fail;

pub const Kind = enum {
    file,
    hardlink,
    symlink,
    dir,
    /// A device, a FIFO or another special entry: never a regular file.
    other,
};

pub const Entry = struct {
    path: []const u8,
    kind: Kind,
    mode: u32,
    size: u64,
    /// The target of a symbolic or hard link, else empty.
    link: []const u8,
};

pub const BLOCK: usize = 512;

pub fn field(h: []const u8, at: usize, len: usize) []const u8 {
    const f = h[at .. at + len];
    return if (std.mem.indexOfScalar(u8, f, 0)) |n| f[0..n] else f;
}

fn text(b: []const u8, what: []const u8) Fail![]const u8 {
    if (!C.utf8Valid(b)) return C.fail("tar: {s} is not UTF-8", .{what});
    return C.dupe(b);
}

/// An octal field (spaces and NULs around it allowed), or a base-256 one.
pub fn number(h: []const u8, at: usize, len: usize, what: []const u8) Fail!u64 {
    const f = h[at .. at + len];
    if (f[0] & 0x80 != 0) {
        var v: u64 = f[0] & 0x7f;
        for (f[1..]) |b| {
            const m = @mulWithOverflow(v, @as(u64, 256));
            const s = @addWithOverflow(m[0], @as(u64, b));
            if (m[1] != 0 or s[1] != 0) return C.fail("tar: {s} overflows", .{what});
            v = s[0];
        }
        return v;
    }
    var t = C.list(u8);
    for (f) |b| {
        if (b != 0 and b != ' ') C.push(u8, &t, b);
    }
    if (t.items.len == 0) return 0;
    if (!C.utf8Valid(t.items)) return C.fail("tar: {s} is not octal", .{what});
    return C.parseUnsigned(u64, t.items, 8) orelse return C.fail("tar: {s} `{s}` is not octal", .{ what, t.items });
}

pub const Kv = struct { k: []const u8, v: []const u8 };

/// The pax records `<len> <key>=<value>\n` of an extended header; a key
/// given twice is refused, so a header cannot say two things about a field.
fn pax(data: []const u8) Fail![]Kv {
    var out = C.list(Kv);
    var at: usize = 0;
    while (at < data.len) {
        const sp = std.mem.indexOfScalar(u8, data[at..], ' ') orelse return C.failS("tar: a pax record without a length");
        const len_text = data[at .. at + sp];
        const parsed: ?usize = if (C.utf8Valid(len_text)) C.parseUnsigned(usize, len_text, 10) else null;
        const n = parsed orelse return C.failS("tar: a pax record length is not a number");
        if (n <= sp + 1 or n > data.len - at or data[at + n - 1] != '\n') return C.failS("tar: a malformed pax record");
        const rec = data[at + sp + 1 .. at + n - 1];
        const eq = std.mem.indexOfScalar(u8, rec, '=') orelse return C.failS("tar: a pax record without `=`");
        const key = try text(rec[0..eq], "a pax key");
        for (out.items) |kv| {
            if (C.eql(kv.k, key)) return C.fail("tar: pax key `{s}` given twice", .{key});
        }
        C.push(Kv, &out, .{ .k = key, .v = try text(rec[eq + 1 ..], "a pax value") });
        at += n;
    }
    return out.items;
}

fn allZero(b: []const u8) bool {
    for (b) |x| {
        if (x != 0) return false;
    }
    return true;
}

pub fn read(data: []const u8) Fail![]Entry {
    var out = C.list(Entry);
    var at: usize = 0;
    var long_name: ?[]const u8 = null;
    var long_link: ?[]const u8 = null;
    var pax_kv: ?[]Kv = null;
    while (true) {
        if (at > data.len or data.len - at < BLOCK) return C.failS("tar: the archive ends without a zero block");
        const h = data[at .. at + BLOCK];
        if (allZero(h)) {
            if (long_name != null or long_link != null or pax_kv != null) return C.failS("tar: the archive ends after a header for no entry");
            return out.items;
        }
        var sum: u64 = 0;
        for (h, 0..) |b, i| sum += if (i >= 148 and i < 156) ' ' else b;
        if (try number(h, 148, 8, "checksum") != sum) return C.fail("tar: header at byte {d} has a wrong checksum", .{at});
        const flag = h[156];
        var size = try number(h, 124, 12, "size");
        if (!(flag == 'L' or flag == 'K' or flag == 'x' or flag == 'g')) {
            if (pax_kv) |kvs| {
                for (kvs) |kv| {
                    if (C.eql(kv.k, "size")) {
                        size = C.parseUnsigned(u64, kv.v, 10) orelse return C.failS("tar: a pax size is not a number");
                        break;
                    }
                }
            }
        }
        const body = at + BLOCK;
        if (size > data.len - body) return C.failS("tar: an entry runs past the end");
        const sz: usize = @intCast(size);
        const end = body + sz;
        const next = body + (sz + BLOCK - 1) / BLOCK * BLOCK;
        switch (flag) {
            'L' => {
                if (long_name != null) return C.failS("tar: two long names for one entry");
                long_name = try text(field(data[body..end], 0, end - body), "a long name");
            },
            'K' => {
                if (long_link != null) return C.failS("tar: two long links for one entry");
                long_link = try text(field(data[body..end], 0, end - body), "a long link");
            },
            'x' => {
                if (pax_kv != null) return C.failS("tar: two pax headers for one entry");
                pax_kv = try pax(data[body..end]);
            },
            // A global header changes no path of this layer that we read.
            'g' => {},
            else => {
                var path = try text(field(h, 0, 100), "a name");
                // POSIX ustar only: GNU's `ustar  \0` keeps its atime there.
                if (C.eql(h[257..263], "ustar\x00")) {
                    const prefix = try text(field(h, 345, 155), "a name prefix");
                    if (prefix.len != 0) path = C.fmt("{s}/{s}", .{ prefix, path });
                }
                var link = try text(field(h, 157, 100), "a link name");
                if (long_name) |n| {
                    path = n;
                    long_name = null;
                }
                if (long_link) |l| {
                    link = l;
                    long_link = null;
                }
                if (pax_kv) |kvs| {
                    for (kvs) |kv| {
                        if (C.eql(kv.k, "path")) {
                            path = kv.v;
                        } else if (C.eql(kv.k, "linkpath")) {
                            link = kv.v;
                        }
                    }
                    pax_kv = null;
                }
                const kind: Kind = switch (flag) {
                    '0', 0, '7' => .file,
                    '1' => .hardlink,
                    '2' => .symlink,
                    '5' => .dir,
                    else => .other,
                };
                if (kind != .symlink and kind != .hardlink) link = "";
                const mode: u32 = @intCast(try number(h, 100, 8, "mode") & 0o7777);
                C.push(Entry, &out, .{ .path = path, .kind = kind, .mode = mode, .size = size, .link = link });
            },
        }
        at = next;
    }
}

/// An entry to write: a directory's path ends in /.
pub const Item = struct {
    path: []const u8,
    mode: u32,
    data: []const u8,
};

/// Zero-padded octal filling all but the last byte, which is NUL.
pub fn octal(f: []u8, v: u64) Fail!void {
    const digits = f.len - 1;
    const s = C.fmt("{o}", .{v});
    if (s.len > digits) return C.fail("tar: {d} does not fit a {d}-byte field", .{ v, f.len });
    @memset(f[0 .. digits - s.len], '0');
    @memcpy(f[digits - s.len .. digits], s);
    f[digits] = 0;
}

pub fn putHeader(out: *C.List(u8), name: []const u8, flag: u8, mode: u32, size: u64) Fail!void {
    var h = [_]u8{0} ** BLOCK;
    @memcpy(h[0..name.len], name);
    try octal(h[100..108], mode);
    try octal(h[108..116], 0);
    try octal(h[116..124], 0);
    // Past eleven octal digits (8 GiB) the size is base-256: 0x80, then the
    // number big-endian, as GNU tar writes it and `number` reads it.
    octal(h[124..136], size) catch {
        // `octal` wrote nothing: the field is still all NUL.
        h[124] = 0x80;
        std.mem.writeInt(u64, h[128..136], size, .big);
    };
    try octal(h[136..148], 0);
    h[156] = flag;
    @memcpy(h[257..263], "ustar\x00");
    @memcpy(h[263..265], "00");
    @memset(h[148..156], ' ');
    var sum: u64 = 0;
    for (h) |b| sum += b;
    try octal(h[148..155], sum);
    h[155] = ' ';
    C.add(out, &h);
}

fn pad(out: *C.List(u8)) void {
    const want = (out.items.len + BLOCK - 1) / BLOCK * BLOCK;
    out.appendNTimes(0, want - out.items.len) catch C.oom();
}

fn decimalLen(n: usize) usize {
    return C.fmt("{d}", .{n}).len;
}

fn pathLess(_: void, x: Item, y: Item) bool {
    return std.mem.lessThan(u8, x.path, y.path);
}

/// `items` as a tar, sorted by path, uid, gid and mtime 0, a path over 100
/// bytes in a pax header, a size over 8 GiB in base-256, ending with two
/// zero blocks. A path given twice is refused.
pub fn write(given: []const Item) Fail![]u8 {
    const items = C.a().dupe(Item, given) catch C.oom();
    std.mem.sort(Item, items, {}, pathLess);
    var out = C.list(u8);
    for (items, 0..) |e, i| {
        if (i > 0 and C.eql(items[i - 1].path, e.path)) return C.fail("tar: {s} given twice", .{e.path});
        const flag: u8 = if (C.endsWith(e.path, "/")) '5' else '0';
        const p = e.path;
        if (p.len > 100) {
            var len = " path=\n".len + p.len;
            var digits: usize = 1;
            while (decimalLen(len + digits) != digits) {
                digits = decimalLen(len + digits);
            }
            len += digits;
            const rec = C.fmt("{d} path={s}\n", .{ len, e.path });
            try putHeader(&out, "././@PaxHeader", 'x', 0o644, rec.len);
            C.add(&out, rec);
            pad(&out);
        }
        try putHeader(&out, p[0..@min(p.len, 100)], flag, e.mode, e.data.len);
        C.add(&out, e.data);
        pad(&out);
    }
    out.appendNTimes(0, 2 * BLOCK) catch C.oom();
    return out.items;
}
