//! changelog: the assembler of the Python package's changelog, as a module its command (main.zig) and its
//! cases import. cli.zig says what the command does, changelog.zig what the changelog is made of.
pub const changelog = @import("changelog.zig");
pub const cli = @import("cli.zig");
