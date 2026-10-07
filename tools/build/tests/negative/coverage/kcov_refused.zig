//! A planted defect (test 43): a kcov that fails as kcov v42 does when the
//! executor refuses personality(ADDR_NO_RANDOMIZE) (a seccomp profile):
//! its child prints perror's line and kcov exits 255. cov_run.sh must say
//! that kcov could not trace the test, not that the test failed.

const std = @import("std");

pub fn main() void {
    std.io.getStdErr().writer().print("Can't set personality: Operation not permitted\n", .{}) catch {};
    std.process.exit(255);
}
