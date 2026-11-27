//! What the komira_wheel tests share: the input of a wheel holding a
//! library, its owner and a Python file, or of a macOS wheel holding a dylib
//! and the Mojo runtime's; and, from `native_policy.testing`, the synthetic
//! ELF and Mach-O libraries they hold.

const std = @import("std");
const native = @import("native_policy").testing;
const wheel = @import("wheel.zig");
const Alloc = std.mem.Allocator;

pub const elf = native.elf;
pub const machO = native.machO;
pub const macosVersion = native.macosVersion;
const goodLibrary = native.goodLibrary;
const external = native.external;
const runtime_dylibs = native.runtime_dylibs;
const runtimeDylib = native.runtimeDylib;
const goodDylib = native.goodDylib;

pub const readme = "# komira\n\nSQL over local files.\n";

/// A wheel's input: a Python file, the library and its owner (both 0755),
/// two licence files, in an order the build must sort.
pub fn input(alloc: Alloc) !wheel.Input {
    const files = try alloc.dupe(wheel.File, &.{
        .{ .path = "komira/_lib/libkomira.so", .data = try goodLibrary(alloc), .mode = 0o755 },
        .{ .path = "komira/__init__.py", .data = "__all__: list[str] = []\n" },
        .{ .path = "komira/_lib/lib/libkomira_fs_native.so.1", .data = try elf(alloc, .{ .needed = &.{"libc.so.6"}, .runpath = "$ORIGIN" }), .mode = 0o755 },
    });
    const lics = try alloc.dupe(wheel.File, &.{
        .{ .path = "NOTICE", .data = "komira notice\n" },
        .{ .path = "LICENSE", .data = "Apache License text\n" },
    });
    return .{
        .name = "komira",
        .version = "0.1.57",
        .summary = "SQL over local files",
        .readme = readme,
        .requires_python = ">=3.13",
        .requires_dist = &.{ "pyarrow", "mojo-compiler==1.0.0" },
        .classifiers = &.{ "Programming Language :: Python :: 3.13", "Typing :: Typed" },
        .project_urls = &.{.{ .label = "Homepage", .url = "https://github.com/komira-ai/komira" }},
        .license_expression = "Apache-2.0",
        .licenses = lics,
        .files = files,
        .tag = "py3-none-manylinux_2_34_x86_64",
        .max_glibcxx = "3.4.30",
        .max_cxxabi = "1.3.13",
        .external_needed = &external,
    };
}

/// The macOS wheel's input: libkomira.dylib and the three runtime dylibs
/// (0755), and a Python file, under the tag py3-none-macosx_11_0_arm64, with
/// `lib` as libkomira.dylib.
pub fn macosInputOf(alloc: Alloc, lib: []const u8) !wheel.Input {
    var in = try input(alloc);
    var files = std.ArrayList(wheel.File).empty;
    try files.append(alloc, .{ .path = "komira/__init__.py", .data = "__all__: list[str] = []\n" });
    try files.append(alloc, .{ .path = "komira/_lib/libkomira.dylib", .data = lib, .mode = 0o755 });
    for (runtime_dylibs) |n| {
        try files.append(alloc, .{ .path = try std.fmt.allocPrint(alloc, "komira/_lib/lib/{s}", .{n}), .data = try runtimeDylib(alloc, n), .mode = 0o755 });
    }
    in.files = try files.toOwnedSlice(alloc);
    in.tag = "py3-none-macosx_11_0_arm64";
    in.requires_dist = &.{"pyarrow"};
    in.max_glibcxx = null;
    in.max_cxxabi = null;
    in.external_needed = &.{};
    return in;
}

/// The macOS wheel's input with the good libkomira.dylib.
pub fn macosInput(alloc: Alloc) !wheel.Input {
    return macosInputOf(alloc, try goodDylib(alloc));
}
