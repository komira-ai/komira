//! host_identity: the identity of a macOS execution host, as listed in
//! `[komira_re] darwin_macos_hosts` (tools/build/platforms/defs.bzl).
//! mojo_compile_macos.zig collects the fields (running each tool below by
//! its absolute path) and refuses a compile on a host whose identity is not
//! listed; `mojo_compile host-identity [--fields]` prints it, for the person
//! filling the list.
//!
//! A compile on macOS uses more of the host than its inputs name: the C
//! driver and the linker it runs, the SDK, and the operating system whose
//! libraries a gated test loads. Two hosts can print the same SDK version and
//! still differ in each of those (Xcode.app against the Command Line Tools,
//! an SDK respin at the same version, another clang or ld build, another OS
//! build), so the identity carries a digest of all of them:
//!
//!   developer_dir  xcode-select -p: Xcode.app or the Command Line Tools
//!   sdk_version    xcrun --show-sdk-version
//!   sdk_build      xcrun --show-sdk-build-version
//!   cc             cc --version, first line (the clang build)
//!   ld             ld -v with its stderr, first line (the linker build)
//!   os_build       sw_vers -buildVersion
//!
//! The identity is the SDK version (so a person can tell queues apart), a
//! dash, and the first 16 hex digits of the md5 of the six `name=value`
//! lines, each ended by a newline. These are the bytes the retired
//! host_identity.sh printed for the same tool output, so every configured
//! value stays valid.

const std = @import("std");

pub const Field = struct {
    name: []const u8,
    argv: []const []const u8,
    /// Only the first line of the output counts (else: all of it, without
    /// its trailing newlines, as a shell's command substitution reads it).
    first_line: bool = false,
    /// The tool's stderr is read with its stdout.
    with_stderr: bool = false,
};

pub const fields = [_]Field{
    .{ .name = "developer_dir", .argv = &.{ "/usr/bin/xcode-select", "-p" } },
    .{ .name = "sdk_version", .argv = &.{ "/usr/bin/xcrun", "--show-sdk-version" } },
    .{ .name = "sdk_build", .argv = &.{ "/usr/bin/xcrun", "--show-sdk-build-version" } },
    .{ .name = "cc", .argv = &.{ "/usr/bin/cc", "--version" }, .first_line = true },
    .{ .name = "ld", .argv = &.{ "/usr/bin/ld", "-v" }, .first_line = true, .with_stderr = true },
    .{ .name = "os_build", .argv = &.{ "/usr/bin/sw_vers", "-buildVersion" } },
};

/// The field's value from the tool's output.
pub fn fieldValue(f: Field, output: []const u8) []const u8 {
    const v = if (f.first_line)
        (if (std.mem.indexOfScalar(u8, output, '\n')) |n| output[0..n] else output)
    else
        output;
    return std.mem.trimRight(u8, v, "\n");
}

/// The index of the first empty value (a field that could not be read), or
/// null.
pub fn firstEmpty(values: []const []const u8) ?usize {
    for (values, 0..) |v, i| if (v.len == 0) return i;
    return null;
}

/// The `name=value` lines the digest covers, each ended by a newline.
pub fn text(alloc: std.mem.Allocator, values: [fields.len][]const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    for (fields, values) |f, v| {
        try out.appendSlice(alloc, f.name);
        try out.append(alloc, '=');
        try out.appendSlice(alloc, v);
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

/// `<sdk version>-<first 16 hex digits of md5(text)>`.
pub fn identity(alloc: std.mem.Allocator, values: [fields.len][]const u8) ![]u8 {
    const t = try text(alloc, values);
    var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash(t, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(alloc, "{s}-{s}", .{ values[1], hex[0..16] });
}

// ---- tests -------------------------------------------------------------------

const testing = std.testing;

// The tool output of functional/darwin/check.sh's stand-ins for the six
// tools, as the tools print it.
const sample_outputs = [fields.len][]const u8{
    "/Library/Developer/CommandLineTools\n",
    "26.5\n",
    "25F71\n",
    "Apple clang version 17.0.0 (clang-1700.3.19.1)\nTarget: arm64-apple-darwin25.5.0\n",
    "@(#)PROGRAM:ld PROJECT:ld-1167.5\nBUILD 08:00:00\n",
    "25F80\n",
};

fn sampleValues() [fields.len][]const u8 {
    var v: [fields.len][]const u8 = undefined;
    for (fields, sample_outputs, 0..) |f, o, i| v[i] = fieldValue(f, o);
    return v;
}

// Catches: a value that differs from what the retired host_identity.sh
// printed for the same tool output (every configured darwin_macos_hosts
// entry would go stale and every macOS compile refuse its host). The golden
// is `printf '%s\n' <the six lines> | md5sum`, cut to 16 digits. Mutant
// planted: md5 over the lines without the final newline.
test "host identity: the value the shell gave for six fixed field lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = sampleValues();
    try testing.expectEqualStrings(
        "developer_dir=/Library/Developer/CommandLineTools\nsdk_version=26.5\nsdk_build=25F71\n" ++
            "cc=Apple clang version 17.0.0 (clang-1700.3.19.1)\nld=@(#)PROGRAM:ld PROJECT:ld-1167.5\nos_build=25F80\n",
        try text(arena.allocator(), v),
    );
    try testing.expectEqualStrings("26.5-19f5e42a4fed6962", try identity(arena.allocator(), v));
}

// Catches: a field left out of the digest (two hosts that differ only there
// would share an identity). Mutant planted: skip os_build in `text`.
test "host identity: every field changes the value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const base = try identity(arena.allocator(), sampleValues());
    for (0..fields.len) |i| {
        var v = sampleValues();
        v[i] = "other-build-99";
        const got = try identity(arena.allocator(), v);
        if (std.mem.eql(u8, got, base)) {
            std.debug.print("field {s} does not change the identity\n", .{fields[i].name});
            return error.TestUnexpectedResult;
        }
    }
}

test "host identity: first line, trailing newlines, an empty field" {
    try testing.expectEqualStrings("a", fieldValue(fields[3], "a\nb\n"));
    try testing.expectEqualStrings("", fieldValue(fields[3], "\nb\n"));
    try testing.expectEqualStrings("x\ny", fieldValue(fields[0], "x\ny\n\n"));
    try testing.expectEqualStrings("", fieldValue(fields[5], ""));
    const v = [_][]const u8{ "a", "b", "", "d" };
    try testing.expectEqual(@as(?usize, 2), firstEmpty(&v));
    try testing.expectEqual(@as(?usize, null), firstEmpty(&.{ "a", "b" }));
}
