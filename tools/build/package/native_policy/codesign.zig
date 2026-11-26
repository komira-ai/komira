//! native_policy: the code signature of a Mach-O file, checked against the
//! file's bytes as `codesign --verify` checks an ad hoc signature. macOS on
//! arm64 refuses to map code whose signature is missing or does not match its
//! pages, so a wheel member that fails here is a library a Mac will not load.
//!
//! What is held, each refusal naming the file:
//!   * the file has an LC_CODE_SIGNATURE command, and the signature it names
//!     lies inside the file;
//!   * the signature is an embedded-signature SuperBlob whose index entries lie
//!     inside it, holding at least one CodeDirectory (the primary one, slot 0;
//!     an alternate one, slots 0x1000 to 0x1004, is checked the same way);
//!   * each CodeDirectory covers the file exactly up to the signature
//!     (`codeLimit` is the signature's offset), with one hash slot per page;
//!   * its hash type is SHA-1, SHA-256, SHA-256 truncated to 20 bytes or
//!     SHA-384, and its hash size is that type's;
//!   * every page of the file hashes to its code slot;
//!   * every blob of the signature other than a CodeDirectory or a CMS blob
//!     (requirements, entitlements) has a special slot, holding its hash, and
//!     every special slot naming no blob is zero: a library in a wheel has no
//!     bundle, so a slot for an Info.plist or a resource directory names a
//!     file it cannot have.
//!
//! A CMS blob (a Developer ID signature, slot 0x10000) is not verified: the
//! hashes above are what binds the code to the signature, ad hoc or not.

const std = @import("std");
const diag = @import("diag.zig");
const Alloc = std.mem.Allocator;
const Diag = diag.Diag;
const Refused = diag.Refused;
const refuse = diag.refuse;

pub const LC_CODE_SIGNATURE: u32 = 0x1d;
pub const SUPERBLOB_MAGIC: u32 = 0xfade0cc0;
pub const CODEDIRECTORY_MAGIC: u32 = 0xfade0c02;
pub const SLOT_CODEDIRECTORY: u32 = 0;
pub const SLOT_REQUIREMENTS: u32 = 2;
pub const SLOT_ENTITLEMENTS: u32 = 5;
pub const SLOT_DER_ENTITLEMENTS: u32 = 7;
pub const SLOT_ALTERNATE_FIRST: u32 = 0x1000;
pub const SLOT_ALTERNATE_LAST: u32 = 0x1004;
pub const SLOT_CMS: u32 = 0x10000;
pub const HASH_SHA1: u8 = 1;
pub const HASH_SHA256: u8 = 2;
pub const HASH_SHA256_TRUNCATED: u8 = 3;
pub const HASH_SHA384: u8 = 4;

/// The size of a hash of `kind`; null for a kind this reader does not know.
pub fn hashSize(kind: u8) ?usize {
    return switch (kind) {
        HASH_SHA1, HASH_SHA256_TRUNCATED => 20,
        HASH_SHA256 => 32,
        HASH_SHA384 => 48,
        else => null,
    };
}

/// The hash of `kind` over `data`, written to the front of `out` (48 bytes,
/// the largest); returns the hash's bytes.
pub fn hash(kind: u8, data: []const u8, out: *[48]u8) []const u8 {
    switch (kind) {
        HASH_SHA1 => {
            std.crypto.hash.Sha1.hash(data, out[0..20], .{});
            return out[0..20];
        },
        HASH_SHA256, HASH_SHA256_TRUNCATED => {
            std.crypto.hash.sha2.Sha256.hash(data, out[0..32], .{});
            return out[0..hashSize(kind).?];
        },
        else => {
            std.crypto.hash.sha2.Sha384.hash(data, out[0..48], .{});
            return out[0..48];
        },
    }
}

fn be(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .big);
}

fn le(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

/// Where the signature is: LC_CODE_SIGNATURE's `dataoff` and `datasize`, or
/// null when the file has no such command. The file's header and load
/// commands were read by macho.zig first, so they lie inside the file.
fn signatureRange(data: []const u8) ?struct { off: u32, size: u32 } {
    const ncmds = le(data, 16);
    var at: usize = 32;
    var i: u32 = 0;
    while (i < ncmds) : (i += 1) {
        const cmd = le(data, at);
        const size = le(data, at + 4);
        if (cmd == LC_CODE_SIGNATURE and size >= 16) return .{ .off = le(data, at + 8), .size = le(data, at + 12) };
        at += size;
    }
    return null;
}

fn slotName(t: u32) []const u8 {
    return switch (t) {
        1 => "an Info.plist",
        2 => "requirements",
        3 => "a resource directory",
        4 => "application data",
        5 => "entitlements",
        6 => "a representation",
        7 => "DER entitlements",
        else => "a special slot",
    };
}

/// One CodeDirectory, `cd` (its bytes up to the SuperBlob's end; its own
/// length field is bounded against them),
/// against the file `data` and the SuperBlob `sb` its special slots name.
fn checkDirectory(alloc: Alloc, d: *Diag, name: []const u8, data: []const u8, sig_off: u32, sb: []const u8, cd: []const u8) Refused!void {
    if (cd.len < 44) return refuse(d, alloc, "signature: {s}: a CodeDirectory shorter than its 44-byte header", .{name});
    const len = be(cd, 4);
    if (len < 44 or len > cd.len) return refuse(d, alloc, "signature: {s}: a CodeDirectory whose length lies outside the signature", .{name});
    const c = cd[0..len];
    const hash_off = be(c, 16);
    const n_special = be(c, 24);
    const n_code = be(c, 28);
    const code_limit = be(c, 32);
    const hsize: usize = c[36];
    const kind = c[37];
    const page_shift = c[39];
    const want_size = hashSize(kind) orelse return refuse(d, alloc, "signature: {s}: a CodeDirectory of hash type {d}, which is none of SHA-1, SHA-256 and SHA-384", .{ name, kind });
    if (hsize != want_size) return refuse(d, alloc, "signature: {s}: a CodeDirectory of hash type {d} with {d}-byte hashes, not {d}", .{ name, kind, hsize, want_size });
    if (code_limit != sig_off) return refuse(d, alloc, "signature: {s}: the CodeDirectory covers {d} bytes, and the signature starts at {d}", .{ name, code_limit, sig_off });
    if (page_shift > 30) return refuse(d, alloc, "signature: {s}: a CodeDirectory page size of 2^{d}", .{ name, page_shift });
    // code_limit is the signature's offset, past the file's 32-byte header (check).
    const page: usize = if (page_shift == 0) code_limit else @as(usize, 1) << @intCast(page_shift);
    const pages: usize = (code_limit + page - 1) / page;
    if (n_code != pages) return refuse(d, alloc, "signature: {s}: the CodeDirectory has {d} code slots for {d} pages", .{ name, n_code, pages });
    if (hash_off < 44 + @as(usize, n_special) * hsize or hash_off + @as(usize, n_code) * hsize > c.len)
        return refuse(d, alloc, "signature: {s}: the CodeDirectory's hash slots lie outside it", .{name});

    var buf: [48]u8 = undefined;
    var p: usize = 0;
    while (p < pages) : (p += 1) {
        const start = p * page;
        const end = @min(start + page, code_limit);
        const got = hash(kind, data[start..end], &buf);
        const slot = c[hash_off + p * hsize ..][0..hsize];
        if (!std.mem.eql(u8, got, slot))
            return refuse(d, alloc, "signature: {s}: page {d} (bytes {d} to {d}) does not match its hash in the CodeDirectory: the file changed after it was signed", .{ name, p, start, end });
    }

    var t: u32 = 1;
    while (t <= n_special) : (t += 1) {
        const slot = c[hash_off - t * hsize ..][0..hsize];
        const blob = blobOf(sb, t);
        if (blob) |b| {
            const got = hash(kind, b, &buf);
            if (!std.mem.eql(u8, got, slot))
                return refuse(d, alloc, "signature: {s}: the {s} blob does not match its hash in the CodeDirectory", .{ name, slotName(t) });
        } else if (std.mem.indexOfNone(u8, slot, &.{0}) != null) {
            return refuse(d, alloc, "signature: {s}: the CodeDirectory has a hash for {s}, which the signature does not carry", .{ name, slotName(t) });
        }
    }
}

/// The blob of slot type `t` in the SuperBlob `sb`, its whole bytes; null when
/// the index has none. The index and each blob were bounded by `check`.
fn blobOf(sb: []const u8, t: u32) ?[]const u8 {
    const count = be(sb, 8);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (be(sb, 12 + i * 8) != t) continue;
        const off = be(sb, 16 + i * 8);
        return sb[off .. off + be(sb, off + 4)];
    }
    return null;
}

/// Refuses the Mach-O file `data` (named `name`) unless its code signature is
/// present and matches it. Precondition: macho.read accepted `data`, so its
/// header and load commands lie inside it.
pub fn check(alloc: Alloc, d: *Diag, name: []const u8, data: []const u8) Refused!void {
    const r = signatureRange(data) orelse
        return refuse(d, alloc, "signature: {s} has no code signature (no LC_CODE_SIGNATURE): macOS on arm64 refuses to load unsigned code", .{name});
    if (r.off < 32 or @as(usize, r.off) + r.size > data.len or r.size < 12)
        return refuse(d, alloc, "signature: {s}: the code signature lies outside the file", .{name});
    const sb = data[r.off .. r.off + r.size];
    if (be(sb, 0) != SUPERBLOB_MAGIC) return refuse(d, alloc, "signature: {s}: the code signature is not an embedded-signature SuperBlob", .{name});
    const count = be(sb, 8);
    if (count > (sb.len - 12) / 8) return refuse(d, alloc, "signature: {s}: the SuperBlob's index lies outside it", .{name});
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const off = be(sb, 16 + i * 8);
        if (off < 12 + count * 8 or off > sb.len - 8 or be(sb, off + 4) < 8 or be(sb, off + 4) > sb.len - off)
            return refuse(d, alloc, "signature: {s}: a blob of the SuperBlob lies outside it", .{name});
    }
    var directories: usize = 0;
    i = 0;
    while (i < count) : (i += 1) {
        const t = be(sb, 12 + i * 8);
        if (t != SLOT_CODEDIRECTORY and (t < SLOT_ALTERNATE_FIRST or t > SLOT_ALTERNATE_LAST)) continue;
        const off = be(sb, 16 + i * 8);
        const cd = sb[off..];
        if (be(cd, 0) != CODEDIRECTORY_MAGIC) return refuse(d, alloc, "signature: {s}: the blob of slot {x} is not a CodeDirectory", .{ name, t });
        try checkDirectory(alloc, d, name, data, r.off, sb, cd);
        directories += 1;
    }
    if (directories == 0) return refuse(d, alloc, "signature: {s}: the code signature holds no CodeDirectory", .{name});
    // A blob no special slot names is bound to nothing: each CodeDirectory must hash it.
    i = 0;
    while (i < count) : (i += 1) {
        const t = be(sb, 12 + i * 8);
        if (t == SLOT_CODEDIRECTORY or (t >= SLOT_ALTERNATE_FIRST and t <= SLOT_ALTERNATE_LAST) or t == SLOT_CMS) continue;
        var j: usize = 0;
        while (j < count) : (j += 1) {
            const ct = be(sb, 12 + j * 8);
            if (ct != SLOT_CODEDIRECTORY and (ct < SLOT_ALTERNATE_FIRST or ct > SLOT_ALTERNATE_LAST)) continue;
            if (t > be(sb, be(sb, 16 + j * 8) + 24))
                return refuse(d, alloc, "signature: {s}: the signature carries {s} (slot {d}), which no special slot of a CodeDirectory hashes", .{ name, slotName(t), t });
        }
    }
}
