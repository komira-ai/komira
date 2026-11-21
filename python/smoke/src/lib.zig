//! pypi_smoke: the driver of .github/workflows/pypi.yml and of the user test of the wheel in release.yml, as a
//! module its command (../src/main.zig) and its cases import. cli.zig says what each command does.
pub const cli = @import("cli.zig");
pub const common = @import("common.zig");
pub const index = @import("index.zig");
pub const install = @import("install.zig");
pub const matrix = @import("matrix.zig");
pub const meta = @import("meta.zig");
pub const readme = @import("readme.zig");

/// The client and the wheel zip the driver is built on, for the cases to make routes and wheels with.
pub const fetch = @import("release_beta_fetch");
pub const zip = @import("wheel_zip");
