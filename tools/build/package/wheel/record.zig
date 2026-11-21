//! komira_wheel runtime-record: the record a wheel carries of a runtime it
//! does not carry, so its loader can tell that the copy it finds installed is
//! the build the wheel was made with.
//!
//! The record is text, one entry per line, each `<key>\t<value>\n`:
//!
//!   requirement\t<the requirement that installs the runtime>
//!   <file name>\t<its GNU build id, lowercase hex>     (one per library)
//!
//! The requirement comes first; the libraries follow in the order given.
//! komira's external wheel carries it at `komira/_lib/mojo_runtime.tsv`, and
//! komira/_runtime.py reads it (docs/design/python_package.md, the two
//! flavours).
//!
//! The build id is the GNU build id note (owner `GNU`, type
//! NT_GNU_BUILD_ID) of a PT_NOTE segment, read through the program headers
//! as the loader's own reader does. 64-bit little-endian ELF only; a library
//! without a build id, a note or header outside the file, two libraries of
//! one file name, and a requirement holding a tab or a line break are
//! refused.

const std = @import("std");
const cli = @import("cli.zig");
const diag = @import("diag.zig");
const Alloc = std.mem.Allocator;
const Diag = diag.Diag;
const Refused = diag.Refused;
const refuse = diag.refuse;

pub const Library = struct {
    /// The file name the record gives it (the loader looks for it by name).
    name: []const u8,
    data: []const u8,
};

const PT_NOTE = 4;
const NT_GNU_BUILD_ID = 3;

fn align4(n: u64) u64 {
    return (n +| 3) & ~@as(u64, 3);
}

fn int(comptime T: type, b: []const u8, at: u64) ?T {
    const n = @sizeOf(T);
    if (at > b.len or b.len - at < n) return null;
    return std.mem.readInt(T, b[@intCast(at)..][0..n], .little);
}

/// The GNU build id of `data` (the ELF file named `name`): the descriptor of
/// the first NT_GNU_BUILD_ID note owned by `GNU` in a PT_NOTE segment.
pub fn buildId(alloc: Alloc, d: *Diag, name: []const u8, data: []const u8) Refused![]const u8 {
    if (data.len < 64 or !std.mem.eql(u8, data[0..4], "\x7fELF")) return refuse(d, alloc, "{s}: not an ELF file", .{name});
    if (data[4] != 2 or data[5] != 1) return refuse(d, alloc, "{s}: not a 64-bit little-endian ELF file", .{name});
    const phoff = int(u64, data, 0x20).?;
    const phentsize = int(u16, data, 0x36).?;
    const phnum = int(u16, data, 0x38).?;
    if (phentsize != 56) return refuse(d, alloc, "{s}: a program header entry that is not 56 bytes", .{name});
    var i: u64 = 0;
    while (i < phnum) : (i += 1) {
        const at = phoff +| i *| 56;
        const kind = int(u32, data, at) orelse return refuse(d, alloc, "{s}: a program header past the end of the file", .{name});
        if (kind != PT_NOTE) continue;
        const offset = int(u64, data, at +| 8) orelse return refuse(d, alloc, "{s}: a program header past the end of the file", .{name});
        const size = int(u64, data, at +| 32) orelse return refuse(d, alloc, "{s}: a program header past the end of the file", .{name});
        if (offset > data.len or size > data.len - offset) return refuse(d, alloc, "{s}: a note segment past the end of the file", .{name});
        const end = offset + size;
        var note = offset;
        while (end - note >= 12) {
            const namesz = int(u32, data, note).?;
            const descsz = int(u32, data, note + 4).?;
            const kind_n = int(u32, data, note + 8).?;
            const name_at = note + 12;
            const desc_at = name_at +| align4(namesz);
            if (desc_at > end or descsz > end - desc_at) return refuse(d, alloc, "{s}: a note past the end of its segment", .{name});
            if (kind_n == NT_GNU_BUILD_ID and namesz == 4 and std.mem.eql(u8, data[@intCast(name_at)..@intCast(name_at + 4)], "GNU\x00")) {
                if (descsz == 0) return refuse(d, alloc, "{s}: an empty GNU build id", .{name});
                return data[@intCast(desc_at)..@intCast(desc_at + descsz)];
            }
            note = desc_at +| align4(descsz);
            if (note > end) break;
        }
    }
    return refuse(d, alloc, "{s}: no GNU build id note; the loader could not tell its build from another", .{name});
}

/// The record of `libs`, installed by `requirement`.
pub fn record(alloc: Alloc, d: *Diag, requirement: []const u8, libs: []const Library) Refused![]const u8 {
    if (requirement.len == 0 or std.mem.indexOfAny(u8, requirement, "\t\r\n") != null)
        return refuse(d, alloc, "--requirement `{s}` is empty or holds a tab or a line break", .{requirement});
    if (libs.len == 0) return refuse(d, alloc, "no --library: the record names the libraries it is the record of", .{});
    var out = std.ArrayList(u8).empty;
    try out.print(alloc, "requirement\t{s}\n", .{requirement});
    for (libs, 0..) |lib, i| {
        for (libs[0..i]) |prev| {
            if (std.mem.eql(u8, prev.name, lib.name)) return refuse(d, alloc, "two libraries are named {s}", .{lib.name});
        }
        const id = try buildId(alloc, d, lib.name, lib.data);
        try out.print(alloc, "{s}\t{x}\n", .{ lib.name, id });
    }
    return out.toOwnedSlice(alloc);
}

/// `runtime-record`'s flags (`--requirement <r>`, `--library <file>` once or
/// more, `--out <record>`) read into the record's text and where it goes.
/// Each library is named by its file name.
pub fn command(alloc: Alloc, d: *Diag, argv: []const []const u8) Refused!struct { out: []const u8, text: []const u8 } {
    const a = try cli.parseOnly(alloc, d, argv, &.{ "--requirement", "--library", "--out" });
    var libs = std.ArrayList(Library).empty;
    for (try a.all(alloc, "--library")) |path| {
        try libs.append(alloc, .{ .name = diag.baseName(path), .data = try cli.readFile(alloc, d, path) });
    }
    const requirement = try a.one(alloc, d, "--requirement");
    const out = try a.one(alloc, d, "--out");
    return .{ .out = out, .text = try record(alloc, d, requirement, libs.items) };
}
