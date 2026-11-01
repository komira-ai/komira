//! npm's os/cpu/libc test: a list of allowed names, or of `!name` refusals.
const std = @import("std");

/// The platform this tool lays out for: linux, x64, glibc.
pub const os = "linux";
pub const cpu = "x64";
pub const libc = "glibc";

/// `list` is the lockfile's array for the field (null when absent). True when
/// `current` may be installed: no list, or not refused and (no allowed names
/// or named among them).
pub fn ok(list: ?std.json.Value, current: []const u8) bool {
    const v = list orelse return true;
    if (v != .array or v.array.items.len == 0) return true;
    var any_allowed = false;
    var allowed = false;
    for (v.array.items) |x| {
        if (x != .string) continue;
        const s = x.string;
        if (s.len > 0 and s[0] == '!') {
            if (std.mem.eql(u8, s[1..], current)) return false;
        } else {
            any_allowed = true;
            if (std.mem.eql(u8, s, current)) allowed = true;
        }
    }
    return !any_allowed or allowed;
}
