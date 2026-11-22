//! pypi_smoke: forwards to the library (lib.zig).
pub fn main() !u8 {
    return @import("pypi_smoke_lib").cli.main();
}
