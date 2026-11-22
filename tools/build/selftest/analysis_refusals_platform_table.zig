//! analysis_refusals_platform_table: the platform table
//! (tools/build/platforms/table.bzl) and the platforms it declares.
//!
//! 1. `tests//functional/platform_table` loads: its load-time cases
//!    (cases.bzl) hold, so the committed table is complete and a table
//!    missing a pin or a field, with a pending pin in a registered row, a
//!    malformed sha256, a duplicate key or host, is refused naming the row
//!    and the pin, and each host_info() selects the right row or is refused.
//!    Catches a pending pin accepted.
//! 2. `komira//tools/build/platforms` declares exactly darwin-arm64, host,
//!    linux-arm64 and linux-x86_64: a platform per registered row.
//! 3. `host` is this client's platform (the guard holds the client to Linux
//!    x86_64): it is linux-x86_64, and a target stating no
//!    --target-platforms is configured for it.
const std = @import("std");
const lib = @import("lib/lib.zig");

const LINUX = "komira//tools/build/platforms:linux-x86_64";

fn body(c: *lib.Ctx) !void {
    // 1
    const cases = try c.run(&.{ "targets", "tests//functional/platform_table:" }, .{});
    c.rep.check(cases.ok(), "cases: tests//functional/platform_table loads, so every load-time case of cases.bzl holds", cases.log);

    // 2
    const t = try c.run(&.{ "targets", "komira//tools/build/platforms:" }, .{});
    const names = try lib.parse.targetNames(c.a, t.stdout);
    var platforms = std.ArrayList([]const u8).empty;
    for (names) |n| if (!std.mem.eql(u8, n, "doc_tree")) try platforms.append(c.a, n);
    const want = [_][]const u8{ "darwin-arm64", "host", "linux-arm64", "linux-x86_64" };
    if (t.ok() and lib.text.eqlLists(&want, platforms.items)) {
        c.pass("platforms: komira//tools/build/platforms declares darwin-arm64, host, linux-arm64 and linux-x86_64, a platform per registered row", .{});
    } else {
        c.fail("platforms: komira//tools/build/platforms declares [{s}], want [darwin-arm64 host linux-arm64 linux-x86_64] (see {s})", .{ try lib.text.join(c.a, platforms.items, " "), t.log });
    }

    // 3
    const host = try c.run(&.{ "audit", "providers", "komira//tools/build/platforms:host" }, .{});
    const label = "label=\"" ++ LINUX ++ "\"";
    c.rep.check(host.ok() and lib.text.contains(host.stdout, label), "host: komira//tools/build/platforms:host is linux-x86_64 on this Linux x86_64 client", host.log);
    const dflt = try c.run(&.{ "cquery", "komira//tools/build/toolchains:conda_unpack" }, .{});
    c.rep.check(dflt.ok() and lib.parse.configuredFor(dflt.stdout, LINUX), "host: a target stating no --target-platforms is configured for linux-x86_64", dflt.log);
}

pub fn main() u8 {
    return lib.main(body);
}
