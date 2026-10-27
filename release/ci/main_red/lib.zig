//! The main-red alert's library (docs/ci.md, "The main red alert"): the
//! pieces main_red.zig runs and test_main_red.zig holds.
pub const args = @import("args.zig");
pub const gh = @import("gh.zig");
pub const issue = @import("issue.zig");
pub const logs = @import("logs.zig");
pub const range = @import("range.zig");
pub const run = @import("run.zig");
