//! Subresource integrity strings of npm (`sha512-<base64>`), and the digest
//! of a tarball in that form.
const std = @import("std");

pub const prefix = "sha512-";

/// `sha512-<base64 of the 64-byte digest of bytes>`; the caller frees it.
pub fn of(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha512.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(bytes, &digest, .{});
    const enc = std.base64.standard.Encoder;
    const out = try a.alloc(u8, prefix.len + enc.calcSize(digest.len));
    @memcpy(out[0..prefix.len], prefix);
    _ = enc.encode(out[prefix.len..], &digest);
    return out;
}

/// Whether `sri` is a sha512 integrity of 64 bytes in base64.
pub fn wellFormed(sri: []const u8) bool {
    if (!std.mem.startsWith(u8, sri, prefix)) return false;
    const b64 = sri[prefix.len..];
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(b64) catch return false;
    if (n != 64) return false;
    var buf: [64]u8 = undefined;
    dec.decode(&buf, b64) catch return false;
    return true;
}
