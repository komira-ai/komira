//! The publish: each package of the set, in the set's order (every platform package, then the main package,
//! which names them), with `npm publish <file> --access public`. npm.yml's `publish` job runs it in the
//! environment `npm` with `id-token: write` and no token: npm's trusted publishing exchanges the job's OIDC
//! token for the publish, and adds the provenance itself.
//!
//! Before each package the registry is asked for that version (`npm view <name>@<version> dist.integrity
//! --json`): absent (no output, or E404, on stderr or as the JSON error's code, for a package the registry
//! does not have yet), it is published; there
//! with the set's integrity, it is not published again (a re-run of a job whose earlier attempt published
//! some packages), and the log says so; there with another integrity, the publish stops, since npm takes a
//! (name, version) once and the set's bytes can never be published at it. A failed publish stops the run: the
//! packages before it are published and the ones after it are not, so the main package is never published
//! naming a platform package that is missing.
const std = @import("std");
const common = @import("common.zig");
const npm = @import("npm.zig");
const set_mod = @import("set.zig");

const Allocator = common.Allocator;
const Error = common.Error;
const refuse = common.refuse;

/// What the registry holds at a package's version.
pub const State = enum { absent, same };

/// Whether the registry holds `p` (refused when it holds other bytes at that version, or cannot be asked).
pub fn state(a: Allocator, why: *[]const u8, runner: npm.Runner, tools: npm.Tools, p: set_mod.Package) Error!State {
    const spec = try std.fmt.allocPrint(a, "{s}@{s}", .{ p.name, p.version });
    const argv = try tools.argv(a, &.{ "view", spec, "dist.integrity", "--json" });
    const what = try std.fmt.allocPrint(a, "asking the registry for {s}", .{spec});
    const r = try npm.run(a, why, runner, what, argv, tools.work);
    const out = std.mem.trim(u8, r.stdout, " \t\r\n");
    if (r.code != null and r.code.? == 0) {
        if (out.len == 0) return .absent;
        const quoted = try std.fmt.allocPrint(a, "\"{s}\"", .{p.integrity});
        if (std.mem.eql(u8, out, quoted)) return .same;
        return refuse(a, why, "{s} is on the registry with the integrity {s}, not the set's {s}: npm takes a version once, so nothing is published over it", .{ spec, out, p.integrity });
    }
    // npm names the error on stderr, and with --json also in the JSON it prints on stdout
    if (std.mem.indexOf(u8, r.stderr, "E404") != null or std.mem.indexOf(u8, r.stdout, "\"E404\"") != null) return .absent;
    return npm.failed(a, why, what, argv, r);
}

/// Publishes every package of `set` from `dir` that the registry does not hold yet, in the set's order.
pub fn run(a: Allocator, why: *[]const u8, runner: npm.Runner, tools: npm.Tools, set: set_mod.Set, dir: []const u8, log: *std.Io.Writer) !void {
    try tools.prepare(a, why);
    for (set.packages) |p| {
        const spec = try std.fmt.allocPrint(a, "{s}@{s}", .{ p.name, p.version });
        switch (try state(a, why, runner, tools, p)) {
            .same => {
                try log.print("npm_smoke: {s} is on the registry with the set's integrity: not published again\n", .{spec});
                continue;
            },
            .absent => {},
        }
        const file = try std.fs.path.join(a, &.{ dir, p.file });
        const argv = try tools.argv(a, &.{ "publish", file, "--access", "public" });
        const what = try std.fmt.allocPrint(a, "publishing {s}", .{spec});
        const r = try npm.run(a, why, runner, what, argv, tools.work);
        if (r.code == null or r.code.? != 0) return npm.failed(a, why, what, argv, r);
        try log.print("npm_smoke: published {s} ({s}, {s})\n", .{ spec, p.file, p.integrity });
    }
    try log.flush();
}
