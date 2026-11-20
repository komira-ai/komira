//! What the komira_wheel tests share: the design's pyproject (its values
//! filled), and the input of a wheel built from it.

const std = @import("std");
const project = @import("wheel_project.zig");
const wheel = @import("wheel.zig");

pub const pyproject =
    \\# The package's metadata, the one source of the wheel's METADATA.
    \\[project]
    \\name = "komira"
    \\dynamic = ["version"]   # stamped by the wheel rule
    \\description = "SQL over local files, with libkomira, the komira query engine, in process"
    \\readme = "README.md"
    \\requires-python = ">=3.13"
    \\license = "Apache-2.0"
    \\license-files = ["LICENSE", "NOTICE"]
    \\authors = [{ name = "The komira authors" }]
    \\keywords = ["sql", "arrow", "parquet", "query-engine"]
    \\classifiers = [
    \\  "Development Status :: 3 - Alpha",
    \\  "Programming Language :: Python :: 3.13",
    \\  "Typing :: Typed",
    \\]
    \\dependencies = [
    \\  "pyarrow",   # the Arrow terminals
    \\]
    \\
    \\[project.optional-dependencies]
    \\polars = ["polars"]
    \\pandas = ["pandas"]
    \\
    \\[project.urls]
    \\Homepage = "https://github.com/komira-ai/komira"
    \\"Issue tracker" = "https://github.com/komira-ai/komira/issues"
    \\
;

pub const readme = "# komira\n\nSQL over local files.\n";

pub const runtime_drop = [_][]const u8{ "libKGENCompilerRTShared.so", "libMSupportGlobals.so" };

pub fn parsed(alloc: std.mem.Allocator) !project.Project {
    var d = project.Diag{};
    return project.parse(alloc, &d, pyproject) catch |err| {
        std.debug.print("{s}\n", .{d.msg});
        return err;
    };
}

/// A wheel's input: the package's two files, a native directory holding the
/// library, one owner and the runtime libraries, and both licence files.
pub fn input(alloc: std.mem.Allocator) !wheel.Input {
    const pkg = try alloc.dupe(wheel.File, &.{
        .{ .path = "komira/py.typed", .data = "" },
        .{ .path = "komira/__init__.py", .data = "__all__: list[str] = []\n" },
    });
    const native = try alloc.dupe(wheel.File, &.{
        .{ .path = "lib/libKGENCompilerRTShared.so", .data = "runtime", .mode = 0o755 },
        .{ .path = "libkomira.so", .data = "\x7fELF library", .mode = 0o755 },
        .{ .path = "lib/libkomira_fs_native.so.1", .data = "\x7fELF owner", .mode = 0o755 },
        .{ .path = "lib/libMSupportGlobals.so", .data = "runtime", .mode = 0o755 },
    });
    const lic = try alloc.dupe(wheel.File, &.{
        .{ .path = "NOTICE", .data = "komira notice\n" },
        .{ .path = "LICENSE", .data = "Apache License text\n" },
    });
    return .{
        .project = try parsed(alloc),
        .readme_name = "README.md",
        .readme = readme,
        .version = "1.0.0.post57",
        .tag = "py3-none-manylinux_2_34_x86_64",
        .runtime_requires = &.{"mojo-compiler==1.0.0"},
        .import_name = "komira",
        .package_files = pkg,
        .native_files = native,
        .native_lib = "libkomira.so",
        .native_drop = &runtime_drop,
        .licenses = lic,
    };
}
