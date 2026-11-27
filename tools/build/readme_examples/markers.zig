//! The marker words of every document whose examples are files
//! (docs/design/documentation_tests.md, "Marker comments"), spelled here
//! once: include.zig holds a README's and a task page's includes with them,
//! and examples.zig reads an include marker with them. Pure: no I/O.

const std = @import("std");

/// The marker words: an include, and a fence that shows no file.
pub const MARKERS = struct {
    pub const open = "<!-- ";
    pub const close = " -->";
    pub const include = "include ";
    pub const not_tested = "not-tested: ";
};

/// The argument of the marker `word` that `line` is, whole, or null when
/// it is not that marker.
pub fn marker(line: []const u8, comptime word: []const u8) ?[]const u8 {
    const head = MARKERS.open ++ word;
    if (!std.mem.startsWith(u8, line, head) or !std.mem.endsWith(u8, line, MARKERS.close)) return null;
    if (line.len < head.len + MARKERS.close.len) return null;
    return line[head.len .. line.len - MARKERS.close.len];
}
