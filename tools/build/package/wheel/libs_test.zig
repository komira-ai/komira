//! `komira_wheel libs` on synthetic wheels laid out as komira's is: the
//! entry library at komira/_lib/libkomira.so with the run path
//! `$ORIGIN/lib:$ORIGIN`, an owner and the three Mojo runtime libraries in
//! komira/_lib/lib/ (the runtime with the vendor's `$ORIGIN` run paths), and
//! the runtime's licence files in the dist-info. That wheel passes, with its
//! libraries in the loader's order. Each defect is refused by the exact
//! message naming its check: a second copy of a runtime library, a runtime
//! library that is not the toolchain's or is missing, a run path that does not
//! reach a library or is absolute, climbs out of the package or is only
//! spelled like `$ORIGIN`, a library with no run path, a DT_NEEDED nobody
//! provides, one that is a path or reaches a file that is no library, a
//! library nothing loads, a member path that is absolute or not plain, a
//! directory beside the package, two or no dist-info directories, a missing
//! entry, a missing or empty runtime licence or one METADATA does not name,
//! and a Requires-Dist of the runtime's own distribution; and the command
//! line's flags. The same for a macOS wheel (libkomira.dylib, the runtime
//! dylibs by `@rpath` through `@loader_path/lib`, signed ad hoc): it passes in
//! dyld's order, and a load from Homebrew, a home directory, a conda prefix or
//! by `@executable_path`, an `@rpath` no run path reaches, an `@loader_path`
//! name outside the package, a run path that is absolute or leaves the
//! package, a Mach-O member nothing loads and a Linux `.so` beside the dylib
//! are each refused by their exact message. A library the package opens
//! itself (`--opened`, the UDF runtime beside libkomira) is walked as the
//! entry is: it and what it loads count as loaded, after the entry's
//! libraries; without it named, what only it loads is stray; and one missing,
//! outside the package, named twice or of the other format is refused.

const std = @import("std");
const diag = @import("diag.zig");
const elf = @import("elf.zig");
const libs = @import("libs.zig");
const policy = @import("policy.zig");
const zip = @import("zip.zig");
const fixture = @import("testing.zig");
const t = std.testing;
const Alloc = std.mem.Allocator;

const entry = "komira/_lib/libkomira.so";
const info = "komira-0.1.57.dist-info";
const kgen = "komira/_lib/lib/libKGENCompilerRTShared.so";
const msupport = "komira/_lib/lib/libMSupportGlobals.so";
const asyncrt = "komira/_lib/lib/libAsyncRTRuntimeGlobals.so";
const owner = "komira/_lib/lib/libkomira_fs_native.so.1";

const metadata =
    "Metadata-Version: 2.4\nName: komira\nVersion: 0.1.57\n" ++
    "License-File: LICENSE\nLicense-File: MODULAR_LICENSE\nLicense-File: MODULAR_THIRD_PARTY_NOTICES\n" ++
    "Requires-Dist: pyarrow>=14\n" ++
    "\n# komira\n\nRequires-Dist: mojo-compiler\n";

const Lib = struct {
    fn entryLib(a: Alloc, runpath: ?[]const u8) ![]u8 {
        return fixture.elf(a, .{
            .needed = &.{ "libKGENCompilerRTShared.so", "libkomira_fs_native.so.1", "libpthread.so.0", "libc.so.6" },
            .runpath = runpath,
        });
    }
    fn kgenLib(a: Alloc) ![]u8 {
        return fixture.elf(a, .{
            .needed = &.{ "libm.so.6", "libstdc++.so.6", "libMSupportGlobals.so", "libAsyncRTRuntimeGlobals.so", "libgcc_s.so.1", "libc.so.6" },
            .rpath = "$ORIGIN:$ORIGIN/../lib:$ORIGIN/../_solib_k8/_USupport:$ORIGIN/libKGENCompilerRTShared.so.runfiles/_main/_solib_k8/_USupport",
        });
    }
    fn msupportLib(a: Alloc) ![]u8 {
        return fixture.elf(a, .{ .needed = &.{ "libstdc++.so.6", "libc.so.6" }, .rpath = "$ORIGIN:$ORIGIN/../lib" });
    }
    fn asyncLib(a: Alloc) ![]u8 {
        return fixture.elf(a, .{ .needed = &.{ "libMSupportGlobals.so", "libstdc++.so.6" }, .rpath = "${ORIGIN}" });
    }
};

/// komira's layout, in the order a wheel's central directory lists it.
fn goodMembers(a: Alloc) !std.ArrayList(policy.Member) {
    var ms = std.ArrayList(policy.Member).empty;
    try ms.appendSlice(a, &.{
        .{ .name = "komira/__init__.py", .data = "__all__: list[str] = []\n" },
        .{ .name = kgen, .data = try Lib.kgenLib(a) },
        .{ .name = asyncrt, .data = try Lib.asyncLib(a) },
        .{ .name = msupport, .data = try Lib.msupportLib(a) },
        .{ .name = owner, .data = try fixture.elf(a, .{ .needed = &.{"libc.so.6"} }) },
        .{ .name = entry, .data = try Lib.entryLib(a, "$ORIGIN/lib:$ORIGIN") },
        .{ .name = info ++ "/METADATA", .data = metadata },
        .{ .name = info ++ "/WHEEL", .data = "Wheel-Version: 1.0\n" },
        .{ .name = info ++ "/licenses/LICENSE", .data = "Apache License text\n" },
        .{ .name = info ++ "/licenses/MODULAR_LICENSE", .data = "Modular Community License Terms\n" },
        .{ .name = info ++ "/licenses/MODULAR_THIRD_PARTY_NOTICES", .data = "Third-party notices\n" },
        .{ .name = info ++ "/RECORD", .data = "" },
    });
    return ms;
}

/// The toolchain's runtime: the bytes the good wheel carries.
fn goodPolicy(a: Alloc) !libs.Policy {
    return .{
        .entry = entry,
        .runtime = try a.dupe(libs.Runtime, &.{
            .{ .name = "libAsyncRTRuntimeGlobals.so", .data = try Lib.asyncLib(a) },
            .{ .name = "libKGENCompilerRTShared.so", .data = try Lib.kgenLib(a) },
            .{ .name = "libMSupportGlobals.so", .data = try Lib.msupportLib(a) },
        }),
        .runtime_licenses = &.{ "MODULAR_LICENSE", "MODULAR_THIRD_PARTY_NOTICES" },
        .runtime_dists = &.{ "mojo", "mojo-compiler", "mojo-compiler-mojo-libs" },
    };
}

fn set(ms: *std.ArrayList(policy.Member), name: []const u8, data: []const u8) void {
    for (ms.items) |*m| {
        if (!std.mem.eql(u8, m.name, name)) continue;
        m.data = data;
        return;
    }
    @panic("no such member");
}

fn drop(ms: *std.ArrayList(policy.Member), name: []const u8) void {
    for (ms.items, 0..) |m, i| {
        if (!std.mem.eql(u8, m.name, name)) continue;
        _ = ms.orderedRemove(i);
        return;
    }
    @panic("no such member");
}

fn refusal(a: Alloc, p: libs.Policy, ms: []const policy.Member) ![]const u8 {
    var d = diag.Diag{};
    try t.expectError(error.Refused, libs.check(a, &d, p, ms));
    return d.msg;
}

/// The refusal of the good wheel with the entry's run path `runpath`.
fn entryRunpathRefusal(a: Alloc, runpath: ?[]const u8) ![]const u8 {
    var ms = try goodMembers(a);
    set(&ms, entry, try Lib.entryLib(a, runpath));
    return refusal(a, try goodPolicy(a), ms.items);
}

test "komira's layout passes, its libraries listed in the loader's order" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const ms = try goodMembers(a);
    const loaded = try libs.check(a, &d, try goodPolicy(a), ms.items);
    try t.expectEqual(@as(usize, 5), loaded.len);
    const want = [_][]const u8{ entry, kgen, owner, msupport, asyncrt };
    for (want, loaded) |w, g| try t.expectEqualStrings(w, g);
}

test "a second copy of a runtime library beside the entry is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = try goodMembers(a);
    try ms.append(a, .{ .name = "komira/_lib/libKGENCompilerRTShared.so", .data = try Lib.kgenLib(a) });
    try t.expectEqualStrings(
        "runtime: the wheel carries libKGENCompilerRTShared.so 2 times (komira/_lib/lib/libKGENCompilerRTShared.so, komira/_lib/libKGENCompilerRTShared.so), and a process holds one Mojo runtime",
        try refusal(a, try goodPolicy(a), ms.items),
    );
}

test "a runtime library of another build is refused with both sha256 sums" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = try goodMembers(a);
    const other = try fixture.elf(a, .{ .needed = &.{"libMSupportGlobals.so"}, .rpath = "$ORIGIN" });
    set(&ms, kgen, other);
    var got: [32]u8 = undefined;
    var want: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(other, &got, .{});
    std.crypto.hash.sha2.Sha256.hash(try Lib.kgenLib(a), &want, .{});
    try t.expectEqualStrings(
        try std.fmt.allocPrint(a, "runtime: komira/_lib/lib/libKGENCompilerRTShared.so is not the toolchain's (sha256 {s}, the toolchain's {s})", .{ &std.fmt.bytesToHex(got, .lower), &std.fmt.bytesToHex(want, .lower) }),
        try refusal(a, try goodPolicy(a), ms.items),
    );
}

test "a missing runtime library is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = try goodMembers(a);
    drop(&ms, msupport);
    try t.expectEqualStrings("runtime: the wheel carries no libMSupportGlobals.so", try refusal(a, try goodPolicy(a), ms.items));
}

test "a run path that does not reach the runtime is refused, naming where it is" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings(
        "needed: komira/_lib/libkomira.so needs libKGENCompilerRTShared.so, which its run path `$ORIGIN/runtime:$ORIGIN` does not reach in the wheel (the wheel has it at komira/_lib/lib/libKGENCompilerRTShared.so)",
        try entryRunpathRefusal(a, "$ORIGIN/runtime:$ORIGIN"),
    );
}

test "an entry with no run path is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings(
        "needed: komira/_lib/libkomira.so needs libKGENCompilerRTShared.so, and has no run path to find it in the wheel (the wheel has it at komira/_lib/lib/libKGENCompilerRTShared.so)",
        try entryRunpathRefusal(a, null),
    );
}

test "an absolute run path entry is refused, even after one that reaches" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings(
        "runpath: komira/_lib/libkomira.so has the run path entry `/opt/modular/lib`, which is not $ORIGIN-relative",
        try entryRunpathRefusal(a, "$ORIGIN/lib:/opt/modular/lib"),
    );
}

test "a run path entry only spelled like $ORIGIN is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings(
        "runpath: komira/_lib/libkomira.so has the run path entry `$ORIGINAL/lib`, which is not $ORIGIN-relative",
        try entryRunpathRefusal(a, "$ORIGINAL/lib"),
    );
    try t.expectEqualStrings(
        "runpath: komira/_lib/libkomira.so has the run path entry `lib`, which is not $ORIGIN-relative",
        try entryRunpathRefusal(a, "lib"),
    );
}

test "a run path entry that climbs out of the package is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // To the wheel's root, above it, and into a directory beside the package.
    for ([_][]const u8{ "$ORIGIN/../..", "$ORIGIN/../../../lib", "$ORIGIN/../../modular/lib" }) |r| {
        try t.expectEqualStrings(
            try std.fmt.allocPrint(a, "runpath: komira/_lib/libkomira.so has the run path entry `{s}`, which leads out of komira/", .{r}),
            try entryRunpathRefusal(a, r),
        );
    }
}

test "run path entries that stay inside the package resolve . and .." {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = try goodMembers(a);
    set(&ms, entry, try Lib.entryLib(a, "${ORIGIN}/./x/../lib/"));
    var d = diag.Diag{};
    const loaded = try libs.check(a, &d, try goodPolicy(a), ms.items);
    try t.expectEqualStrings(kgen, loaded[1]);
}

test "a DT_NEEDED nobody provides is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = try goodMembers(a);
    set(&ms, owner, try fixture.elf(a, .{ .needed = &.{ "libssl.so.3", "libc.so.6" }, .runpath = "$ORIGIN" }));
    try t.expectEqualStrings(
        "needed: komira/_lib/lib/libkomira_fs_native.so.1 needs libssl.so.3, which its run path `$ORIGIN` does not reach in the wheel, and it is not a manylinux system library",
        try refusal(a, try goodPolicy(a), ms.items),
    );
}

test "a DT_NEEDED that is a path is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = try goodMembers(a);
    set(&ms, owner, try fixture.elf(a, .{ .needed = &.{"/usr/lib/libc.so.6"} }));
    try t.expectEqualStrings(
        "needed: komira/_lib/lib/libkomira_fs_native.so.1 needs `/usr/lib/libc.so.6`, a path the loader opens as it is, not from the wheel",
        try refusal(a, try goodPolicy(a), ms.items),
    );
}

test "a run path that reaches a file that is no library is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = try goodMembers(a);
    try ms.append(a, .{ .name = "komira/_lib/libkomira_fs_native.so.1", .data = "not a library\n" });
    set(&ms, entry, try Lib.entryLib(a, "$ORIGIN:$ORIGIN/lib"));
    try t.expectEqualStrings(
        "needed: komira/_lib/libkomira.so needs libkomira_fs_native.so.1, and its run path reaches komira/_lib/libkomira_fs_native.so.1, which is not an ELF file",
        try refusal(a, try goodPolicy(a), ms.items),
    );
}

test "a library nothing loads is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = try goodMembers(a);
    try ms.append(a, .{ .name = "komira/_lib/lib/libextra.so", .data = try fixture.elf(a, .{}) });
    try t.expectEqualStrings(
        "stray: komira/_lib/lib/libextra.so is a shared library that komira/_lib/libkomira.so does not load",
        try refusal(a, try goodPolicy(a), ms.items),
    );
}

test "a malformed library the entry loads is refused by the ELF reader" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = try goodMembers(a);
    set(&ms, owner, "\x7fELF");
    try t.expectEqualStrings(
        "komira/_lib/lib/libkomira_fs_native.so.1: a malformed ELF file (a header shorter than 64 bytes)",
        try refusal(a, try goodPolicy(a), ms.items),
    );
}

test "a member path that is absolute or not plain is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "/komira/x.py", "komira/../x.py", "komira//x.py", "komira\\x.py", "./komira/x.py", "komira/x/", "" }) |bad| {
        var ms = try goodMembers(a);
        try ms.append(a, .{ .name = bad, .data = "" });
        try t.expectEqualStrings(
            try std.fmt.allocPrint(a, "path: the member `{s}` is not a relative path of plain components", .{bad}),
            try refusal(a, try goodPolicy(a), ms.items),
        );
    }
}

test "a directory or file beside the package is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "modular/lib/libKGENCompilerRTShared.so", "setup.py", "komira-0.1.57.data/scripts/x" }) |bad| {
        var ms = try goodMembers(a);
        try ms.append(a, .{ .name = bad, .data = "" });
        try t.expectEqualStrings(
            try std.fmt.allocPrint(a, "layout: {s} is outside komira/ and komira-0.1.57.dist-info/", .{bad}),
            try refusal(a, try goodPolicy(a), ms.items),
        );
    }
}

test "two dist-info directories, or none, are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = try goodMembers(a);
    try ms.append(a, .{ .name = "mojo_compiler-1.0.0.dist-info/METADATA", .data = "" });
    try t.expectEqualStrings(
        "layout: the wheel has two .dist-info directories, komira-0.1.57.dist-info and mojo_compiler-1.0.0.dist-info",
        try refusal(a, try goodPolicy(a), ms.items),
    );
    var none = std.ArrayList(policy.Member).empty;
    for ((try goodMembers(a)).items) |m| if (!std.mem.startsWith(u8, m.name, info)) try none.append(a, m);
    try t.expectEqualStrings("layout: the wheel has no .dist-info directory", try refusal(a, try goodPolicy(a), none.items));
}

test "a missing entry, an entry that is no library and an entry outside a package are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = try goodMembers(a);
    drop(&ms, entry);
    try t.expectEqualStrings("entry: the wheel has no komira/_lib/libkomira.so", try refusal(a, try goodPolicy(a), ms.items));
    var text = try goodMembers(a);
    set(&text, entry, "#!/bin/sh\n");
    try t.expectEqualStrings("entry: komira/_lib/libkomira.so is neither an ELF nor a Mach-O file", try refusal(a, try goodPolicy(a), text.items));
    var p = try goodPolicy(a);
    p.entry = "libkomira.so";
    try t.expectEqualStrings("entry: `libkomira.so` is not a path under the import package", try refusal(a, p, (try goodMembers(a)).items));
}

test "a runtime licence missing, empty or not named by METADATA is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var missing = try goodMembers(a);
    drop(&missing, info ++ "/licenses/MODULAR_LICENSE");
    try t.expectEqualStrings(
        "licence: the wheel carries the Mojo runtime and no komira-0.1.57.dist-info/licenses/MODULAR_LICENSE",
        try refusal(a, try goodPolicy(a), missing.items),
    );
    var empty = try goodMembers(a);
    set(&empty, info ++ "/licenses/MODULAR_THIRD_PARTY_NOTICES", "");
    try t.expectEqualStrings(
        "licence: komira-0.1.57.dist-info/licenses/MODULAR_THIRD_PARTY_NOTICES is empty",
        try refusal(a, try goodPolicy(a), empty.items),
    );
    var unlisted = try goodMembers(a);
    set(&unlisted, info ++ "/METADATA", "Metadata-Version: 2.4\nName: komira\nLicense-File: LICENSE\nLicense-File: MODULAR_LICENSE\n\nLicense-File: MODULAR_THIRD_PARTY_NOTICES\n");
    try t.expectEqualStrings(
        "licence: METADATA has no `License-File: MODULAR_THIRD_PARTY_NOTICES`",
        try refusal(a, try goodPolicy(a), unlisted.items),
    );
    var no_meta = try goodMembers(a);
    drop(&no_meta, info ++ "/METADATA");
    try t.expectEqualStrings("licence: the wheel has no komira-0.1.57.dist-info/METADATA", try refusal(a, try goodPolicy(a), no_meta.items));
}

test "a Requires-Dist of the runtime's distribution is refused in any spelling" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][2][]const u8{
        .{ "mojo-compiler==1.0.0", "mojo-compiler" },
        .{ "Mojo_Compiler (==1.0.0)", "mojo-compiler" },
        .{ "mojo.compiler.mojo-libs; python_version>='3.13'", "mojo-compiler-mojo-libs" },
        .{ "MOJO", "mojo" },
    }) |c| {
        var ms = try goodMembers(a);
        set(&ms, info ++ "/METADATA", try std.fmt.allocPrint(a, "Metadata-Version: 2.4\nLicense-File: MODULAR_LICENSE\nLicense-File: MODULAR_THIRD_PARTY_NOTICES\nRequires-Dist: {s}\n", .{c[0]}));
        try t.expectEqualStrings(
            try std.fmt.allocPrint(a, "requires: METADATA requires {s} (`Requires-Dist: {s}`), which carries a second Mojo runtime", .{ c[1], c[0] }),
            try refusal(a, try goodPolicy(a), ms.items),
        );
    }
}

/// The files of a command line, from memory.
const Mem = struct {
    files: []const [2][]const u8,
    pub fn read(m: Mem, alloc: Alloc, d: *diag.Diag, path: []const u8) diag.Refused![]const u8 {
        for (m.files) |f| if (std.mem.eql(u8, f[0], path)) return f[1];
        return diag.refuse(d, alloc, "cannot read {s}: FileNotFound", .{path});
    }
};

fn wheelBytes(a: Alloc, ms: []const policy.Member) ![]const u8 {
    var zs = std.ArrayList(zip.Member).empty;
    for (ms) |m| try zs.append(a, .{ .name = m.name, .data = m.data, .mode = if (elf.isElf(m.data)) 0o755 else 0o644 });
    var d = diag.Diag{};
    return zip.write(a, &d, zs.items, .{});
}

fn goodFiles(a: Alloc) !Mem {
    return .{ .files = try a.dupe([2][]const u8, &.{
        .{ "w.whl", try wheelBytes(a, (try goodMembers(a)).items) },
        .{ "rt/a", try Lib.asyncLib(a) },
        .{ "rt/k", try Lib.kgenLib(a) },
        .{ "rt/m", try Lib.msupportLib(a) },
    }) };
}

const good_argv = [_][]const u8{
    "--wheel",           "w.whl",
    "--entry",           entry,
    "--runtime-lib",     "libAsyncRTRuntimeGlobals.so=rt/a",
    "--runtime-lib",     "libKGENCompilerRTShared.so=rt/k",
    "--runtime-lib",     "libMSupportGlobals.so=rt/m",
    "--runtime-license", "MODULAR_LICENSE",
    "--runtime-license", "MODULAR_THIRD_PARTY_NOTICES",
    "--runtime-dist",    "mojo-compiler",
    "--out",             "out/libs.txt",
};

fn commandRefusal(a: Alloc, argv: []const []const u8, files: Mem) ![]const u8 {
    var d = diag.Diag{};
    try t.expectError(error.Refused, libs.command(a, &d, argv, files));
    return d.msg;
}

test "the command reads the wheel and the runtime and lists the loaded libraries" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const r = try libs.command(a, &d, &good_argv, try goodFiles(a));
    try t.expectEqualStrings("out/libs.txt", r.out);
    try t.expectEqualStrings(entry ++ "\n" ++ kgen ++ "\n" ++ owner ++ "\n" ++ msupport ++ "\n" ++ asyncrt ++ "\n", r.marker);
}

test "the command refuses a flag of another command, a missing flag and a malformed value" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = try goodFiles(a);
    try t.expectEqualStrings("unknown argument --tag", try commandRefusal(a, &(good_argv ++ [_][]const u8{ "--tag", "x" }), files));
    try t.expectEqualStrings("unknown argument --bogus", try commandRefusal(a, &(good_argv ++ [_][]const u8{ "--bogus", "x" }), files));
    try t.expectEqualStrings("unknown argument --runtime-requirement", try commandRefusal(a, &(good_argv ++ [_][]const u8{ "--runtime-requirement", "mojo-compiler==1.0.0" }), files));
    try t.expectEqualStrings("--out needs a value", try commandRefusal(a, &(good_argv ++ [_][]const u8{"--out"}), files));
    try t.expectEqualStrings("missing --runtime-lib", try commandRefusal(a, &.{ "--wheel", "w.whl", "--entry", entry, "--out", "o" }, files));
    try t.expectEqualStrings("--runtime-lib `rt/k` is not <name>=<value>", try commandRefusal(a, &.{ "--runtime-lib", "rt/k", "--wheel", "w.whl" }, files));
    try t.expectEqualStrings("missing --entry", try commandRefusal(a, &.{ "--runtime-lib", "x=rt/k", "--wheel", "w.whl", "--out", "o" }, files));
    try t.expectEqualStrings("missing --out", try commandRefusal(a, &.{ "--runtime-lib", "x=rt/k", "--wheel", "w.whl", "--entry", entry }, files));
    try t.expectEqualStrings("missing --wheel", try commandRefusal(a, &.{ "--runtime-lib", "x=rt/k", "--entry", entry, "--out", "o" }, files));
    try t.expectEqualStrings("--entry is given 2 times", try commandRefusal(a, &(good_argv ++ [_][]const u8{ "--entry", entry }), files));
    try t.expectEqualStrings("cannot read rt/none: FileNotFound", try commandRefusal(a, &.{ "--runtime-lib", "x=rt/none" }, files));
}

test "the command refuses bytes that are no wheel, and a wheel the check refuses" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try goodFiles(a);
    const not_zip = try a.dupe([2][]const u8, good.files);
    not_zip[0] = .{ "w.whl", "not a zip" };
    try t.expectEqualStrings("no end-of-central-directory record in the last 22 bytes (a comment, or not a zip)", try commandRefusal(a, &good_argv, .{ .files = not_zip }));
    var stray = try goodMembers(a);
    try stray.append(a, .{ .name = "komira/_lib/libKGENCompilerRTShared.so", .data = try Lib.kgenLib(a) });
    const planted = try a.dupe([2][]const u8, good.files);
    planted[0] = .{ "w.whl", try wheelBytes(a, stray.items) };
    try t.expectEqualStrings(
        "runtime: the wheel carries libKGENCompilerRTShared.so 2 times (komira/_lib/lib/libKGENCompilerRTShared.so, komira/_lib/libKGENCompilerRTShared.so), and a process holds one Mojo runtime",
        try commandRefusal(a, &good_argv, .{ .files = planted }),
    );
}

test "an expected refusal ends ok only on exactly that refusal" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try goodFiles(a);
    var stray = try goodMembers(a);
    try stray.append(a, .{ .name = "komira/_lib/libKGENCompilerRTShared.so", .data = try Lib.kgenLib(a) });
    const planted = try a.dupe([2][]const u8, good.files);
    planted[0] = .{ "w.whl", try wheelBytes(a, stray.items) };
    const why = "runtime: the wheel carries libKGENCompilerRTShared.so 2 times (komira/_lib/lib/libKGENCompilerRTShared.so, komira/_lib/libKGENCompilerRTShared.so), and a process holds one Mojo runtime";
    var d = diag.Diag{};
    const r = try libs.command(a, &d, &(good_argv ++ [_][]const u8{ "--expect-refusal", why }), Mem{ .files = planted });
    try t.expectEqualStrings("out/libs.txt", r.out);
    try t.expectEqualStrings("refused: " ++ why ++ "\n", r.marker);
    // A part of the line is not the line.
    try t.expectEqualStrings(
        "the wheel is refused with `" ++ why ++ "`, not the expected `runtime: the wheel carries`",
        try commandRefusal(a, &(good_argv ++ [_][]const u8{ "--expect-refusal", "runtime: the wheel carries" }), .{ .files = planted }),
    );
    try t.expectEqualStrings(
        "the wheel passes, and the case expects it refused with `" ++ why ++ "`",
        try commandRefusal(a, &(good_argv ++ [_][]const u8{ "--expect-refusal", why }), good),
    );
    try t.expectEqualStrings(
        "--expect-refusal is given 2 times",
        try commandRefusal(a, &(good_argv ++ [_][]const u8{ "--expect-refusal", why, "--expect-refusal", why }), good),
    );
}

// ---- A library the package opens itself --------------------------------------

const udf = "komira/_lib/libkomira_udf_python.so";
const udf_dep = "komira/_lib/udf/libudf_dep.so";

/// komira's layout with the UDF runtime beside libkomira: it needs libc, the
/// owner libkomira already loads (found again through its run path) and one
/// library of its own that its run path reaches.
fn openedMembers(a: Alloc) !std.ArrayList(policy.Member) {
    var ms = try goodMembers(a);
    try ms.append(a, .{ .name = udf, .data = try fixture.elf(a, .{ .needed = &.{ "libc.so.6", "libkomira_fs_native.so.1", "libudf_dep.so" }, .runpath = "$ORIGIN/lib:$ORIGIN/udf" }) });
    try ms.append(a, .{ .name = udf_dep, .data = try fixture.elf(a, .{ .needed = &.{"libc.so.6"} }) });
    return ms;
}

fn openedPolicy(a: Alloc, opened: []const []const u8) !libs.Policy {
    var p = try goodPolicy(a);
    p.opened = opened;
    return p;
}

test "an opened library and what it loads count as loaded, listed after the entry's libraries" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const ms = try openedMembers(a);
    const loaded = try libs.check(a, &d, try openedPolicy(a, &.{udf}), ms.items);
    const want = [_][]const u8{ entry, kgen, owner, msupport, asyncrt, udf, udf_dep };
    try t.expectEqual(want.len, loaded.len);
    for (want, loaded) |w, g| try t.expectEqualStrings(w, g);
}

test "a library the package opens is stray when it is not named opened" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ms = try openedMembers(a);
    try t.expectEqualStrings(
        "stray: " ++ udf ++ " is a shared library that " ++ entry ++ " does not load",
        try refusal(a, try goodPolicy(a), ms.items),
    );
}

test "with an opened library, a library neither it nor the entry loads is stray, naming both" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = try openedMembers(a);
    try ms.append(a, .{ .name = "komira/_lib/lib/libextra.so", .data = try fixture.elf(a, .{}) });
    try t.expectEqualStrings(
        "stray: komira/_lib/lib/libextra.so is a shared library that neither " ++ entry ++ " nor " ++ udf ++ " loads",
        try refusal(a, try openedPolicy(a, &.{udf}), ms.items),
    );
}

test "an opened library's own needs are walked: one its run path does not reach is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = try openedMembers(a);
    set(&ms, udf, try fixture.elf(a, .{ .needed = &.{"libudf_dep.so"}, .runpath = "$ORIGIN/lib" }));
    try t.expectEqualStrings(
        "needed: " ++ udf ++ " needs libudf_dep.so, which its run path `$ORIGIN/lib` does not reach in the wheel (the wheel has it at " ++ udf_dep ++ ")",
        try refusal(a, try openedPolicy(a, &.{udf}), ms.items),
    );
}

test "an opened library missing, outside the package, named twice or of another format is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var missing = try openedMembers(a);
    drop(&missing, udf);
    try t.expectEqualStrings("entry: the wheel has no " ++ udf, try refusal(a, try openedPolicy(a, &.{udf}), missing.items));
    const ms = try openedMembers(a);
    for ([_][]const u8{ "other/libkomira_udf_python.so", "libkomira_udf_python.so", "komira/../x.so", "komira" }) |o| {
        try t.expectEqualStrings(
            try std.fmt.allocPrint(a, "entry: the opened library `{s}` is not a path under komira/", .{o}),
            try refusal(a, try openedPolicy(a, &.{o}), ms.items),
        );
    }
    try t.expectEqualStrings("entry: " ++ udf ++ " is named twice", try refusal(a, try openedPolicy(a, &.{ udf, udf }), ms.items));
    try t.expectEqualStrings("entry: " ++ entry ++ " is named twice", try refusal(a, try openedPolicy(a, &.{entry}), ms.items));
    var text = try openedMembers(a);
    set(&text, udf, "#!/bin/sh\n");
    try t.expectEqualStrings(
        "entry: the opened library " ++ udf ++ " is not an ELF file like " ++ entry,
        try refusal(a, try openedPolicy(a, &.{udf}), text.items),
    );
    var dylib = try openedMembers(a);
    set(&dylib, udf, try Dylib.msupLib(a));
    try t.expectEqualStrings(
        "entry: the opened library " ++ udf ++ " is not an ELF file like " ++ entry,
        try refusal(a, try openedPolicy(a, &.{udf}), dylib.items),
    );
}

test "the command takes --opened and lists what each opened library loads" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try goodFiles(a);
    const files = try a.dupe([2][]const u8, good.files);
    files[0] = .{ "w.whl", try wheelBytes(a, (try openedMembers(a)).items) };
    var d = diag.Diag{};
    const r = try libs.command(a, &d, &(good_argv ++ [_][]const u8{ "--opened", udf }), Mem{ .files = files });
    try t.expectEqualStrings(entry ++ "\n" ++ kgen ++ "\n" ++ owner ++ "\n" ++ msupport ++ "\n" ++ asyncrt ++ "\n" ++ udf ++ "\n" ++ udf_dep ++ "\n", r.marker);
    try t.expectEqualStrings(
        "stray: " ++ udf ++ " is a shared library that " ++ entry ++ " does not load",
        try commandRefusal(a, &good_argv, .{ .files = files }),
    );
}

test "macOS: an opened library must be Mach-O like the entry, and is walked as dyld walks it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mudf = "komira/_lib/libkomira_udf_python.dylib";
    var ms = try macMembers(a);
    try ms.append(a, .{ .name = mudf, .data = try fixture.machO(a, .{ .install_name = "@rpath/libkomira_udf_python.dylib", .loads = &.{ "@rpath/libMSupportGlobals.dylib", "/usr/lib/libSystem.B.dylib" }, .rpaths = &.{"@loader_path/lib"} }) });
    var p = try macPolicy(a);
    p.opened = &.{mudf};
    var d = diag.Diag{};
    const loaded = try libs.check(a, &d, p, ms.items);
    try t.expectEqualStrings(mudf, loaded[loaded.len - 1]);
    try t.expectEqual(@as(usize, 5), loaded.len);
    set(&ms, mudf, try fixture.elf(a, .{ .needed = &.{"libc.so.6"} }));
    try t.expectEqualStrings(
        "entry: the opened library " ++ mudf ++ " is not a Mach-O file like " ++ mentry,
        try refusal(a, p, ms.items),
    );
}

// ---- The macOS wheel ---------------------------------------------------------

const mentry = "komira/_lib/libkomira.dylib";
const mkgen = "komira/_lib/lib/libKGENCompilerRTShared.dylib";
const masync = "komira/_lib/lib/libAsyncRTRuntimeGlobals.dylib";
const msup = "komira/_lib/lib/libMSupportGlobals.dylib";

const Dylib = struct {
    fn entryLib(a: Alloc, loads: []const []const u8, rpaths: []const []const u8) ![]u8 {
        return fixture.machO(a, .{ .install_name = "@rpath/libkomira.dylib", .loads = loads, .rpaths = rpaths });
    }
    fn good(a: Alloc) ![]u8 {
        return entryLib(a, &.{ "@rpath/libKGENCompilerRTShared.dylib", "@rpath/libAsyncRTRuntimeGlobals.dylib", "/usr/lib/libSystem.B.dylib", "/usr/lib/libc++.1.dylib" }, &.{"@loader_path/lib"});
    }
    fn kgenLib(a: Alloc) ![]u8 {
        return fixture.machO(a, .{ .install_name = "@rpath/libKGENCompilerRTShared.dylib", .loads = &.{ "@rpath/libMSupportGlobals.dylib", "/usr/lib/libSystem.B.dylib" }, .rpaths = &.{"@loader_path"} });
    }
    fn asyncLib(a: Alloc) ![]u8 {
        return fixture.machO(a, .{ .install_name = "@rpath/libAsyncRTRuntimeGlobals.dylib", .loads = &.{ "@rpath/libMSupportGlobals.dylib", "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation" }, .rpaths = &.{"@loader_path/../lib"} });
    }
    fn msupLib(a: Alloc) ![]u8 {
        return fixture.machO(a, .{ .install_name = "@rpath/libMSupportGlobals.dylib", .loads = &.{"/usr/lib/libSystem.B.dylib"} });
    }
};

fn macMembers(a: Alloc) !std.ArrayList(policy.Member) {
    var ms = std.ArrayList(policy.Member).empty;
    try ms.appendSlice(a, &.{
        .{ .name = "komira/__init__.py", .data = "__all__: list[str] = []\n" },
        .{ .name = mkgen, .data = try Dylib.kgenLib(a) },
        .{ .name = masync, .data = try Dylib.asyncLib(a) },
        .{ .name = msup, .data = try Dylib.msupLib(a) },
        .{ .name = mentry, .data = try Dylib.good(a) },
        .{ .name = info ++ "/METADATA", .data = metadata },
        .{ .name = info ++ "/WHEEL", .data = "Wheel-Version: 1.0\n" },
        .{ .name = info ++ "/licenses/LICENSE", .data = "Apache License text\n" },
        .{ .name = info ++ "/licenses/MODULAR_LICENSE", .data = "Modular Community License Terms\n" },
        .{ .name = info ++ "/licenses/MODULAR_THIRD_PARTY_NOTICES", .data = "Third-party notices\n" },
        .{ .name = info ++ "/RECORD", .data = "" },
    });
    return ms;
}

fn macPolicy(a: Alloc) !libs.Policy {
    return .{
        .entry = mentry,
        .runtime = try a.dupe(libs.Runtime, &.{
            .{ .name = "libAsyncRTRuntimeGlobals.dylib", .data = try Dylib.asyncLib(a) },
            .{ .name = "libKGENCompilerRTShared.dylib", .data = try Dylib.kgenLib(a) },
            .{ .name = "libMSupportGlobals.dylib", .data = try Dylib.msupLib(a) },
        }),
        .runtime_licenses = &.{ "MODULAR_LICENSE", "MODULAR_THIRD_PARTY_NOTICES" },
        .runtime_dists = &.{ "mojo", "mojo-compiler", "mojo-compiler-mojo-libs" },
    };
}

/// The refusal of the good macOS wheel with libkomira.dylib loading `loads`
/// through `rpaths`.
fn macEntryRefusal(a: Alloc, loads: []const []const u8, rpaths: []const []const u8) ![]const u8 {
    var ms = try macMembers(a);
    set(&ms, mentry, try Dylib.entryLib(a, loads, rpaths));
    return refusal(a, try macPolicy(a), ms.items);
}

test "macOS: komira's layout passes, its dylibs listed in dyld's order" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const got = try libs.check(a, &d, try macPolicy(a), (try macMembers(a)).items);
    try t.expectEqual(@as(usize, 4), got.len);
    try t.expectEqualStrings(mentry, got[0]);
    try t.expectEqualStrings(mkgen, got[1]);
    try t.expectEqualStrings(masync, got[2]);
    try t.expectEqualStrings(msup, got[3]);
}

test "macOS: a load from Homebrew, a home directory, a conda prefix, by @executable_path or by a bare name is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "/opt/homebrew/lib/liblz4.1.dylib",
        "/Users/runner/work/komira/buck-out/libkomira_fs.dylib",
        "/Users/runner/miniconda3/lib/libc++.1.dylib",
        "@executable_path/../lib/liblz4.dylib",
        "liblz4.dylib",
        "/usr/lib/../../opt/homebrew/lib/liblz4.dylib",
    }) |bad| {
        try t.expectEqualStrings(
            try std.fmt.allocPrint(a, "needed: komira/_lib/libkomira.dylib loads `{s}`, a path outside the wheel that is not a macOS system library", .{bad}),
            try macEntryRefusal(a, &.{ "@rpath/libKGENCompilerRTShared.dylib", "@rpath/libAsyncRTRuntimeGlobals.dylib", bad }, &.{"@loader_path/lib"}),
        );
    }
}

test "macOS: an @rpath no run path reaches is refused, naming where the wheel has it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loads = [_][]const u8{ "@rpath/libKGENCompilerRTShared.dylib", "@rpath/libAsyncRTRuntimeGlobals.dylib" };
    try t.expectEqualStrings(
        "needed: komira/_lib/libkomira.dylib loads @rpath/libKGENCompilerRTShared.dylib, which its run path `@loader_path` does not reach in the wheel (the wheel has it at komira/_lib/lib/libKGENCompilerRTShared.dylib)",
        try macEntryRefusal(a, &loads, &.{"@loader_path"}),
    );
    try t.expectEqualStrings(
        "needed: komira/_lib/libkomira.dylib loads @rpath/libKGENCompilerRTShared.dylib, and has no run path to find it in the wheel (the wheel has it at komira/_lib/lib/libKGENCompilerRTShared.dylib)",
        try macEntryRefusal(a, &loads, &.{}),
    );
    try t.expectEqualStrings(
        "needed: komira/_lib/libkomira.dylib loads @rpath/libnone.dylib, which its run path `@loader_path/lib` does not reach in the wheel",
        try macEntryRefusal(a, &(loads ++ [_][]const u8{"@rpath/libnone.dylib"}), &.{"@loader_path/lib"}),
    );
}

test "macOS: an @loader_path load is followed inside the package and refused outside it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = try macMembers(a);
    set(&ms, mentry, try Dylib.entryLib(a, &.{ "@loader_path/lib/libKGENCompilerRTShared.dylib", "@rpath/libAsyncRTRuntimeGlobals.dylib" }, &.{"@loader_path/lib"}));
    var d = diag.Diag{};
    const got = try libs.check(a, &d, try macPolicy(a), ms.items);
    try t.expectEqualStrings(mkgen, got[1]);
    try t.expectEqualStrings(
        "needed: komira/_lib/libkomira.dylib loads `@loader_path/../../liblz4.dylib`, which leads out of komira/",
        try macEntryRefusal(a, &.{ "@rpath/libKGENCompilerRTShared.dylib", "@rpath/libAsyncRTRuntimeGlobals.dylib", "@loader_path/../../liblz4.dylib" }, &.{"@loader_path/lib"}),
    );
    try t.expectEqualStrings(
        "needed: komira/_lib/libkomira.dylib loads @loader_path/lib/liblz4.dylib, and the wheel has no komira/_lib/lib/liblz4.dylib",
        try macEntryRefusal(a, &.{ "@rpath/libKGENCompilerRTShared.dylib", "@rpath/libAsyncRTRuntimeGlobals.dylib", "@loader_path/lib/liblz4.dylib" }, &.{"@loader_path/lib"}),
    );
}

test "macOS: a run path that is absolute, not @loader_path-relative or leaves the package is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loads = [_][]const u8{ "@rpath/libKGENCompilerRTShared.dylib", "@rpath/libAsyncRTRuntimeGlobals.dylib" };
    for ([_][]const u8{ "/opt/homebrew/lib", "@executable_path/lib", "@loader_pathx", "lib" }) |r| {
        try t.expectEqualStrings(
            try std.fmt.allocPrint(a, "runpath: komira/_lib/libkomira.dylib has the run path entry `{s}`, which is not @loader_path-relative", .{r}),
            try macEntryRefusal(a, &loads, &.{ "@loader_path/lib", r }),
        );
    }
    for ([_][]const u8{ "@loader_path/../..", "@loader_path/../../other" }) |r| {
        try t.expectEqualStrings(
            try std.fmt.allocPrint(a, "runpath: komira/_lib/libkomira.dylib has the run path entry `{s}`, which leads out of komira/", .{r}),
            try macEntryRefusal(a, &loads, &.{r}),
        );
    }
}

test "macOS: a dylib nothing loads, and a Linux .so beside the dylib, are refused as stray" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var extra = try macMembers(a);
    try extra.append(a, .{ .name = "komira/_lib/lib/liblz4.dylib", .data = try fixture.machO(a, .{ .install_name = "@rpath/liblz4.dylib" }) });
    try t.expectEqualStrings("stray: komira/_lib/lib/liblz4.dylib is a shared library that komira/_lib/libkomira.dylib does not load", try refusal(a, try macPolicy(a), extra.items));
    var linux = try macMembers(a);
    try linux.append(a, .{ .name = "komira/_lib/libkomira.so", .data = try Lib.entryLib(a, "$ORIGIN/lib") });
    try t.expectEqualStrings("stray: komira/_lib/libkomira.so is a shared library that komira/_lib/libkomira.dylib does not load", try refusal(a, try macPolicy(a), linux.items));
}

test "macOS: an @rpath that reaches a member that is not Mach-O is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = try macMembers(a);
    try ms.append(a, .{ .name = "komira/_lib/lib/liblz4.dylib", .data = "not a library\n" });
    set(&ms, mentry, try Dylib.entryLib(a, &.{ "@rpath/libKGENCompilerRTShared.dylib", "@rpath/libAsyncRTRuntimeGlobals.dylib", "@rpath/liblz4.dylib" }, &.{"@loader_path/lib"}));
    try t.expectEqualStrings(
        "needed: komira/_lib/libkomira.dylib loads @rpath/liblz4.dylib, and its run path reaches komira/_lib/lib/liblz4.dylib, which is not a Mach-O file",
        try refusal(a, try macPolicy(a), ms.items),
    );
    // The same member reached by @loader_path.
    set(&ms, mentry, try Dylib.entryLib(a, &.{ "@rpath/libKGENCompilerRTShared.dylib", "@rpath/libAsyncRTRuntimeGlobals.dylib", "@loader_path/lib/liblz4.dylib" }, &.{"@loader_path/lib"}));
    try t.expectEqualStrings(
        "needed: komira/_lib/libkomira.dylib loads @loader_path/lib/liblz4.dylib, which is komira/_lib/lib/liblz4.dylib, not a Mach-O file",
        try refusal(a, try macPolicy(a), ms.items),
    );
}
