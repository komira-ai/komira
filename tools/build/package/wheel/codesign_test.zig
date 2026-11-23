//! The code signature check (codesign.zig) on synthetic dylibs signed ad hoc
//! the way `ld` signs one (testing.zig, `adHocSignature`): a signature of each
//! hash type passes, and each way a signature can fail to match its file is
//! refused by its exact message: no signature, a page changed after signing,
//! a requirements blob changed, a code limit short of the signature, a slot
//! count that is not the page count, an unknown hash type or a hash size that
//! is not the type's, a special slot naming a bundle file, and a SuperBlob,
//! an index or a blob outside its bounds.

const std = @import("std");
const codesign = @import("codesign.zig");
const diag = @import("diag.zig");
const fixture = @import("testing.zig");
const t = std.testing;

fn refusal(a: std.mem.Allocator, data: []const u8) ![]const u8 {
    var d = diag.Diag{};
    try t.expectError(error.Refused, codesign.check(a, &d, "libx.dylib", data));
    return d.msg;
}

fn passes(a: std.mem.Allocator, data: []const u8) !void {
    var d = diag.Diag{};
    codesign.check(a, &d, "libx.dylib", data) catch |e| {
        std.debug.print("refused: {s}\n", .{d.msg});
        return e;
    };
}

fn put32le(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .little);
}

fn put32be(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .big);
}

fn get32le(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

fn get32be(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .big);
}

/// The offset of the signature (LC_CODE_SIGNATURE's dataoff): the fixture
/// writes that command last.
fn sigOff(b: []const u8) u32 {
    const cmds_end = 32 + get32le(b, 20);
    return get32le(b, cmds_end - 8);
}

/// The offset of the CodeDirectory, the SuperBlob's first blob.
fn cdOff(b: []const u8) usize {
    const sb = sigOff(b);
    return sb + get32be(b, sb + 16);
}

/// A dylib whose code (a byte pattern) and header end in its `pages`-th
/// 4096-byte page, signed ad hoc.
fn signed(a: std.mem.Allocator, pages: usize, hash_type: u8) ![]u8 {
    const code = try a.alloc(u8, pages * 4096 - 512);
    for (code, 0..) |*c, i| c.* = @truncate(i * 7 + 3);
    return a.dupe(u8, try fixture.machO(a, .{ .install_name = "@rpath/libx.dylib", .code = code, .hash_type = hash_type }));
}

test "an ad hoc signature of each hash type passes, over one page and over several" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try passes(a, try fixture.goodDylib(a));
    for ([_]u8{ codesign.HASH_SHA1, codesign.HASH_SHA256, codesign.HASH_SHA256_TRUNCATED, codesign.HASH_SHA384 }) |h| {
        try passes(a, try signed(a, 3, h));
    }
    // A page size of 2^0 is one page holding the whole code.
    try passes(a, try fixture.machO(a, .{ .install_name = "@rpath/libx.dylib", .page_shift = 0 }));
}

test "a file with no code signature is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings(
        "signature: libx.dylib has no code signature (no LC_CODE_SIGNATURE): macOS on arm64 refuses to load unsigned code",
        try refusal(a, try fixture.machO(a, .{ .install_name = "@rpath/libx.dylib", .unsigned = true })),
    );
}

test "a page changed after signing is refused, naming the page" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A byte of the second page (as install_name_tool or strip would change it).
    const b = try signed(a, 3, codesign.HASH_SHA256);
    b[4096 + 10] ^= 0xff;
    try t.expectEqualStrings(
        "signature: libx.dylib: page 1 (bytes 4096 to 8192) does not match its hash in the CodeDirectory: the file changed after it was signed",
        try refusal(a, b),
    );
    // The last page, shorter than a page, is hashed only up to the signature.
    const last = try signed(a, 3, codesign.HASH_SHA256);
    const off = sigOff(last);
    last[off - 1] ^= 0x01;
    const want = try std.fmt.allocPrint(a, "signature: libx.dylib: page 2 (bytes 8192 to {d}) does not match its hash in the CodeDirectory: the file changed after it was signed", .{off});
    try t.expectEqualStrings(want, try refusal(a, last));
    // The header is page 0: a load command changed after signing.
    const header = try a.dupe(u8, try fixture.goodDylib(a));
    header[12] = 8; // filetype
    try t.expectStringStartsWith(try refusal(a, header), "signature: libx.dylib: page 0 (bytes 0 to ");
}

test "a requirements blob changed after signing is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = try a.dupe(u8, try fixture.goodDylib(a));
    // The requirements blob is the signature's last 12 bytes; its count field.
    b[b.len - 1] = 1;
    try t.expectEqualStrings("signature: libx.dylib: the requirements blob does not match its hash in the CodeDirectory", try refusal(a, b));
}

test "a hash for a bundle file the signature cannot carry is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = try a.dupe(u8, try fixture.goodDylib(a));
    const cd = cdOff(b);
    const hash_off = get32be(b, cd + 16);
    // Special slot 1 (an Info.plist), just before the code slots.
    b[cd + hash_off - 1] = 0x5a;
    try t.expectEqualStrings("signature: libx.dylib: the CodeDirectory has a hash for an Info.plist, which the signature does not carry", try refusal(a, b));
}

test "a CodeDirectory that does not cover the file up to its signature is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = try signed(a, 2, codesign.HASH_SHA256);
    const cd = cdOff(b);
    put32be(b, cd + 32, sigOff(b) - 16);
    const want = try std.fmt.allocPrint(a, "signature: libx.dylib: the CodeDirectory covers {d} bytes, and the signature starts at {d}", .{ sigOff(b) - 16, sigOff(b) });
    try t.expectEqualStrings(want, try refusal(a, b));
    const slots = try signed(a, 2, codesign.HASH_SHA256);
    put32be(slots, cdOff(slots) + 28, 1);
    try t.expectEqualStrings("signature: libx.dylib: the CodeDirectory has 1 code slots for 2 pages", try refusal(a, slots));
}

test "an unknown hash type, or a hash size that is not the type's, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kind = try a.dupe(u8, try fixture.goodDylib(a));
    kind[cdOff(kind) + 37] = 9;
    try t.expectEqualStrings("signature: libx.dylib: a CodeDirectory of hash type 9, which is none of SHA-1, SHA-256 and SHA-384", try refusal(a, kind));
    const size = try a.dupe(u8, try fixture.goodDylib(a));
    size[cdOff(size) + 36] = 20;
    try t.expectEqualStrings("signature: libx.dylib: a CodeDirectory of hash type 2 with 20-byte hashes, not 32", try refusal(a, size));
}

test "a signature, an index or a blob outside its bounds is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try fixture.goodDylib(a);
    const cmd = 32 + get32le(good, 20) - 16;

    const past = try a.dupe(u8, good);
    put32le(past, cmd + 12, @intCast(good.len));
    try t.expectEqualStrings("signature: libx.dylib: the code signature lies outside the file", try refusal(a, past));

    const magic = try a.dupe(u8, good);
    put32be(magic, sigOff(magic), 0xfade0c02);
    try t.expectEqualStrings("signature: libx.dylib: the code signature is not an embedded-signature SuperBlob", try refusal(a, magic));

    const count = try a.dupe(u8, good);
    put32be(count, sigOff(count) + 8, 1000);
    try t.expectEqualStrings("signature: libx.dylib: the SuperBlob's index lies outside it", try refusal(a, count));

    const blob = try a.dupe(u8, good);
    put32be(blob, sigOff(blob) + 16, 0x7fffffff);
    try t.expectEqualStrings("signature: libx.dylib: a blob of the SuperBlob lies outside it", try refusal(a, blob));

    const blob_len = try a.dupe(u8, good);
    put32be(blob_len, cdOff(blob_len) + 4, 0x7fffffff);
    try t.expectEqualStrings("signature: libx.dylib: a blob of the SuperBlob lies outside it", try refusal(a, blob_len));

    const slots = try a.dupe(u8, good);
    put32be(slots, cdOff(slots) + 16, 0x7ff0);
    try t.expectEqualStrings("signature: libx.dylib: the CodeDirectory's hash slots lie outside it", try refusal(a, slots));

    const not_cd = try a.dupe(u8, good);
    put32be(not_cd, cdOff(not_cd), 0xfade0c01);
    try t.expectEqualStrings("signature: libx.dylib: the blob of slot 0 is not a CodeDirectory", try refusal(a, not_cd));

    // Only the requirements blob: slot 0 renumbered to an entitlements slot.
    const none = try a.dupe(u8, good);
    put32be(none, sigOff(none) + 12, codesign.SLOT_ENTITLEMENTS);
    try t.expectEqualStrings("signature: libx.dylib: the code signature holds no CodeDirectory", try refusal(a, none));
}

test "an LC_CODE_SIGNATURE too short, a signature before the code or too short for its header is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try fixture.goodDylib(a);
    const cmd = 32 + get32le(good, 20) - 16;
    const short_cmd = try a.dupe(u8, good);
    put32le(short_cmd, cmd + 4, 8);
    try t.expectEqualStrings("signature: libx.dylib has no code signature (no LC_CODE_SIGNATURE): macOS on arm64 refuses to load unsigned code", try refusal(a, short_cmd));
    const early = try a.dupe(u8, good);
    put32le(early, cmd + 8, 16);
    try t.expectEqualStrings("signature: libx.dylib: the code signature lies outside the file", try refusal(a, early));
    const tiny = try a.dupe(u8, good);
    put32le(tiny, cmd + 12, 8);
    try t.expectEqualStrings("signature: libx.dylib: the code signature lies outside the file", try refusal(a, tiny));
}

test "a CodeDirectory too short, of a page size past 2^30, or whose hashes overlap its header is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try fixture.goodDylib(a);
    const len = try a.dupe(u8, good);
    put32be(len, cdOff(len) + 4, 40);
    try t.expectEqualStrings("signature: libx.dylib: a CodeDirectory whose length lies outside the signature", try refusal(a, len));
    // The CodeDirectory's index entry moved to the signature's last 8 bytes, a CodeDirectory magic there.
    const cut = try a.dupe(u8, good);
    const sb = sigOff(cut);
    const sb_len = get32be(cut, sb + 4);
    put32be(cut, sb + 8, 1); // the index holds the CodeDirectory alone
    put32be(cut, sb + 16, sb_len - 8);
    put32be(cut, sb + sb_len - 8, codesign.CODEDIRECTORY_MAGIC);
    put32be(cut, sb + sb_len - 4, 8);
    try t.expectEqualStrings("signature: libx.dylib: a CodeDirectory shorter than its 44-byte header", try refusal(a, cut));
    const shift = try a.dupe(u8, good);
    shift[cdOff(shift) + 39] = 31;
    try t.expectEqualStrings("signature: libx.dylib: a CodeDirectory page size of 2^31", try refusal(a, shift));
    const overlap = try a.dupe(u8, good);
    put32be(overlap, cdOff(overlap) + 16, 44);
    try t.expectEqualStrings("signature: libx.dylib: the CodeDirectory's hash slots lie outside it", try refusal(a, overlap));
}

test "an index entry inside the index, or a blob shorter than its own header, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try fixture.goodDylib(a);
    const inside = try a.dupe(u8, good);
    put32be(inside, sigOff(inside) + 16, 12);
    try t.expectEqualStrings("signature: libx.dylib: a blob of the SuperBlob lies outside it", try refusal(a, inside));
    const short = try a.dupe(u8, good);
    const req = sigOff(short) + get32be(short, sigOff(short) + 24);
    put32be(short, req + 4, 4);
    try t.expectEqualStrings("signature: libx.dylib: a blob of the SuperBlob lies outside it", try refusal(a, short));
}

test "an alternate CodeDirectory is checked as the primary one is" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const alt = try signed(a, 2, codesign.HASH_SHA256);
    put32be(alt, sigOff(alt) + 12, codesign.SLOT_ALTERNATE_FIRST);
    try passes(a, alt);
    const last = try a.dupe(u8, alt);
    put32be(last, sigOff(last) + 12, codesign.SLOT_ALTERNATE_LAST);
    last[100] ^= 0xff;
    try t.expectEqualStrings("signature: libx.dylib: page 0 (bytes 0 to 4096) does not match its hash in the CodeDirectory: the file changed after it was signed", try refusal(a, last));
}

test "a blob no special slot hashes is refused, each kind by its name" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try fixture.goodDylib(a);
    const cd = cdOff(good);
    const hash_off = get32be(good, cd + 16);
    // The requirements blob renumbered past the CodeDirectory's two special slots (its slot-2 hash zeroed).
    for ([_]struct { slot: u32, want: []const u8 }{
        .{ .slot = 3, .want = "a resource directory" },
        .{ .slot = 4, .want = "application data" },
        .{ .slot = 5, .want = "entitlements" },
        .{ .slot = 6, .want = "a representation" },
        .{ .slot = 7, .want = "DER entitlements" },
        .{ .slot = 9, .want = "a special slot" },
    }) |c| {
        const b = try a.dupe(u8, good);
        @memset(b[cd + hash_off - 64 .. cd + hash_off - 32], 0);
        put32be(b, sigOff(b) + 20, c.slot);
        const want = try std.fmt.allocPrint(a, "signature: libx.dylib: the signature carries {s} (slot {d}), which no special slot of a CodeDirectory hashes", .{ c.want, c.slot });
        try t.expectEqualStrings(want, try refusal(a, b));
    }
    // A CMS blob is not hashed by a special slot, and is not refused for it.
    const cms = try a.dupe(u8, good);
    @memset(cms[cd + hash_off - 64 .. cd + hash_off - 32], 0);
    put32be(cms, sigOff(cms) + 20, codesign.SLOT_CMS);
    try passes(a, cms);
}
