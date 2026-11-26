//! changelog: forwards to the library (lib.zig).
pub fn main() !u8 {
    return @import("changelog_lib").cli.main();
}
