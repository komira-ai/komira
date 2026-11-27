//! npm_smoke: forwards to the library (npm_smoke/lib.zig; npm_smoke/cli.zig says what each command does).
pub fn main() !u8 {
    return @import("npm_smoke_lib").cli.main();
}
