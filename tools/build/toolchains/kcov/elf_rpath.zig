//! elf_rpath: turn the DT_RUNPATH of an ELF64 little-endian file into a
//! DT_RPATH, in place.
//!
//! usage: elf_rpath <file>
//!
//! The loader searches a DT_RPATH before LD_LIBRARY_PATH, and a DT_RUNPATH
//! after it; a DT_RUNPATH also does not apply to a library another library
//! dlopens (glibc's pthread_cancel loads libgcc_s.so.1). kcov runs with the
//! LD_LIBRARY_PATH of the program under test, so its run path must be a
//! DT_RPATH. zig 0.12 passes `--disable-new-dtags` to lld for a shared
//! library only, so an executable it links always gets a DT_RUNPATH; this is
//! the byte edit `--disable-new-dtags` would have made: the tag of the one
//! DT_RUNPATH entry (29) becomes DT_RPATH (15), and its string is untouched.
//!
//! Refuses, with exit status 2 and the file untouched, anything but an
//! x86_64 executable or shared object (ET_EXEC or ET_DYN, EM_X86_64) with
//! one PT_DYNAMIC header whose segment has exactly one DT_RUNPATH and no
//! DT_RPATH. An error opening, reading or writing the file exits 1.

const std = @import("std");

const ET_EXEC: u16 = 2;
const ET_DYN: u16 = 3;
const EM_X86_64: u16 = 62;
const PT_DYNAMIC: u32 = 2;
const DT_NULL: u64 = 0;
const DT_RPATH: u64 = 15;
const DT_RUNPATH: u64 = 29;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("elf_rpath: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn rd(comptime T: type, b: []const u8, at: usize) T {
    if (at + @sizeOf(T) > b.len) fail("truncated ELF file", .{});
    return std.mem.readInt(T, b[at..][0..@sizeOf(T)], .little);
}

/// The file offset of the d_tag of the one DT_RUNPATH entry.
fn runpathTag(b: []const u8) usize {
    if (b.len < 64 or !std.mem.eql(u8, b[0..4], "\x7fELF")) fail("not an ELF file", .{});
    if (b[4] != 2 or b[5] != 1) fail("not ELF64 little-endian", .{});
    const e_type = rd(u16, b, 0x10);
    if (e_type != ET_EXEC and e_type != ET_DYN) fail("e_type {d} is neither ET_EXEC nor ET_DYN", .{e_type});
    const e_machine = rd(u16, b, 0x12);
    if (e_machine != EM_X86_64) fail("e_machine {d} is not EM_X86_64", .{e_machine});
    const phoff: usize = @intCast(rd(u64, b, 0x20));
    const phentsize: usize = rd(u16, b, 0x36);
    const phnum: usize = rd(u16, b, 0x38);
    var dyn: ?usize = null;
    var dyn_size: usize = 0;
    for (0..phnum) |i| {
        const ph = phoff + i * phentsize;
        if (rd(u32, b, ph) == PT_DYNAMIC) {
            if (dyn != null) fail("the file has two PT_DYNAMIC headers", .{});
            dyn = @intCast(rd(u64, b, ph + 8));
            dyn_size = @intCast(rd(u64, b, ph + 32));
        }
    }
    const start = dyn orelse fail("no PT_DYNAMIC segment", .{});
    var runpath: ?usize = null;
    var at = start;
    while (at + 16 <= start + dyn_size) : (at += 16) {
        const tag = rd(u64, b, at);
        if (tag == DT_NULL) break;
        if (tag == DT_RPATH) fail("the file has a DT_RPATH already", .{});
        if (tag == DT_RUNPATH) {
            if (runpath != null) fail("the file has two DT_RUNPATH entries", .{});
            runpath = at;
        }
    }
    return runpath orelse fail("the file has no DT_RUNPATH", .{});
}

pub fn main() !void {
    const a = std.heap.page_allocator;
    const args = try std.process.argsAlloc(a);
    if (args.len != 2) fail("usage: elf_rpath <file>", .{});
    try convert(a, args[1]);
}

fn convert(a: std.mem.Allocator, path: []const u8) !void {
    var f = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    defer f.close();
    const b = try f.readToEndAlloc(a, 1 << 31);
    const off = runpathTag(b);
    var tag: [8]u8 = undefined;
    std.mem.writeInt(u64, &tag, DT_RPATH, .little);
    try f.pwriteAll(&tag, off);
}
