//! analysis_refusals_adopt_deps: `mojo_adopted_library` holds its `deps` to the closure of its `lib`
//! (tools/build/mojo/adopt.bzl). `-c adopt_deps.case=...` selects the case of tests//negative/adopt_deps:
//! `missing` and `extra` are refused at analysis, naming the package and the side that lacks it, and
//! `agree` (the control, the same `lib` with the right list) analyses. Catches either direction of the
//! check removed: a dependency the manifest has and the BUCK file lacks building green (the dependents of
//! the label would then compile without it), and one the BUCK file adds that the manifest does not reach.
//! The `native_*` cases hold `native_static`: an adopted library with `c_deps` (komira_metrics' `:lib`) and a dependent whose closure
//! check (`native_refusal_test`) states no unshipped C is refused without `native_static = True` (the closure
//! links the C and no library ships it) and analyses with it; the same library with the C stated as unshipped
//! analyses, so the refusal is about the library's attribute and not about the check. Catches `native_static`
//! not reaching the closure facts of an adopted library.
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
    .{
        .name = "native_unshipped",
        .target = "tests//negative/adopt_deps:native_closure",
        .text = "that no library of its closure ships; the test states []",
        .cfg = &.{"adopt_deps.case=native_unshipped"},
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
    // The controls of the `native_*` refusal: with the C stated as unshipped the check holds (the closure does
    // link it), and with `native_static = True` the check that states none holds (the library ships it).
    const native_controls = [_][]const u8{ "native_unshipped_stated", "native_static" };
    for (native_controls) |case| {
        const check = "tests//negative/adopt_deps:native_closure";
        var buf: [64]u8 = undefined;
        const cfg = try std.fmt.bufPrint(&buf, "adopt_deps.case={s}", .{case});
        const r = try c.run(&.{ "audit", "providers", check }, .{ .cfg = &.{cfg} });
        if (r.ok()) {
            c.pass("{s}: {s} analyses", .{ case, check });
        } else {
            c.fail("{s}: {s} was refused (see {s})", .{ case, check, r.log });
        }
    }
}

pub fn main() u8 {
    return lib.main(body);
}
