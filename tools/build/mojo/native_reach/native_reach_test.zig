//! native_reach's cases (native_reach.zig). Each names the defect it catches.

const std = @import("std");
const N = @import("native_reach.zig");

const t = std.testing;
const awslc = N.Refuse{ .prefix = "komira_awslc_", .owner = "komira//src/komira_crypto:komira_crypto" };
const s2n = N.Refuse{ .prefix = "komira_s2n_", .owner = "komira//src/komira_http_core:komira_http_core" };

fn found(text: []const u8, refuses: []const N.Refuse) ![]const N.Finding {
    var out = std.ArrayList(N.Finding).init(t.allocator);
    errdefer out.deinit();
    try N.scan("f.mojo", text, refuses, &out);
    return out.toOwnedSlice();
}

// The case the check exists for: komira_uuid's entropy.mojo spelling.
test "scan: finds the name an external_call spells, with its line" {
    const f = try found("    var rc = external_call[\n        \"komira_awslc_RAND_bytes\",\n        c_int,\n", &.{awslc});
    defer t.allocator.free(f);
    try t.expectEqual(@as(usize, 1), f.len);
    try t.expectEqual(@as(usize, 2), f[0].line);
    try t.expectEqualStrings("komira_awslc_RAND_bytes", f[0].symbol);
    try t.expectEqualStrings(awslc.owner, f[0].refuse.owner);
}

// A name in a comment is prose: a whole-line comment and a trailing one.
test "scan: skips comments, whole-line and trailing" {
    const f = try found("# calls \"komira_awslc_SHA256\"\nx = 1  # \"komira_awslc_SHA256\"\n", &.{awslc});
    defer t.allocator.free(f);
    try t.expectEqual(@as(usize, 0), f.len);
}

// A `#` inside a string is not a comment: a scanner cutting the line at the
// first `#` would miss the second string.
test "scan: a # inside a string does not end the line" {
    const f = try found("f(\"a#b\", \"komira_awslc_SHA256\")\n", &.{awslc});
    defer t.allocator.free(f);
    try t.expectEqual(@as(usize, 1), f.len);
}

// An escaped quote does not close a string: without escape handling the
// quote after `\"` would be read as opening, and the name after it missed.
test "scan: a backslash-escaped quote stays inside the string" {
    const f = try found("f(\"a\\\"\", \"komira_awslc_SHA256\")\n", &.{awslc});
    defer t.allocator.free(f);
    try t.expectEqual(@as(usize, 1), f.len);
    try t.expectEqualStrings("komira_awslc_SHA256", f[0].symbol);
}

// A name that does not open a string (an identifier, or text later in a
// string) is no C name.
test "scan: only a string that starts with the prefix counts" {
    const f = try found("var komira_awslc_x = 1\ns = \"see komira_awslc_x\"\n", &.{awslc});
    defer t.allocator.free(f);
    try t.expectEqual(@as(usize, 0), f.len);
}

test "scan: single-quoted strings count, and the name ends at the first non-identifier byte" {
    const f = try found("g('komira_s2n_init', x)\n", &.{s2n});
    defer t.allocator.free(f);
    try t.expectEqual(@as(usize, 1), f.len);
    try t.expectEqualStrings("komira_s2n_init", f[0].symbol);
}

// Only the refused prefixes: an owner in the closure passes no --refuse.
test "scan: a prefix not refused is not reported" {
    const f = try found("a(\"komira_awslc_SHA256\")\nb(\"komira_s2n_init\")\n", &.{s2n});
    defer t.allocator.free(f);
    try t.expectEqual(@as(usize, 1), f.len);
    try t.expectEqualStrings("komira_s2n_init", f[0].symbol);
    try t.expectEqual(@as(usize, 2), f[0].line);
}

test "scan: two names on one line are both reported" {
    const f = try found("x(\"komira_awslc_A\", \"komira_s2n_B\")\n", &.{ awslc, s2n });
    defer t.allocator.free(f);
    try t.expectEqual(@as(usize, 2), f.len);
}

fn status(json: []const u8) ![]const u8 {
    const p = try std.json.parseFromSlice(std.json.Value, t.allocator, json, .{});
    defer p.deinit();
    const v = p.value.object.get("version").?.integer;
    try t.expectEqual(@as(i64, 1), v);
    const s = p.value.object.get("data").?.object.get("status").?.string;
    return if (std.mem.eql(u8, s, "failure")) "failure" else if (std.mem.eql(u8, s, "success")) "success" else "other";
}

// The result Buck2 reads: a finding is a failure naming file, line, name and
// owner; none is a success.
test "result: failure names each finding, success when there is none" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fs = [_]N.Finding{.{ .path = "entropy.mojo", .line = 44, .symbol = "komira_awslc_RAND_bytes", .refuse = awslc }};
    const bad = try N.message(a, "komira//src/komira_uuid:komira_uuid", 3, &.{awslc}, &fs);
    try t.expect(std.mem.indexOf(u8, bad, "entropy.mojo:44: \"komira_awslc_RAND_bytes\" is komira//src/komira_crypto:komira_crypto's") != null);
    try t.expectEqualStrings("failure", try status(try N.result(a, true, bad)));
    const good = try N.message(a, "komira//src/komira_uuid:komira_uuid", 3, &.{awslc}, &.{});
    try t.expect(std.mem.indexOf(u8, good, "3 source file(s) checked") != null);
    try t.expectEqualStrings("success", try status(try N.result(a, false, good)));
}

test "parseArgs: refuses a missing flag, a malformed --refuse and no --refuse" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    try t.expect((try N.parseArgs(a, &.{ "--out", "o", "--library", "l", "--refuse", "p=o" }, &why)) == null);
    try t.expect((try N.parseArgs(a, &.{ "--out", "o", "--library", "l", "--src", "s", "--refuse", "p" }, &why)) == null);
    try t.expect((try N.parseArgs(a, &.{ "--out", "o", "--library", "l", "--src", "s", "--refuse", "=o" }, &why)) == null);
    try t.expect((try N.parseArgs(a, &.{ "--out", "o", "--library", "l", "--src", "s" }, &why)) == null);
    try t.expect((try N.parseArgs(a, &.{ "--out", "o", "--library" }, &why)) == null);
    const ok = (try N.parseArgs(a, &.{ "--out", "o", "--library", "l", "--src", "s", "--refuse", "komira_awslc_=c", "--refuse", "komira_s2n_=h" }, &why)).?;
    try t.expectEqual(@as(usize, 2), ok.refuses.len);
    try t.expectEqualStrings("komira_s2n_", ok.refuses[1].prefix);
    try t.expectEqualStrings("h", ok.refuses[1].owner);
}

// Every `.mojo` file at any depth, and nothing else; a check reading only the
// top level would miss `internal/asm/*_ffi.mojo`.
test "run: reads nested .mojo files only, in sorted order, and writes the result" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("pkg/internal/asm");
    try tmp.dir.writeFile("pkg/__init__.mojo", "from .x import y\n");
    try tmp.dir.writeFile("pkg/internal/asm/rng_ffi.mojo", "external_call[\"komira_awslc_RAND_bytes\", c_int]()\n");
    try tmp.dir.writeFile("pkg/notes.txt", "\"komira_awslc_SHA256\"\n");
    var src = try tmp.dir.openDir("pkg", .{ .iterate = true });
    defer src.close();
    const files = try N.mojoFiles(a, src);
    try t.expectEqual(@as(usize, 2), files.len);
    try t.expectEqualStrings("__init__.mojo", files[0]);

    const src_path = try tmp.dir.realpathAlloc(a, "pkg");
    const out_path = try std.fs.path.join(a, &.{ try tmp.dir.realpathAlloc(a, "."), "out.json" });
    try N.run(a, .{ .out = out_path, .library = "L", .src = src_path, .refuses = &.{awslc} });
    const out = try std.fs.cwd().readFileAlloc(a, out_path, 1 << 20);
    try t.expectEqualStrings("failure", try status(out));
    try t.expect(std.mem.indexOf(u8, out, "internal/asm/rng_ffi.mojo:1:") != null);
    try t.expect(std.mem.indexOf(u8, out, "notes.txt") == null);
}
