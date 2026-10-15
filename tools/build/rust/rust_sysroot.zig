// Why Zig: build tools are Zig (tools/build/README.md). This replaces a
// busybox shell script (the `rust_sysroot` rule's), so that unpacking the
// Rust toolchain runs no shell. It runs under the pinned zig, not under rustc.
//! rust_sysroot: assembles the sysroot the Rust rules compile with, from the
//! release tarballs of rustc and of the standard library.
//!
//! usage: rust_sysroot <rustc.tar.gz> <rust-std.tar.gz> <out_dir> <triple> <version> <libs_dir>
//!
//! It keeps only what compiling needs, at these places in <out_dir>:
//!   bin/rustc                  the driver, from `rustc-<version>-<triple>/rustc/bin/rustc`
//!   lib/<name>                 the shared libraries rustc loads: each file or
//!                              link with `.so` in its name directly in
//!                              `rustc-<version>-<triple>/rustc/lib/`
//!   lib/<name>                 each file of <libs_dir>/lib/ (the libraries those
//!                              need beyond glibc); a name already there is refused
//!   lib/rustlib/<triple>/lib/  everything under `rust-std-<version>-<triple>/
//!                              rust-std-<triple>/lib/rustlib/<triple>/lib/`
//!
//! Files get mode 0755 when the tarball marks them executable, else 0644;
//! directories 0755. The sysroot is refused unless bin/rustc is executable
//! and the standard library has a `libstd-*`.
//!
//! Exit status: 0; 2 for a usage error, an unreadable or malformed archive, a
//! library in both rustc and <libs_dir>, or an incomplete sysroot.

const std = @import("std");

pub const Layout = struct {
    /// `rustc-<version>-<triple>/rustc/`
    rustc_prefix: []const u8,
    /// `rust-std-<version>-<triple>/rust-std-<triple>/lib/rustlib/<triple>/lib/`
    std_prefix: []const u8,
    /// `lib/rustlib/<triple>/lib`
    std_dest: []const u8,
};

pub fn layout(a: std.mem.Allocator, version: []const u8, triple: []const u8) !Layout {
    return .{
        .rustc_prefix = try std.fmt.allocPrint(a, "rustc-{s}-{s}/rustc/", .{ version, triple }),
        .std_prefix = try std.fmt.allocPrint(a, "rust-std-{s}-{s}/rust-std-{s}/lib/rustlib/{s}/lib/", .{ version, triple, triple, triple }),
        .std_dest = try std.fmt.allocPrint(a, "lib/rustlib/{s}/lib", .{triple}),
    };
}

/// The mode a sysroot file gets: 0755 when the tarball marks it executable.
pub fn modeOf(tar_mode: u32) std.fs.File.Mode {
    return if (tar_mode & 0o111 != 0) 0o755 else 0o644;
}

pub const PathError = error{PathEscapes};

/// `name` below `prefix`, or null when it is not under it. A `..` component
/// is refused.
pub fn below(name: []const u8, prefix: []const u8) PathError!?[]const u8 {
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const rest = std.mem.trimRight(u8, name[prefix.len..], "/");
    var it = std.mem.splitScalar(u8, rest, '/');
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, "..")) return error.PathEscapes;
    }
    return rest;
}

/// Whether `rest` (a path below `rustc/lib/`) is a shared library file of
/// that directory: one component, with `.so` in its name.
pub fn isRustcLib(rest: []const u8) bool {
    return rest.len > 0 and std.mem.indexOfScalar(u8, rest, '/') == null and std.mem.indexOf(u8, rest, ".so") != null;
}

pub const Stats = struct { bin: usize = 0, libs: usize = 0, std_entries: usize = 0 };

fn put(dir: std.fs.Dir, f: anytype, rel: []const u8) !void {
    if (std.fs.path.dirname(rel)) |d| try dir.makePath(d);
    switch (f.kind) {
        .directory => try dir.makePath(rel),
        .file => {
            const file = try dir.createFile(rel, .{ .mode = modeOf(f.mode) });
            defer file.close();
            try f.writeAll(file);
            try file.chmod(modeOf(f.mode));
        },
        .sym_link => {
            dir.deleteFile(rel) catch {};
            try dir.symLink(f.link_name, rel, .{});
        },
    }
}

/// Takes from the gzipped tar read by `reader` the members of the rustc
/// release a sysroot keeps, into `out`.
pub fn takeRustc(out: std.fs.Dir, reader: anytype, lay: Layout, stats: *Stats) !void {
    var name_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var link_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var it = std.tar.iterator(reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    while (try it.next()) |f| {
        const under = try below(f.name, lay.rustc_prefix) orelse continue;
        if (f.kind == .directory) continue;
        if (std.mem.eql(u8, under, "bin/rustc")) {
            if (f.kind != .file) return error.NotAFile;
            try put(out, f, "bin/rustc");
            stats.bin += 1;
        } else if (std.mem.startsWith(u8, under, "lib/") and isRustcLib(under["lib/".len..])) {
            const rel = try std.fmt.bufPrint(&buf, "lib/{s}", .{under["lib/".len..]});
            try put(out, f, rel);
            stats.libs += 1;
        }
    }
}

/// Takes the standard library of the rust-std release into `out`.
pub fn takeStd(out: std.fs.Dir, reader: anytype, lay: Layout, stats: *Stats) !void {
    var name_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var link_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var it = std.tar.iterator(reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    while (try it.next()) |f| {
        const under = try below(f.name, lay.std_prefix) orelse continue;
        if (under.len == 0) continue;
        const rel = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ lay.std_dest, under });
        try put(out, f, rel);
        stats.std_entries += 1;
    }
}

pub const LibsError = error{Duplicate};

/// Copies each file of `libs` (the `lib/` of a conda_libs output) into
/// `out/lib/`; a name already there is a library of rustc's own. On
/// `error.Duplicate`, `name` is the library.
pub fn takeLibs(out: std.fs.Dir, libs: std.fs.Dir, name: *[std.fs.MAX_NAME_BYTES]u8, name_len: *usize) !usize {
    var n: usize = 0;
    var dir = try out.openDir("lib", .{});
    defer dir.close();
    var it = libs.iterate();
    while (try it.next()) |e| {
        if (dir.statFile(e.name)) |_| {
            @memcpy(name[0..e.name.len], e.name);
            name_len.* = e.name.len;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        try libs.copyFile(e.name, dir, e.name, .{});
        n += 1;
    }
    return n;
}

pub const CheckError = error{ NoRustc, NoLibstd };

/// A sysroot is refused unless bin/rustc is executable and the standard
/// library has a `libstd-*`.
pub fn check(out: std.fs.Dir, lay: Layout) !void {
    const st = out.statFile("bin/rustc") catch return error.NoRustc;
    if (st.mode & 0o111 == 0) return error.NoRustc;
    var d = out.openDir(lay.std_dest, .{ .iterate = true }) catch return error.NoLibstd;
    defer d.close();
    var it = d.iterate();
    while (try it.next()) |e| {
        if (std.mem.startsWith(u8, e.name, "libstd-")) return;
    }
    return error.NoLibstd;
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("rust_sysroot: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn gunzipped(path: []const u8, comptime body: anytype, ctx: anytype) !void {
    const file = std.fs.cwd().openFile(path, .{}) catch |e| die("cannot open {s}: {s}", .{ path, @errorName(e) });
    defer file.close();
    var br = std.io.bufferedReader(file.reader());
    var dec = std.compress.gzip.decompressor(br.reader());
    try body(ctx, dec.reader());
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len != 7) die("usage: rust_sysroot <rustc.tar.gz> <rust-std.tar.gz> <out_dir> <triple> <version> <libs_dir>", .{});
    const rustc_tar = argv[1];
    const std_tar = argv[2];
    const out_path = argv[3];
    const triple = argv[4];
    const version = argv[5];
    const libs_path = argv[6];
    const lay = try layout(a, version, triple);

    try std.fs.cwd().makePath(out_path);
    var out = try std.fs.cwd().openDir(out_path, .{ .iterate = true });
    defer out.close();
    try out.makePath("bin");
    try out.makePath("lib");
    try out.makePath(lay.std_dest);

    var stats = Stats{};
    const Ctx = struct { out: std.fs.Dir, lay: Layout, stats: *Stats };
    const ctx = Ctx{ .out = out, .lay = lay, .stats = &stats };
    try gunzipped(rustc_tar, struct {
        fn f(c: Ctx, r: anytype) !void {
            try takeRustc(c.out, r, c.lay, c.stats);
        }
    }.f, ctx);

    const libs_lib = try std.fs.path.join(a, &.{ libs_path, "lib" });
    var libs = std.fs.cwd().openDir(libs_lib, .{ .iterate = true }) catch |e| die("cannot open {s}: {s}", .{ libs_lib, @errorName(e) });
    defer libs.close();
    var dup_name: [std.fs.MAX_NAME_BYTES]u8 = undefined;
    var dup_len: usize = 0;
    stats.libs += takeLibs(out, libs, &dup_name, &dup_len) catch |e| switch (e) {
        error.Duplicate => die("REFUSING: {s} is both a rustc library and in libs", .{dup_name[0..dup_len]}),
        else => return e,
    };

    try gunzipped(std_tar, struct {
        fn f(c: Ctx, r: anytype) !void {
            try takeStd(c.out, r, c.lay, c.stats);
        }
    }.f, ctx);

    check(out, lay) catch |e| switch (e) {
        error.NoRustc => die("REFUSING: {s}/bin/rustc is missing or not executable", .{out_path}),
        error.NoLibstd => die("REFUSING: no libstd-* in {s}/{s}", .{ out_path, lay.std_dest }),
        else => return e,
    };
}
