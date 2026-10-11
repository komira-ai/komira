//! SHA-256 (FIPS 180-4, Zig's standard library), for the digests of an
//! image's blobs and layers.

const std = @import("std");
const C = @import("common.zig");

/// The SHA-256 of `data`, as 64 lower-case hex digits.
pub fn hex(data: []const u8) []u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &out, .{});
    return C.fmt("{s}", .{std.fmt.fmtSliceHexLower(&out)});
}

/// `sha256:<hex>` of `data`.
pub fn digest(data: []const u8) []u8 {
    return C.fmt("sha256:{s}", .{hex(data)});
}

test "sha256: known_answers" {
    const eq = std.testing.expectEqualStrings;
    // FIPS 180-4 examples, and lengths around the padding boundary.
    try eq("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", hex(""));
    try eq("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", hex("abc"));
    try eq("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"));
    const million = C.a().alloc(u8, 1_000_000) catch C.oom();
    @memset(million, 'a');
    try eq("cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0", hex(million));
    try eq("9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318", hex(million[0..55]));
    try eq("ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb", hex(million[0..64]));
    try eq("sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", digest("abc"));
}
