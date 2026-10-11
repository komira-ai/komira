//! The guard: what must hold before a scenario drives buck2.
//!
//!   - no `--nested`: the recursion guard's select gives it to a scenario
//!     run by an inner command (defs.bzl); refusing it stops the recursion;
//!   - a Linux x86_64 client: scenarios run the pinned linux buck2 and read
//!     linux-x86_64 answers;
//!   - every execution platform the inner daemon registers is remote (or,
//!     for the one scenario stating `expect = "local"`, every one local):
//!     read from `buck2 audit config` and `buck2 audit providers`, so a
//!     `-c`, a user buckconfig and `.buckconfig.local` all count.
//!
//! A refusal is a failure, never a skip.
const std = @import("std");
const args = @import("args.zig");
const parse = @import("parse.zig");

pub fn clientRefusal(sysname: []const u8, machine: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, sysname, "Linux") and std.mem.eql(u8, machine, "x86_64")) return null;
    return "the scenarios need a Linux x86_64 client: they run the pinned linux-x86_64 buck2 and check linux-x86_64 answers";
}

pub fn nestedRefusal(nested: bool) ?[]const u8 {
    if (!nested) return null;
    return "--nested: this scenario was run by an inner command of a scenario (-c komira_selftest.inner=true), so its incompatibility under that key did not keep it out (the recursion guard, tools/build/selftest/defs.bzl); refusing to drive buck2 a level deeper";
}

/// Why the registered execution platforms do not match `expect`, or null.
pub fn platformsRefusal(e: parse.Executors, expect: args.Expect) ?[]const u8 {
    if (e.platforms == 0) return "the inner daemon registers no execution platform";
    if (e.local + e.remote != e.platforms) return "an execution platform's executor is neither Local nor Remote";
    switch (expect) {
        .remote => if (e.local != 0) return "an execution platform of the inner daemon is local: every inner build must run on the farm (configure the farm: .buckconfig.local, or the farm-connect buckconfig in CI)",
        .local => if (e.remote != 0) return "an execution platform of the inner daemon is remote, and this scenario expects only local ones",
    }
    return null;
}

/// The linux-x86_64 digest `tools/buck2` pins (its `"linux-x86_64": {`
/// block's `"digest"`), or null.
pub fn pinnedDigest(pin: []const u8) ?[]const u8 {
    const block = std.mem.indexOf(u8, pin, "\"linux-x86_64\": {") orelse return null;
    const end = std.mem.indexOfPos(u8, pin, block, "}") orelse return null;
    const key = "\"digest\": \"";
    const at = std.mem.indexOfPos(u8, pin[0..end], block, key) orelse return null;
    const v = at + key.len;
    const q = std.mem.indexOfScalarPos(u8, pin, v, '"') orelse return null;
    const d = pin[v..q];
    if (d.len != 64) return null;
    for (d) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return null;
    return d;
}

/// The lower-case hex sha256 of `bytes`.
pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}
