//! The committed publish gate, release/npm_publish.txt, read as npm.yml's build job reads it
//! (release/ci/npm_smoke/gate.zig), by //release:npm_publish_gate_cases as a build action: a file that is not
//! one `publish: off` or `publish: on` line among comments fails the pull request that changes it, not the
//! build job of main after it merged. Whether it says off or on is the owner's go (docs/ci.md, "npm.yml:
//! publishing the npm packages"); this case holds only that it says one of them.
const std = @import("std");
const lib = @import("npm_smoke_lib");
const t = std.testing;

test "release/npm_publish.txt is one publish line, off or on" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const work = try std.process.getEnvVarOwned(a, "KOMIRA_TEST_WORK");
    const text = try std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ work, "npm_publish.txt" }), 1 << 16);
    var why: []const u8 = "";
    _ = lib.gate.parse(a, &why, "release/npm_publish.txt", text) catch |e| {
        std.debug.print("{s}\n", .{why});
        return e;
    };
}
