//! The character sets every string kpin reads from a file or a registry must
//! stay inside before it is written into the lock. The lock is Starlark that
//! Buck2 executes, so a registry-supplied value with a quote in it would be
//! code in the build graph; nothing outside these sets is ever emitted.

const std = @import("std");

fn all(s: []const u8, comptime ok: fn (u8) bool) bool {
    for (s) |c| if (!ok(c)) return false;
    return true;
}

fn alnum(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn nameChar(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or c == '-' or c == '_';
}

fn pkgChar(c: u8) bool {
    return alnum(c) or c == '-' or c == '_' or c == '.' or c == '@' or c == '/' or c == '+';
}

fn versionChar(c: u8) bool {
    return alnum(c) or c == '-' or c == '_' or c == '.' or c == '+';
}

fn urlChar(c: u8) bool {
    return alnum(c) or switch (c) {
        '-', '.', '_', '~', ':', '/', '?', '#', '@', '&', '+', ',', ';', '=', '%' => true,
        else => false,
    };
}

fn pathChar(c: u8) bool {
    return alnum(c) or c == '_' or c == '-' or c == '.';
}

fn lowerHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
}

/// A pin, platform or table name in pins.toml: lower-case, digits, `-`, `_`.
pub fn isPinName(s: []const u8) bool {
    return s.len >= 1 and s.len <= 64 and nameChar(s[0]) and s[0] != '-' and s[0] != '_' and all(s, nameChar);
}

/// The text substituted for `{platform}`.
pub fn isToken(s: []const u8) bool {
    return s.len >= 1 and s.len <= 64 and all(s, versionChar);
}

pub fn isVersion(s: []const u8) bool {
    return s.len >= 1 and s.len <= 64 and alnum(s[0]) and all(s, versionChar);
}

/// An npm package name, scope included (`@scope/name`).
pub fn isPackageName(s: []const u8) bool {
    if (s.len < 1 or s.len > 214 or !all(s, pkgChar)) return false;
    if (s[0] == '/' or s[0] == '.' or s[s.len - 1] == '/') return false;
    if (std.mem.indexOf(u8, s, "..") != null or std.mem.indexOf(u8, s, "//") != null) return false;
    return true;
}

pub fn isUrl(s: []const u8) bool {
    if (s.len > 2048 or !all(s, urlChar)) return false;
    const rest = if (std.mem.startsWith(u8, s, "https://")) s[8..] else if (std.mem.startsWith(u8, s, "http://")) s[7..] else return false;
    return rest.len > 0 and rest[0] != '/';
}

pub fn isSha256(s: []const u8) bool {
    return s.len == 64 and all(s, lowerHex);
}

/// `sha512-` and the base64 of exactly 64 bytes. Nothing else is an npm
/// integrity kpin accepts (a sha1 or sha256 integrity is refused).
pub fn isSri512(s: []const u8) bool {
    const prefix = "sha512-";
    if (!std.mem.startsWith(u8, s, prefix)) return false;
    const b64 = s[prefix.len..];
    if (b64.len != 88) return false;
    var out: [64]u8 = undefined;
    std.base64.standard.Decoder.decode(&out, b64) catch return false;
    return true;
}

/// A dotted path into a JSON document.
pub fn isJsonPath(s: []const u8) bool {
    return s.len >= 1 and s.len <= 128 and all(s, pathChar) and s[0] != '.' and s[s.len - 1] != '.' and std.mem.indexOf(u8, s, "..") == null;
}
