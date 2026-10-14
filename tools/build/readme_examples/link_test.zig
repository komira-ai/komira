//! The link block (link.zig): the commands the packer writes, parsed to
//! their arguments; every way a block is refused.

const std = @import("std");
const link = @import("link.zig");
const t = std.testing;

const Arena = std.heap.ArenaAllocator;

/// The section the packer appends (tools/build/package/pack/readme_link.zig),
/// for a closure of two owners and komira_log's holder.
const PACKED = "# X\n\n## Linking\n\n<!-- Written by the packer -->\ntext\n\n```sh komira-link\n" ++
    "mojo run -Xlinker -L$CONDA_PREFIX/lib -Xlinker -lkomira_http_core_native -Xlinker -lkomira_crypto_native prog.mojo\n" ++
    "mojo build -Xlinker -L$CONDA_PREFIX/lib -Xlinker -lkomira_http_core_native -Xlinker -lkomira_crypto_native" ++
    " -Xlinker -lkomira_log_holder -Xlinker -rpath -Xlinker '$ORIGIN/../lib' prog.mojo -o $CONDA_PREFIX/bin/prog\n```\n";

fn parse(a: std.mem.Allocator, text: []const u8) !link.Parsed {
    return link.parse(a, text, "src/x/README.md");
}

fn refusal(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    return switch (try parse(a, text)) {
        .refused => |why| why,
        else => error.NotRefused,
    };
}

test "the packer's block parses to its arguments, quotes removed, $CONDA_PREFIX kept" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = (try parse(a, PACKED)).commands;
    try t.expectEqual(@as(usize, 6), c.run.len);
    try t.expectEqualStrings("-L$CONDA_PREFIX/lib", c.run[1]);
    try t.expectEqualStrings("-lkomira_http_core_native", c.run[3]);
    try t.expectEqualStrings("-lkomira_crypto_native", c.run[5]);
    try t.expectEqual(@as(usize, 12), c.build.len);
    try t.expectEqualStrings("-lkomira_log_holder", c.build[7]);
    try t.expectEqualStrings("-rpath", c.build[9]);
    try t.expectEqualStrings("$ORIGIN/../lib", c.build[11]);
}

test "no block is none, and a sh block without the marker is prose" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect((try parse(a, "# X\n\n```sh\nmojo run -lx prog.mojo\n```\n")) == .none);
}

test "each refusal names its README line" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok_run = "mojo run -Xlinker -lx p.mojo\n";
    const ok_build = "mojo build -Xlinker -lx p.mojo -o p\n";
    const cases = [_]struct { text: []const u8, want: []const u8 }{
        .{ .text = "```sh komira_link\n" ++ ok_run ++ ok_build ++ "```\n", .want = "src/x/README.md:1: `sh komira_link` is not `sh komira-link`" },
        .{ .text = "```sh komira-link extra\n" ++ ok_run ++ ok_build ++ "```\n", .want = "src/x/README.md:1: `sh komira-link extra` is not" },
        .{ .text = "```sh komira-link\n" ++ ok_run ++ ok_build ++ "```\n\n```sh komira-link\n" ++ ok_run ++ ok_build ++ "```\n", .want = "src/x/README.md:6: a second `sh komira-link` block (the first is at line 1)" },
        .{ .text = "```sh komira-link\n" ++ ok_run ++ ok_build, .want = "src/x/README.md:1: the `sh komira-link` block is never closed" },
        .{ .text = "```sh komira-link\n" ++ ok_run ++ "```\n", .want = "src/x/README.md:1: the `sh komira-link` block holds 1 lines" },
        .{ .text = "```sh komira-link\n" ++ ok_run ++ "\n" ++ ok_build ++ "```\n", .want = "src/x/README.md:1: the `sh komira-link` block holds 3 lines" },
        .{ .text = "```sh komira-link\n" ++ ok_build ++ ok_run ++ "```\n", .want = "src/x/README.md:2: line 1 of the block is not `mojo run ARGS... PROGRAM.mojo`" },
        .{ .text = "```sh komira-link\n" ++ ok_run ++ "mojo build -lx p.mojo\n```\n", .want = "src/x/README.md:3: line 2 of the block is not `mojo build ARGS... PROGRAM.mojo -o OUT`" },
        .{ .text = "```sh komira-link\nmojo run a.mojo -lx b.mojo\n" ++ ok_build ++ "```\n", .want = "src/x/README.md:2: line 1 of the block is not" },
        .{ .text = "```sh komira-link\nmojo run \"-lx\" p.mojo\n" ++ ok_build ++ "```\n", .want = "src/x/README.md:2: `\"`: the block is plain words" },
        .{ .text = "```sh komira-link\nmojo run -lx p.mojo; rm x\n" ++ ok_build ++ "```\n", .want = "src/x/README.md:2: `;`" },
        .{ .text = "```sh komira-link\nmojo run -L$HOME/lib p.mojo\n" ++ ok_build ++ "```\n", .want = "src/x/README.md:2: `$` outside quotes begins only `$CONDA_PREFIX`" },
        .{ .text = "```sh komira-link\nmojo run -L$CONDA_PREFIXX p.mojo\n" ++ ok_build ++ "```\n", .want = "src/x/README.md:2: `$` outside quotes" },
        .{ .text = "```sh komira-link\nmojo run '-L$CONDA_PREFIX/lib' p.mojo\n" ++ ok_build ++ "```\n", .want = "src/x/README.md:2: `$CONDA_PREFIX` inside single quotes" },
        .{ .text = "```sh komira-link\nmojo run '-lx p.mojo\n" ++ ok_build ++ "```\n", .want = "src/x/README.md:2: an unclosed single quote" },
    };
    for (cases) |c| {
        const why = try refusal(a, c.text);
        if (!std.mem.startsWith(u8, why, c.want)) {
            std.debug.print("got: {s}\nwant: {s}\n", .{ why, c.want });
            return error.WrongRefusal;
        }
    }
}

test "words: single quotes join to the word around them" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = (try link.words(a, "a  -Wl,'$ORIGIN/x'y\tb")).words;
    try t.expectEqual(@as(usize, 3), w.len);
    try t.expectEqualStrings("-Wl,$ORIGIN/xy", w[1]);
}
