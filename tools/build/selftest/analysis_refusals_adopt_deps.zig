//! analysis_refusals_adopt_deps: `mojo_adopted_library` holds its `deps` to the closure of its `lib`
//! (tools/build/mojo/adopt.bzl). `-c adopt_deps.case=...` selects the case of tests//negative/adopt_deps:
//! `missing` and `extra` are refused at analysis, naming the package and the side that lacks it, and
//! `agree` (the control, the same `lib` with the right list) analyses. Catches either direction of the
//! check removed: a dependency the manifest has and the BUCK file lacks building green (the dependents of
//! the label would then compile without it), and one the BUCK file adds that the manifest does not reach.
const std = @import("std");
const lib = @import("lib/lib.zig");

const ROWS = [_]lib.Row{
    .{
        .name = "missing",
        .target = "tests//negative/adopt_deps:adopted",
        .text = "is built from komira_runtime_paths, which `deps` does not bring",
        .cfg = &.{"adopt_deps.case=missing"},
    },
    .{
        .name = "extra",
        .target = "tests//negative/adopt_deps:adopted",
        .text = "`deps` brings komira_json, which `lib` (komira//src/komira_resources:lib) is not built from",
        .cfg = &.{"adopt_deps.case=extra"},
    },
};

fn body(c: *lib.Ctx) !void {
    try c.refusals(&ROWS);
    // The control: the same `lib` with the list its manifest gives analyses, so the two refusals above are
    // about the lists and not about the case's other attributes.
    const target = "tests//negative/adopt_deps:adopted";
    const res = try c.run(&.{ "audit", "providers", target }, .{ .cfg = &.{"adopt_deps.case=agree"} });
    if (res.ok()) {
        c.pass("agree: {s} analyses with deps = [komira_runtime_paths]", .{target});
    } else {
        c.fail("agree: {s} was refused, but its deps are the closure of its lib (see {s})", .{ target, res.log });
    }
}

pub fn main() u8 {
    return lib.main(body);
}
