//! uquery_select_branches: an unconfigured query follows every branch of a
//! select, including the prelude's never-taken
//! `toolchains//:cxx_no_default_deps` of its C/C++ toolchain select. The
//! query over a Mojo binary linking a C library must answer, and its answer
//! must hold that label as a line of its own, or the query did not traverse
//! the select. Catches `cxx_no_default_deps` deleted from the toolchains
//! cell (the query then fails with `Unknown target`).
const std = @import("std");
const lib = @import("lib/lib.zig");

fn body(c: *lib.Ctx) !void {
    const res = try c.run(&.{ "uquery", "deps(//tools/build/examples/cshim:cadd_user)" }, .{});
    if (!res.ok()) {
        c.fail("uquery deps(cshim:cadd_user) failed (see {s}); its last lines:\n{s}", .{ res.log, lib.text.tail(res.stderr, 8) });
        return;
    }
    c.rep.check(lib.parse.hasLine(res.stdout, "toolchains//:cxx_no_default_deps"), "uquery deps of a C/C++ user answers, through toolchains//:cxx_no_default_deps", try std.fmt.allocPrint(c.a, "the answer does not reach toolchains//:cxx_no_default_deps (see {s})", .{res.log}));
}

pub fn main() u8 {
    return lib.main(body);
}
