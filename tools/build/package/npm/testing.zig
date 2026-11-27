//! What the komira_npm tests share: the input of a main package (compiled
//! JavaScript and licence files) and of a linux-x64 platform package (the
//! addon and a native directory laid out as libkomira's: the library, its
//! owner and the three Mojo runtime libraries), built from the native
//! policy's synthetic ELF libraries, and the stamp they are written at.

const std = @import("std");
const native = @import("native_policy").testing;
const npm = @import("npm.zig");
const Alloc = std.mem.Allocator;

pub const elf = native.elf;

pub const version = "0.1.57";

/// The main package's source manifest: the development one, as node/
/// package.json is.
pub const main_manifest =
    \\{
    \\  "name": "@komira-ai/komira",
    \\  "version": "0.0.0",
    \\  "private": true,
    \\  "license": "Apache-2.0",
    \\  "repository": {
    \\    "type": "git",
    \\    "url": "https://github.com/komira-ai/komira",
    \\    "directory": "node"
    \\  },
    \\  "type": "module",
    \\  "files": [
    \\    "dist/**/*.js",
    \\    "dist/**/*.d.ts",
    \\    "NOTICE"
    \\  ],
    \\  "optionalDependencies": {
    \\    "@komira-ai/komira-linux-x64-gnu": "0.0.0"
    \\  }
    \\}
    \\
;

/// The main package's package.json, stamped 0.1.57.
pub const main_stamped =
    \\{
    \\  "name": "@komira-ai/komira",
    \\  "version": "0.1.57",
    \\  "license": "Apache-2.0",
    \\  "repository": {
    \\    "type": "git",
    \\    "url": "https://github.com/komira-ai/komira",
    \\    "directory": "node"
    \\  },
    \\  "type": "module",
    \\  "files": [
    \\    "dist/**/*.js",
    \\    "dist/**/*.d.ts",
    \\    "NOTICE"
    \\  ],
    \\  "optionalDependencies": {
    \\    "@komira-ai/komira-linux-x64-gnu": "0.1.57"
    \\  }
    \\}
    \\
;

/// The main package at 0.1.57, its files in an order the build must sort.
pub fn mainInput(alloc: Alloc) !npm.Input {
    const files = try alloc.dupe(npm.File, &.{
        .{ .path = "dist/index.js", .data = "export const version = \"0.1.57\";\n" },
        .{ .path = "NOTICE", .data = "komira notice\n" },
        .{ .path = "dist/index.d.ts", .data = "export declare const version: string;\n" },
        .{ .path = "LICENSE", .data = "Apache License text\n" },
    });
    return .{
        .name = "@komira-ai/komira",
        .manifest = main_manifest,
        .version = version,
        .stamped = true,
        .license = "Apache-2.0",
        .files = files,
    };
}

pub const platform_manifest =
    \\{
    \\  "name": "@komira-ai/komira-linux-x64-gnu",
    \\  "version": "0.0.0",
    \\  "private": true,
    \\  "license": "Apache-2.0 AND LicenseRef-Modular-Proprietary",
    \\  "repository": {
    \\    "type": "git",
    \\    "url": "https://github.com/komira-ai/komira",
    \\    "directory": "node"
    \\  },
    \\  "os": [
    \\    "linux"
    \\  ],
    \\  "cpu": [
    \\    "x64"
    \\  ],
    \\  "libc": [
    \\    "glibc"
    \\  ],
    \\  "files": [
    \\    "komira_addon.node",
    \\    "native",
    \\    "NOTICE",
    \\    "MODULAR_LICENSE"
    \\  ]
    \\}
    \\
;

/// The Mojo runtime libraries of the native directory, as `native/lib/`
/// holds them.
pub const runtime = [_][]const u8{ "libAsyncRTRuntimeGlobals.so", "libKGENCompilerRTShared.so", "libMSupportGlobals.so" };

/// The platform package's native files: the addon, the library (it needs
/// its owner and libKGENCompilerRTShared.so, which needs the other two), its
/// owner and the runtime, at the paths libkomira's directory gives them.
pub fn nativeFiles(alloc: Alloc) ![]npm.File {
    var out = std.ArrayList(npm.File).empty;
    try out.append(alloc, .{ .path = "komira_addon.node", .data = try elf(alloc, .{ .needed = &.{"libc.so.6"} }) });
    try out.append(alloc, .{ .path = "native/libkomira.so", .data = try native.goodLibrary(alloc) });
    try out.append(alloc, .{ .path = "native/lib/libkomira_fs_native.so.1", .data = try elf(alloc, .{ .needed = &.{"libc.so.6"}, .runpath = "$ORIGIN" }) });
    try out.append(alloc, .{ .path = "native/lib/libKGENCompilerRTShared.so", .data = try elf(alloc, .{ .needed = &.{ "libMSupportGlobals.so", "libAsyncRTRuntimeGlobals.so", "libc.so.6" }, .runpath = "$ORIGIN" }) });
    try out.append(alloc, .{ .path = "native/lib/libAsyncRTRuntimeGlobals.so", .data = try elf(alloc, .{ .needed = &.{"libc.so.6"} }) });
    try out.append(alloc, .{ .path = "native/lib/libMSupportGlobals.so", .data = try elf(alloc, .{ .needed = &.{"libc.so.6"} }) });
    return out.toOwnedSlice(alloc);
}

/// The platform package at 0.1.57: the native files and three licence
/// files, for linux x64 with glibc at the wheel's bounds.
pub fn platformInputOf(alloc: Alloc, files: []const npm.File) !npm.Input {
    var all = std.ArrayList(npm.File).empty;
    try all.appendSlice(alloc, files);
    try all.append(alloc, .{ .path = "MODULAR_LICENSE", .data = "Modular licence text\n" });
    try all.append(alloc, .{ .path = "NOTICE", .data = "komira notice\n" });
    try all.append(alloc, .{ .path = "LICENSE", .data = "Apache License text\n" });
    return .{
        .name = "@komira-ai/komira-linux-x64-gnu",
        .manifest = platform_manifest,
        .version = version,
        .stamped = true,
        .license = "Apache-2.0 AND LicenseRef-Modular-Proprietary",
        .files = try all.toOwnedSlice(alloc),
        .platform = .{ .os = "linux", .cpu = "x64", .libc = "glibc" },
        .glibc = "2.35",
        .arch = "x86_64",
        .max_glibcxx = "3.4.30",
        .max_cxxabi = "1.3.13",
    };
}

pub fn platformInput(alloc: Alloc) !npm.Input {
    return platformInputOf(alloc, try nativeFiles(alloc));
}

/// `files` without the one at `path`.
pub fn without(alloc: Alloc, files: []const npm.File, path: []const u8) ![]npm.File {
    var out = std.ArrayList(npm.File).empty;
    for (files) |f| {
        if (!std.mem.eql(u8, f.path, path)) try out.append(alloc, f);
    }
    return out.toOwnedSlice(alloc);
}
