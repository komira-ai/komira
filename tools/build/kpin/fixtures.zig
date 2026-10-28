//! Test support: known digests and small builders for the inputs.

const std = @import("std");

/// The bytes the fake registry serves for most files.
pub const ABC = "abc";
pub const ABC_SHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
pub const ABC_SRI512 = "sha512-3a81oZNherrMQXNJriBBMRLm+k6JqX6iCp7u5ktV05ohkpkqJ0/BqDa6PCOj/uu9RU1EI2Q86A4qmslPpUyknw==";
/// Other bytes, for a registry that republished.
pub const ABD = "abd";

pub fn sha256Hex(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(d, .lower));
}

pub fn sri512(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var d: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(bytes, &d, .{});
    var buf: [88]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&buf, &d);
    return std.fmt.allocPrint(a, "sha512-{s}", .{buf});
}

pub const NpmEntry = struct { path: []const u8, name: ?[]const u8 = null, version: []const u8, resolved: []const u8, integrity: []const u8 };

/// A package-lock.json (lockfileVersion 3) with these packages.
pub fn packageLock(a: std.mem.Allocator, entries: []const NpmEntry) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, "{\"name\":\"app\",\"lockfileVersion\":3,\"requires\":true,\"packages\":{\"\":{\"name\":\"app\",\"version\":\"1.0.0\"}");
    for (entries) |e| {
        try out.print(a, ",\"{s}\":{{", .{e.path});
        if (e.name) |n| try out.print(a, "\"name\":\"{s}\",", .{n});
        try out.print(a, "\"version\":\"{s}\",\"resolved\":\"{s}\",\"integrity\":\"{s}\"}}", .{ e.version, e.resolved, e.integrity });
    }
    try out.appendSlice(a, "}}");
    return out.toOwnedSlice(a);
}
