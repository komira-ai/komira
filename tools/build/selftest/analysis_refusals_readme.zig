//! analysis_refusals_readme: the README examples' refusals
//! (tools/build/mojo/readme.bzl): a library whose base has no README has no
//! `[readme]` sub-target, and the `readme` keyword is refused at load when it
//! is True without a README.md or not a bool (`-c readme_keyword.case=...`
//! selects the case). Catches the bool check removed.
const std = @import("std");
const lib = @import("lib/lib.zig");

const ROWS = [_]lib.Row{
    .{
        .name = "readme_owner_base_no_readme",
        .target = "tests//functional/readme_examples/owner:owner_base[tests][readme]",
        .text = "requested sub target named `readme` of target `tests//functional/readme_examples/owner:owner_base[tests][readme] (",
        .also = &.{ "` is not available. Available subtargets are: `[]`" },
    },
    .{
        .name = "readme_keyword_true_without_readme",
        .target = "tests//negative/readme_examples/readme_keyword:kw",
        .text = "kw: `readme = True` and //negative/readme_examples/readme_keyword holds no README.md",
        .cfg = &.{ "readme_keyword.case=true_without_readme" },
    },
    .{
        .name = "readme_keyword_not_bool",
        .target = "tests//negative/readme_examples/readme_keyword:kw",
        .text = "kw: `readme` takes True, False or nothing (the package's README.md, if any), not \"README.md\"",
        .cfg = &.{ "readme_keyword.case=not_bool" },
    },
};

fn body(c: *lib.Ctx) !void {
    try c.refusals(&ROWS);
}

pub fn main() u8 {
    return lib.main(body);
}
