//! The release tools' library (docs/ci.md, "release.yml"): what
//! check_release_ref.zig and release_json.zig run, and what
//! release/ci/tests/test_release.zig holds.
pub const util = @import("util.zig");
pub const ref_guard = @import("ref_guard.zig");
pub const stamp = @import("stamp.zig");
pub const artifacts = @import("artifacts.zig");
pub const set_json = @import("set_json.zig");
