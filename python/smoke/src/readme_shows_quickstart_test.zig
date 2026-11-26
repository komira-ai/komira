//! The README of the Python package shows the quickstart and what it prints: its "What works" ```python block is
//! python/examples/quickstart.py byte for byte, and its ```text block is python/examples/quickstart.expected with
//! `<version>` the newest release python/CHANGELOG.md lists, `<abi_version>` the version line of
//! src/so/abi/komira.tsv and `<cwd>` left as written (the README explains it). The files are the test's data,
//! under KOMIRA_TEST_WORK. A change to one without the others fails here, with the first line that differs.
const std = @import("std");
const lib = @import("pypi_smoke_lib");
const t = std.testing;

fn readData(a: std.mem.Allocator, name: []const u8) ![]u8 {
    const work = try std.process.getEnvVarOwned(a, "KOMIRA_TEST_WORK");
    const path = try std.fs.path.join(a, &.{ work, name });
    return std.fs.cwd().readFileAlloc(a, path, 1 << 20);
}

test "the README's python block is the quickstart byte for byte" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const readme = try readData(a, "README.md");
    const example = try readData(a, "quickstart.py");
    if (try lib.readme.readmeShowsExample(a, readme, example)) |why| {
        std.debug.print("{s}\n", .{why});
        return error.ReadmeDiffersFromQuickstart;
    }
}

test "the README's text block is what the quickstart prints at the newest release" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    const version = lib.readme.newestRelease(a, &why, "python/CHANGELOG.md", try readData(a, "CHANGELOG.md")) catch |e| {
        std.debug.print("{s}\n", .{why});
        return e;
    };
    const abi = lib.install.abiVersion(a, &why, "src/so/abi/komira.tsv", try readData(a, "komira.tsv")) catch |e| {
        std.debug.print("{s}\n", .{why});
        return e;
    };
    const want = try lib.install.expectedText(a, try readData(a, "quickstart.expected"), version, abi, "<cwd>");
    if (try lib.readme.docShowsBlock(a, lib.readme.readme_output, try readData(a, "README.md"), want)) |w| {
        std.debug.print("{s}\n", .{w});
        return error.ReadmeDiffersFromOutput;
    }
}
