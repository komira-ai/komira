//! analysis_refusals_mopm_artifacts: the refusals of `natives` in
//! release/mopm_artifacts.bzl, which holds the attribute to the
//! `[native.<id>]` each package's mopm.toml declares (read from the package's
//! unit graph, release/mopm_native_ids.bzl). `-c mopm_artifacts.case=...`
//! selects the case of tests//negative/mopm_artifacts. Catches either
//! direction of the check removed: a wrong id building green, or a declared
//! native with no entry building green.
const std = @import("std");
const lib = @import("lib/lib.zig");

const ROWS = [_]lib.Row{
    .{
        .name = "wrong_id",
        .target = "tests//negative/mopm_artifacts:artifacts",
        .text = "artifacts: natives names komira_libc.komira_libc_posx, but the mopm.toml of komira_libc declares no [native.komira_libc_posx] (it declares: komira_libc_posix)",
        .cfg = &.{"mopm_artifacts.case=wrong_id"},
    },
    .{
        .name = "missing_entry",
        .target = "tests//negative/mopm_artifacts:artifacts",
        .text = "artifacts: komira_libc declares [native.komira_libc_posix] in its mopm.toml, and natives has no entry for it",
        .cfg = &.{"mopm_artifacts.case=missing_entry"},
    },
};

fn body(c: *lib.Ctx) !void {
    try c.refusals(&ROWS);
}

pub fn main() u8 {
    return lib.main(body);
}
