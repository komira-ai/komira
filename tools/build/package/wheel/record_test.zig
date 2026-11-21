//! The runtime record (record.zig): the GNU build id read from a library's
//! note segment, after other notes and past segments of other kinds; and
//! refused for a file that is not 64-bit little-endian ELF, a header or note
//! outside the file, an empty build id, or none at all. The record of three
//! libraries is the requirement line, then a line per library in the order
//! given; a duplicate name, no library and a requirement with a tab or a line
//! break are refused. The command reads its flags and files: each library
//! named by its file name; a wheel flag, a missing flag and an unreadable
//! file refused.

const std = @import("std");
const diag = @import("diag.zig");
const record = @import("record.zig");
const t = std.testing;

const Note = struct { owner: []const u8, kind: u32, desc: []const u8 };

fn put(a: std.mem.Allocator, out: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    try out.appendSlice(a, &b);
}

fn pad4(a: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    while (out.items.len % 4 != 0) try out.append(a, 0);
}

/// A 64-bit little-endian ELF file: the header, a PT_LOAD and a PT_NOTE
/// program header, then the notes the PT_NOTE covers. `note_size` overrides
/// the segment's size; `phnum` the header's count.
fn elf(a: std.mem.Allocator, notes: []const Note, opts: struct { note_size: ?u64 = null, phnum: u16 = 2, phentsize: u16 = 56, class: u8 = 2 }) ![]u8 {
    var body = std.ArrayList(u8).empty;
    for (notes) |n| {
        try put(a, &body, u32, @intCast(n.owner.len));
        try put(a, &body, u32, @intCast(n.desc.len));
        try put(a, &body, u32, n.kind);
        try body.appendSlice(a, n.owner);
        try pad4(a, &body);
        try body.appendSlice(a, n.desc);
        try pad4(a, &body);
    }
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, &.{ 0x7f, 'E', 'L', 'F', opts.class, 1, 1 });
    try out.appendNTimes(a, 0, 9);
    try put(a, &out, u16, 3); // e_type ET_DYN
    try put(a, &out, u16, 62); // e_machine x86-64
    try put(a, &out, u32, 1);
    try put(a, &out, u64, 0); // e_entry
    try put(a, &out, u64, 64); // e_phoff
    try put(a, &out, u64, 0); // e_shoff
    try put(a, &out, u32, 0);
    try put(a, &out, u16, 64);
    try put(a, &out, u16, opts.phentsize);
    try put(a, &out, u16, opts.phnum);
    try put(a, &out, u16, 0);
    try put(a, &out, u16, 0);
    try put(a, &out, u16, 0);
    const notes_at: u64 = 64 + 2 * 56;
    // PT_LOAD over the whole file, then PT_NOTE over the notes.
    for ([_]u32{ 1, 4 }) |kind| {
        try put(a, &out, u32, kind);
        try put(a, &out, u32, 4);
        try put(a, &out, u64, if (kind == 4) notes_at else 0);
        try put(a, &out, u64, 0);
        try put(a, &out, u64, 0);
        const size: u64 = if (kind == 4) (opts.note_size orelse body.items.len) else notes_at + body.items.len;
        try put(a, &out, u64, size);
        try put(a, &out, u64, size);
        try put(a, &out, u64, 4);
    }
    try out.appendSlice(a, body.items);
    return out.toOwnedSlice(a);
}

const GNU = "GNU\x00";

test "the build id: after another note and another owner's, past a PT_LOAD" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const data = try elf(a, &.{
        .{ .owner = GNU, .kind = 1, .desc = "\x00\x00\x00\x00\x03\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00" },
        .{ .owner = "Go\x00\x00", .kind = 3, .desc = "go-build-id" },
        .{ .owner = GNU, .kind = 3, .desc = "\xaa\xbb\xcc\x01\x02" },
    }, .{});
    try t.expectEqualSlices(u8, "\xaa\xbb\xcc\x01\x02", try record.buildId(a, &d, "lib.so", data));
}

test "the build id refused: no note, an empty id, not ELF64 little-endian, outside the file" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const cases = [_]struct { data: []const u8, want: []const u8 }{
        .{ .data = try elf(a, &.{.{ .owner = "Go\x00\x00", .kind = 3, .desc = "x" }}, .{}), .want = "lib.so: no GNU build id note; the loader could not tell its build from another" },
        .{ .data = try elf(a, &.{}, .{}), .want = "lib.so: no GNU build id note; the loader could not tell its build from another" },
        .{ .data = try elf(a, &.{.{ .owner = GNU, .kind = 3, .desc = "" }}, .{}), .want = "lib.so: an empty GNU build id" },
        .{ .data = "not an ELF file, but at least sixty-four bytes long, so the magic is what fails", .want = "lib.so: not an ELF file" },
        .{ .data = "\x7fELF", .want = "lib.so: not an ELF file" },
        .{ .data = try elf(a, &.{}, .{ .class = 1 }), .want = "lib.so: not a 64-bit little-endian ELF file" },
        .{ .data = try elf(a, &.{}, .{ .phentsize = 32 }), .want = "lib.so: a program header entry that is not 56 bytes" },
        .{ .data = try elf(a, &.{}, .{ .phnum = 9 }), .want = "lib.so: a program header past the end of the file" },
        .{ .data = try elf(a, &.{.{ .owner = GNU, .kind = 3, .desc = "\x01" }}, .{ .note_size = 4096 }), .want = "lib.so: a note segment past the end of the file" },
        .{ .data = try elf(a, &.{.{ .owner = GNU, .kind = 3, .desc = "\x01\x02\x03\x04\x05\x06\x07\x08" }}, .{ .note_size = 20 }), .want = "lib.so: a note past the end of its segment" },
    };
    for (cases) |c| {
        try t.expectError(error.Refused, record.buildId(a, &d, "lib.so", c.data));
        try t.expectEqualStrings(c.want, d.msg);
    }
}

test "the record: the requirement, then each library's build id in the order given" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const libs = [_]record.Library{
        .{ .name = "libB.so", .data = try elf(a, &.{.{ .owner = GNU, .kind = 3, .desc = "\x0b\x0b" }}, .{}) },
        .{ .name = "libA.so", .data = try elf(a, &.{.{ .owner = GNU, .kind = 3, .desc = "\xa0\x01\xff" }}, .{}) },
    };
    try t.expectEqualStrings(
        "requirement\tmojo-compiler==1.0.0\nlibB.so\t0b0b\nlibA.so\ta001ff\n",
        try record.record(a, &d, "mojo-compiler==1.0.0", &libs),
    );
}

test "the record refused: no library, two of one name, a library without an id, a bad requirement" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const good = try elf(a, &.{.{ .owner = GNU, .kind = 3, .desc = "\x01" }}, .{});
    try t.expectError(error.Refused, record.record(a, &d, "r==1", &.{}));
    try t.expectEqualStrings("no --library: the record names the libraries it is the record of", d.msg);
    try t.expectError(error.Refused, record.record(a, &d, "r==1", &.{ .{ .name = "x.so", .data = good }, .{ .name = "x.so", .data = good } }));
    try t.expectEqualStrings("two libraries are named x.so", d.msg);
    try t.expectError(error.Refused, record.record(a, &d, "r==1", &.{.{ .name = "y.so", .data = try elf(a, &.{}, .{}) }}));
    try t.expectEqualStrings("y.so: no GNU build id note; the loader could not tell its build from another", d.msg);
    for ([_][]const u8{ "", "a\tb", "a\nb", "a\rb" }) |bad| {
        try t.expectError(error.Refused, record.record(a, &d, bad, &.{.{ .name = "x.so", .data = good }}));
        try t.expectEqualStrings(try std.fmt.allocPrint(a, "--requirement `{s}` is empty or holds a tab or a line break", .{bad}), d.msg);
    }
}

test "the command: libraries named by their file names, its own flags only" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("lib");
    try tmp.dir.writeFile(.{ .sub_path = "lib/libX.so", .data = try elf(a, &.{.{ .owner = GNU, .kind = 3, .desc = "\x12\x34" }}, .{}) });
    const lib = try std.fs.path.join(a, &.{ try tmp.dir.realpathAlloc(a, "."), "lib", "libX.so" });
    var d = diag.Diag{};
    const r = try record.command(a, &d, &.{ "--requirement", "mojo-compiler==1.0.0", "--library", lib, "--out", "out/r.tsv" });
    try t.expectEqualStrings("out/r.tsv", r.out);
    try t.expectEqualStrings("requirement\tmojo-compiler==1.0.0\nlibX.so\t1234\n", r.text);

    try t.expectError(error.Refused, record.command(a, &d, &.{ "--requirement", "r==1", "--library", lib, "--out", "o", "--name", "komira" }));
    try t.expectEqualStrings("unknown argument --name", d.msg);
    try t.expectError(error.Refused, record.command(a, &d, &.{ "--library", lib, "--out", "o" }));
    try t.expectEqualStrings("missing --requirement", d.msg);
    try t.expectError(error.Refused, record.command(a, &d, &.{ "--requirement", "r==1", "--library", lib }));
    try t.expectEqualStrings("missing --out", d.msg);
    const gone = try std.fs.path.join(a, &.{ try tmp.dir.realpathAlloc(a, "."), "gone.so" });
    try t.expectError(error.Refused, record.command(a, &d, &.{ "--requirement", "r==1", "--library", gone, "--out", "o" }));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "cannot read {s}: FileNotFound", .{gone}), d.msg);
}
