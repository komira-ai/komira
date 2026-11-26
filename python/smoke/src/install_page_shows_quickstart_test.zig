//! The install page, docs/install.md, shows the quickstart and what it prints: its ```python block is
//! python/examples/quickstart.py byte for byte, and its ```text block is python/examples/quickstart.expected with
//! `<version>` the newest release python/CHANGELOG.md lists, `<abi_version>` the version line of
//! src/so/abi/komira.tsv and `<cwd>` left as written (the page explains it); the release smoke holds the installed
//! package's output to the same text with `<cwd>` the run directory's real path. The five
//! files are the test's data, under KOMIRA_TEST_WORK. A change to one without the others fails here, with the
//! first line that differs.
const std = @import("std");
const lib = @import("pypi_smoke_lib");
const t = std.testing;

fn readData(a: std.mem.Allocator, name: []const u8) ![]u8 {
    const work = try std.process.getEnvVarOwned(a, "KOMIRA_TEST_WORK");
    const path = try std.fs.path.join(a, &.{ work, name });
    return std.fs.cwd().readFileAlloc(a, path, 1 << 20);
}

fn fail(why: []const u8, err: anyerror) anyerror {
    std.debug.print("{s}\n", .{why});
    return err;
}

test "the install page's python block is the quickstart byte for byte" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const page = try readData(a, "install.md");
    const example = try readData(a, "quickstart.py");
    if (try lib.readme.docShowsBlock(a, lib.readme.install_page_example, page, example)) |why|
        return fail(why, error.InstallPageDiffersFromQuickstart);
}

test "the install page's text block is what the quickstart prints at the newest release" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    const version = lib.readme.newestRelease(a, &why, "python/CHANGELOG.md", try readData(a, "CHANGELOG.md")) catch |e|
        return fail(why, e);
    const abi = lib.install.abiVersion(a, &why, "src/so/abi/komira.tsv", try readData(a, "komira.tsv")) catch |e|
        return fail(why, e);
    const want = try lib.install.expectedText(a, try readData(a, "quickstart.expected"), version, abi, "<cwd>");
    if (try lib.readme.docShowsBlock(a, lib.readme.install_page_output, try readData(a, "install.md"), want)) |w|
        return fail(w, error.InstallPageDiffersFromOutput);
}
