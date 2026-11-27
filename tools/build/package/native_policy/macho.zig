//! native_policy: what a macOS library asks of the system that loads it, read
//! from its Mach-O bytes: its CPU type and file type, its install name
//! (LC_ID_DYLIB), the libraries it loads (LC_LOAD_DYLIB and its weak,
//! re-export, lazy and upward forms, in command order), its run path entries
//! (LC_RPATH) and the minimum macOS it states (LC_BUILD_VERSION for macOS, or
//! LC_VERSION_MIN_MACOSX).
//!
//! Read through the load commands only. Thin 64-bit little-endian files only
//! (arm64, the release platform); a universal (fat) file is recognised by
//! `isMachO` and refused by `read`. Any header, command or string outside
//! the file or outside its command is refused rather than read past.

const std = @import("std");
const diag = @import("diag.zig");
const Alloc = std.mem.Allocator;
const Diag = diag.Diag;
const Refused = diag.Refused;
const refuse = diag.refuse;

pub const CPU_TYPE_ARM64: u32 = 0x0100000c;
pub const MH_DYLIB: u32 = 6;

pub const Info = struct {
    cputype: u32 = 0,
    filetype: u32 = 0,
    /// LC_ID_DYLIB's name; null for a file with none.
    install_name: ?[]const u8 = null,
    /// The names of the load commands that load a library, in command order.
    loads: []const []const u8 = &.{},
    rpaths: []const []const u8 = &.{},
    /// The minimum macOS as `xxxx.yy.zz` packed in a u32 (`0x000b0000` is
    /// 11.0); null when the file states none.
    minos: ?u32 = null,
};

const MH_MAGIC_64 = 0xfeedfacf;
const FAT_MAGIC = 0xcafebabe;
const FAT_MAGIC_64 = 0xcafebabf;
/// The most architectures a universal file is taken to hold: a Java class
/// file starts with the same magic and then a minor version that is not a
/// small count.
const max_fat_arch = 16;

const LC_LOAD_DYLIB = 0xc;
const LC_ID_DYLIB = 0xd;
const LC_LAZY_LOAD_DYLIB = 0x20;
const LC_VERSION_MIN_MACOSX = 0x24;
const LC_BUILD_VERSION = 0x32;
const LC_LOAD_WEAK_DYLIB = 0x80000018;
const LC_RPATH = 0x8000001c;
const LC_REEXPORT_DYLIB = 0x8000001f;
const LC_LOAD_UPWARD_DYLIB = 0x80000023;
const PLATFORM_MACOS = 1;

fn isFat(data: []const u8) bool {
    if (data.len < 8) return false;
    const magic = std.mem.readInt(u32, data[0..4], .big);
    if (magic == FAT_MAGIC_64) return true;
    if (magic != FAT_MAGIC) return false;
    const n = std.mem.readInt(u32, data[4..8], .big);
    return n >= 1 and n <= max_fat_arch;
}

fn isThin(data: []const u8) bool {
    return data.len >= 4 and std.mem.readInt(u32, data[0..4], .little) == MH_MAGIC_64;
}

/// Whether `data` is a Mach-O file: thin 64-bit little-endian, or universal.
pub fn isMachO(data: []const u8) bool {
    return isThin(data) or isFat(data);
}

/// `v` as text: `11.0`, or `11.0.1` with a patch.
pub fn versionText(alloc: Alloc, v: u32) Alloc.Error![]const u8 {
    const z = v & 0xff;
    if (z != 0) return std.fmt.allocPrint(alloc, "{d}.{d}.{d}", .{ v >> 16, (v >> 8) & 0xff, z });
    return std.fmt.allocPrint(alloc, "{d}.{d}", .{ v >> 16, (v >> 8) & 0xff });
}

const Reader = struct {
    alloc: Alloc,
    d: *Diag,
    name: []const u8,
    b: []const u8,

    fn bad(r: Reader, comptime what: []const u8) Refused {
        return refuse(r.d, r.alloc, "{s}: a malformed Mach-O file ({s})", .{ r.name, what });
    }

    /// The u32 at `at`; every caller has bounded `at + 4` by the header or
    /// its command's size first.
    fn int(r: Reader, at: usize) u32 {
        return std.mem.readInt(u32, r.b[at..][0..4], .little);
    }

    /// The NUL-terminated string at `off` in the command `cmd` (its bytes
    /// from `at` to `at + size`).
    fn str(r: Reader, at: usize, size: usize, off: u32) Refused![]const u8 {
        if (off < 8 or off >= size) return r.bad("a string outside its load command");
        const s = r.b[at + off .. at + size];
        const end = std.mem.indexOfScalar(u8, s, 0) orelse return r.bad("a string without its NUL");
        return s[0..end];
    }
};

/// What `data` (a Mach-O file named `name`) asks of the system.
pub fn read(alloc: Alloc, d: *Diag, name: []const u8, data: []const u8) Refused!Info {
    const r = Reader{ .alloc = alloc, .d = d, .name = name, .b = data };
    if (isFat(data)) return refuse(d, alloc, "{s}: a universal (fat) Mach-O file: a macosx arm64 wheel carries thin arm64 files", .{name});
    if (!isThin(data)) return r.bad("no 64-bit little-endian Mach-O magic");
    if (data.len < 32) return r.bad("a header shorter than 32 bytes");
    var out = Info{ .cputype = r.int(4), .filetype = r.int(12) };
    const ncmds = r.int(16);
    const sizeofcmds = r.int(20);
    if (sizeofcmds > data.len - 32) return r.bad("load commands past the end of the file");
    const end: usize = 32 + sizeofcmds;

    var loads = std.ArrayList([]const u8).empty;
    var rpaths = std.ArrayList([]const u8).empty;
    var at: usize = 32;
    var i: u32 = 0;
    while (i < ncmds) : (i += 1) {
        if (end - at < 8) return r.bad("a load command outside sizeofcmds");
        const cmd = r.int(at);
        const size = r.int(at + 4);
        if (size < 8 or size > end - at) return r.bad("a load command outside sizeofcmds");
        switch (cmd) {
            LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB => {
                if (size < 24) return r.bad("a dylib command shorter than 24 bytes");
                try loads.append(alloc, try r.str(at, size, r.int(at + 8)));
            },
            LC_ID_DYLIB => {
                if (size < 24) return r.bad("a dylib command shorter than 24 bytes");
                if (out.install_name != null) return r.bad("two LC_ID_DYLIB commands");
                out.install_name = try r.str(at, size, r.int(at + 8));
            },
            LC_RPATH => {
                if (size < 12) return r.bad("an LC_RPATH shorter than 12 bytes");
                try rpaths.append(alloc, try r.str(at, size, r.int(at + 8)));
            },
            LC_BUILD_VERSION, LC_VERSION_MIN_MACOSX => {
                if (size < 16) return r.bad("a version command shorter than 16 bytes");
                if (out.minos != null) return r.bad("two minimum-OS version commands");
                if (cmd == LC_BUILD_VERSION) {
                    if (r.int(at + 8) != PLATFORM_MACOS) return r.bad("an LC_BUILD_VERSION for a platform other than macOS");
                    out.minos = r.int(at + 12);
                } else {
                    out.minos = r.int(at + 8);
                }
            },
            else => {},
        }
        at += size;
    }
    out.loads = try loads.toOwnedSlice(alloc);
    out.rpaths = try rpaths.toOwnedSlice(alloc);
    return out;
}
