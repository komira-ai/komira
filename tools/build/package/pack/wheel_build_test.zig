//! The wheel a package's input gives: its file name, its members in order
//! (package, native directory without the runtime libraries, dist-info with
//! RECORD last), METADATA and WHEEL text, RECORD's hashes, the same bytes from
//! inputs in another order, and the refusal of each input it cannot carry.

const std = @import("std");
const project = @import("wheel_project.zig");
const wheel = @import("wheel.zig");
const zip = @import("wheel_zip.zig");
const fixture = @import("wheel_testing.zig");
const t = std.testing;

const want_metadata =
    \\Metadata-Version: 2.4
    \\Name: komira
    \\Version: 1.0.0.post57
    \\Summary: SQL over local files, with libkomira, the komira query engine, in process
    \\Author: The komira authors
    \\License-Expression: Apache-2.0
    \\License-File: LICENSE
    \\License-File: NOTICE
    \\Keywords: sql,arrow,parquet,query-engine
    \\Classifier: Development Status :: 3 - Alpha
    \\Classifier: Programming Language :: Python :: 3.13
    \\Classifier: Typing :: Typed
    \\Project-URL: Homepage, https://github.com/komira-ai/komira
    \\Project-URL: Issue tracker, https://github.com/komira-ai/komira/issues
    \\Requires-Python: >=3.13
    \\Requires-Dist: pyarrow
    \\Requires-Dist: mojo-compiler==1.0.0
    \\Provides-Extra: pandas
    \\Requires-Dist: pandas; extra == "pandas"
    \\Provides-Extra: polars
    \\Requires-Dist: polars; extra == "polars"
    \\Description-Content-Type: text/markdown
    \\
    \\# komira
    \\
    \\SQL over local files.
    \\
;

test "the wheel's name, members in order, and METADATA, WHEEL and RECORD" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = project.Diag{};
    const built = try wheel.build(a, &d, try fixture.input(a));
    try t.expectEqualStrings("komira-1.0.0.post57-py3-none-manylinux_2_34_x86_64.whl", built.file_name);
    try t.expectEqualStrings(want_metadata, built.metadata);

    const ms = try zip.read(a, &d, built.wheel);
    const names = [_][]const u8{
        "komira/__init__.py",
        "komira/_lib/lib/libkomira_fs_native.so.1",
        "komira/_lib/libkomira.so",
        "komira/py.typed",
        "komira-1.0.0.post57.dist-info/METADATA",
        "komira-1.0.0.post57.dist-info/WHEEL",
        "komira-1.0.0.post57.dist-info/licenses/LICENSE",
        "komira-1.0.0.post57.dist-info/licenses/NOTICE",
        "komira-1.0.0.post57.dist-info/RECORD",
    };
    try t.expectEqual(names.len, ms.len);
    for (names, ms) |n, m| try t.expectEqualStrings(n, m.name);
    try t.expectEqual(@as(u32, 0o755), ms[1].mode);
    try t.expectEqual(@as(u32, 0o755), ms[2].mode);
    try t.expectEqual(@as(u32, 0o644), ms[3].mode);
    try t.expectEqualStrings("Wheel-Version: 1.0\nGenerator: komira_wheel\nRoot-Is-Purelib: false\nTag: py3-none-manylinux_2_34_x86_64\n", ms[5].data);
    try t.expectEqualStrings("Apache License text\n", ms[6].data);
    try t.expectEqualSlices(u8, built.metadata, ms[4].data);

    // RECORD: each member's sha256 (urlsafe base64, no padding) and size, then
    // itself. The empty file's hash is the well-known one.
    var lines = std.mem.splitScalar(u8, ms[8].data, '\n');
    for (ms[0..8]) |m| {
        const line = lines.next().?;
        try t.expect(std.mem.startsWith(u8, line, m.name));
        try t.expect(std.mem.endsWith(u8, line, try std.fmt.allocPrint(a, ",{d}", .{m.data.len})));
    }
    try t.expectEqualStrings("komira-1.0.0.post57.dist-info/RECORD,,", lines.next().?);
    try t.expectEqualStrings("", lines.next().?);
    try t.expectEqual(@as(?[]const u8, null), lines.next());
    try t.expectEqualStrings("sha256=47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU", try wheel.recordHash(a, ""));
}

test "inputs given in another order give the same bytes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = project.Diag{};
    var in = try fixture.input(a);
    const first = try wheel.build(a, &d, in);
    const pkg = try a.dupe(wheel.File, in.package_files);
    std.mem.reverse(wheel.File, pkg);
    const nat = try a.dupe(wheel.File, in.native_files);
    std.mem.reverse(wheel.File, nat);
    const lic = try a.dupe(wheel.File, in.licenses);
    std.mem.reverse(wheel.File, lic);
    in.package_files = pkg;
    in.native_files = nat;
    in.licenses = lic;
    const second = try wheel.build(a, &d, in);
    try t.expectEqualSlices(u8, first.wheel, second.wheel);
}

test "the version is the compiler version and the stamp as a post-release" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = project.Diag{};
    try t.expectEqualStrings("1.0.0.post57", try wheel.version(a, &d, "1.0.0", "57"));
    try t.expectEqualStrings("26.1.post0", try wheel.version(a, &d, "26.1", "0"));
    try t.expectError(error.Refused, wheel.version(a, &d, "1.0.0rc1", "1"));
    try t.expectEqualStrings("the base version `1.0.0rc1` is not dot-separated numbers without leading zeros", d.msg);
    try t.expectError(error.Refused, wheel.version(a, &d, "1.01", "1"));
    try t.expectError(error.Refused, wheel.version(a, &d, "1..0", "1"));
    try t.expectError(error.Refused, wheel.version(a, &d, "1.0", "057"));
    try t.expectEqualStrings("the stamp `057` is not a number without leading zeros", d.msg);
    try t.expectError(error.Refused, wheel.version(a, &d, "1.0", ""));
}

test "only a py3-none tag with a lowercase platform is taken" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = project.Diag{};
    try wheel.checkTag(a, &d, "py3-none-manylinux_2_34_x86_64");
    try wheel.checkTag(a, &d, "py3-none-macosx_13_0_arm64");
    try t.expectError(error.Refused, wheel.checkTag(a, &d, "cp313-cp313-manylinux_2_34_x86_64"));
    try t.expectEqualStrings("the tag `cp313-cp313-manylinux_2_34_x86_64` is not `py3-none-<platform>` (the package loads its library with ctypes and uses no CPython ABI)", d.msg);
    try t.expectError(error.Refused, wheel.checkTag(a, &d, "py3-none-"));
    try t.expectError(error.Refused, wheel.checkTag(a, &d, "py3-none-any.x"));
    try t.expectEqualStrings("the platform tag `any.x` holds `.`", d.msg);
}

test "paths RECORD could not carry unquoted, or that leave the wheel, are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = project.Diag{};
    try wheel.checkPath(a, &d, "komira/_lib/lib/libx.so.1");
    for ([_][]const u8{ "", "/abs", "a,b", "a\"b", "a\\b", "a\nb", "a//b", "a/./b", "../a", "a/" }) |p| {
        try t.expectError(error.Refused, wheel.checkPath(a, &d, p));
    }
    try t.expectEqualStrings("`a/` has an empty, `.` or `..` part", d.msg);
}

fn refusal(a: std.mem.Allocator, in: wheel.Input) ![]const u8 {
    var d = project.Diag{};
    try t.expectError(error.Refused, wheel.build(a, &d, in));
    return d.msg;
}

test "a native directory and a list of runtime libraries that disagree are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var in = try fixture.input(a);
    in.native_drop = &.{ "libKGENCompilerRTShared.so", "libAsyncRTRuntimeGlobals.so" };
    try t.expectEqualStrings("the native directory has no `lib/libAsyncRTRuntimeGlobals.so` to leave out: the list of runtime libraries and the directory disagree", try refusal(a, in));
    in = try fixture.input(a);
    in.native_lib = "libother.so";
    try t.expectEqualStrings("the native directory has no `libother.so` at its top", try refusal(a, in));
}

test "a package without __init__.py or py.typed, or with files outside it, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var in = try fixture.input(a);
    in.package_files = in.package_files[0..1];
    try t.expectEqualStrings("the package has no `komira/__init__.py`", try refusal(a, in));
    in = try fixture.input(a);
    in.package_files = in.package_files[1..2];
    try t.expectEqualStrings("the package has no `komira/py.typed`: it ships typed (PEP 561)", try refusal(a, in));
    for ([_][2][]const u8{
        .{ "setup.py", "the package file `setup.py` is not under `komira/`: the wheel carries the import package and nothing beside it" },
        .{ "komira/_lib/libkomira.so", "the package file `komira/_lib/libkomira.so` is under `komira/_lib/`, where the wheel puts the native directory" },
        .{ "komira/__pycache__/x.cpython-313.pyc", "the package file `komira/__pycache__/x.cpython-313.pyc` is bytecode or metadata the wheel rule writes itself" },
        .{ "komira/x.dist-info/RECORD", "the package file `komira/x.dist-info/RECORD` is bytecode or metadata the wheel rule writes itself" },
    }) |case| {
        in = try fixture.input(a);
        in.package_files = try std.mem.concat(a, wheel.File, &.{ in.package_files, &.{.{ .path = case[0], .data = "" }} });
        try t.expectEqualStrings(case[1], try refusal(a, in));
    }
    in = try fixture.input(a);
    in.package_files = try std.mem.concat(a, wheel.File, &.{ in.package_files, in.package_files[0..1] });
    try t.expectEqualStrings("`komira/py.typed` is given twice", try refusal(a, in));
}

test "licence files must be exactly the pyproject's license-files" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var in = try fixture.input(a);
    in.licenses = in.licenses[0..1];
    try t.expectEqualStrings("the pyproject's `license-files` names `LICENSE`, which is given 0 times (once is required): a wheel without its licence text is refused", try refusal(a, in));
    in = try fixture.input(a);
    in.licenses = try std.mem.concat(a, wheel.File, &.{ in.licenses, &.{.{ .path = "COPYING", .data = "" }} });
    try t.expectEqualStrings("the licence file `COPYING` is not in the pyproject's `license-files`", try refusal(a, in));
    in = try fixture.input(a);
    in.licenses = try std.mem.concat(a, wheel.File, &.{ in.licenses, in.licenses[0..1] });
    try t.expectEqualStrings("the pyproject's `license-files` names `NOTICE`, which is given 2 times (once is required): a wheel without its licence text is refused", try refusal(a, in));
    in = try fixture.input(a);
    in.licenses = &.{.{ .path = "sub/LICENSE", .data = "" }};
    try t.expectEqualStrings("the licence file `sub/LICENSE` is not a bare file name", try refusal(a, in));
}

test "a README other than the pyproject's, or not Markdown, and a bad import name, are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var in = try fixture.input(a);
    in.readme_name = "README.rst";
    try t.expectEqualStrings("the README given is `README.rst`, but the pyproject's `readme` is `README.md`", try refusal(a, in));
    in = try fixture.input(a);
    in.project.readme = "README.rst";
    in.readme_name = "README.rst";
    try t.expectEqualStrings("the readme `README.rst` is not Markdown (`.md`), the one content type the wheel rule writes", try refusal(a, in));
    in = try fixture.input(a);
    in.import_name = "ko-mira";
    try t.expectEqualStrings("the import name `ko-mira` is not a Python package name in lowercase", try refusal(a, in));
    in = try fixture.input(a);
    in.tag = "py3-none-any";
    var d = project.Diag{};
    try t.expectEqualStrings("komira-1.0.0.post57-py3-none-any.whl", (try wheel.build(a, &d, in)).file_name);
}

test "the manifest is the release's PYTHON artifact manifest" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings(
        "{\"format\":\"kci.artifact_manifest\",\"schema_version\":1,\"artifact_type\":\"PYTHON\",\"name\":\"komira\",\"version\":\"1.0.0.post57\",\"platform\":\"linux-x86_64\",\"file\":\"k.whl\",\"sha256\":\"ab\",\"metadata\":\"METADATA\"}\n",
        try wheel.manifest(arena.allocator(), "komira", "1.0.0.post57", "linux-x86_64", "k.whl", "ab"),
    );
}
