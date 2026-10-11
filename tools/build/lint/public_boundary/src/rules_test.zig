//! The rules, one row per spelling (rules.zig): each spelling of each rule is
//! found with its text, and each near miss is not. The window is 2030 up to
//! 2031-09-01, so no date here is one the repository's own window refuses.
//!
//! This file is itself read by the lint, so a planted finding is masked: a
//! `~` breaks its shape here (`10.1.2~.3`, `jdoe~@corp.zz`, `http:~//x`,
//! `/ho~me/x`, a split hex run) and `unmask` drops every `~` before the rule
//! reads the row.

const std = @import("std");
const rules = @import("rules.zig");

const W = rules.Window.parse("2030", "2031-09-01").?;

const Row = struct { line: []const u8, want: ?[]const u8 };

fn unmask(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    for (s) |c| {
        if (c == '~') continue;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

fn expectFound(row: Row, got: ?[]const u8) !void {
    var buf: [512]u8 = undefined;
    if (row.want) |want| {
        const w = unmask(&buf, want);
        if (got == null or !std.mem.eql(u8, got.?, w)) {
            std.debug.print("row `{s}`: want `{s}`, got `{?s}`\n", .{ row.line, w, got });
            return error.TestUnexpectedResult;
        }
    } else if (got != null) {
        std.debug.print("row `{s}`: a near miss, found `{s}`\n", .{ row.line, got.? });
        return error.TestUnexpectedResult;
    }
}

const DATES = [_]Row{
    // Each spelling, as the planted lines spell it.
    .{ .line = "Released 2031-08-31.", .want = "2031-08-31" },
    .{ .line = "See notes_2031_08_31.", .want = "2031_08_31" },
    .{ .line = "slash 2031/08/31", .want = "2031/08/31" },
    .{ .line = "dot 2031.08.31", .want = "2031.08.31" },
    .{ .line = "Build 20310831.", .want = "20310831" },
    .{ .line = "Since 2031-08.", .want = "2031-08" },
    .{ .line = "On Aug 31, 2031 it shipped.", .want = "aug 31, 2031" },
    .{ .line = "On 31 August 2031 it shipped.", .want = "31 august 2031" },
    .{ .line = "In August 2030 it began.", .want = "august 2030" },
    .{ .line = "# Feb. 3rd, 2031", .want = "feb. 3rd, 2031" },
    .{ .line = "On 8/31/2031 it shipped.", .want = "8/31/2031" },
    .{ .line = "# 31.08.2030", .want = "31.08.2030" },
    .{ .line = "# 2030-12-01T00:00:00Z", .want = "2030-12-01" },
    .{ .line = "Released 2031-8-31.", .want = "2031-8-31" },
    .{ .line = "Released 31-08-2031.", .want = "31-08-2031" },
    .{ .line = "the first of two: 2031-08-01 and 2030-01-01", .want = "2031-08-01" },
    // At or after the public history.
    .{ .line = "2031-09-01", .want = null },
    .{ .line = "2031-12-31", .want = null },
    .{ .line = "20310901", .want = null },
    .{ .line = "Sep 1, 2031", .want = null },
    .{ .line = "1 Oct 2031", .want = null },
    .{ .line = "September 2031", .want = null },
    .{ .line = "Since 2031-09.", .want = null },
    .{ .line = "9/15/2031", .want = null },
    .{ .line = "15.10.2031", .want = null },
    .{ .line = "15-10-2031", .want = null },
    .{ .line = "2032-01-01", .want = null },
    .{ .line = "2031_09_30", .want = null },
    // A version, and dates before the window.
    .{ .line = "2031.1.5 (a version)", .want = null },
    .{ .line = "2029-12-31", .want = null },
    .{ .line = "20280229", .want = null },
    .{ .line = "Dec 31 2029", .want = null },
    // A year alone, or touching another digit, or a month 13.
    .{ .line = "the 2030 edition", .want = null },
    .{ .line = "build 120310131", .want = null },
    .{ .line = "2031081500", .want = null },
    .{ .line = "2031-13-01", .want = null },
    .{ .line = "id x20310831", .want = null },
};

test "date: each spelling in the window is found, each near miss is not" {
    for (DATES) |row| {
        var buf: [512]u8 = undefined;
        try expectFound(row, rules.findDate(W, std.ascii.lowerString(&buf, row.line)));
    }
}

test "window: a year and a first day of a month, not before it" {
    try std.testing.expect(rules.Window.parse("2030", "2031-09-01") != null);
    try std.testing.expect(rules.Window.parse("2030", "2030-01-01") != null);
    for ([_][2][]const u8{
        .{ "2030", "2031-13-01" },
        .{ "2030", "2031-09-15" },
        .{ "2030", "2031-00-01" },
        .{ "2032", "2031-09-01" },
        .{ "203", "2031-09-01" },
        .{ "2030", "2031-9-01" },
    }) |bad| try std.testing.expect(rules.Window.parse(bad[0], bad[1]) == null);
    // From the first day of `from` up to the day before `public`.
    try std.testing.expect(W.contains(2030, 1));
    try std.testing.expect(W.contains(2031, 8));
    try std.testing.expect(!W.contains(2031, 9));
    try std.testing.expect(!W.contains(2029, 12));
}

const HOMES = [_]Row{
    .{ .line = "Built in /ho~me/jdoe/src.", .want = "/ho~me/jdoe" },
    .{ .line = "Built in /Us~ers/jdoe/Library.", .want = "/Us~ers/jdoe" },
    .{ .line = "Built in C:\\Us~ers\\jdoe\\AppData.", .want = "Us~ers\\jdoe" },
    .{ .line = "var p = \"C:\\\\Us~ers\\\\jdoe\\\\AppData\"", .want = "Us~ers\\\\jdoe" },
    .{ .line = "/ho~me/user/src /ho~me/jdoe/x", .want = "/ho~me/jdoe" },
    // Placeholders, and a prefix with no name.
    .{ .line = "/ho~me/user/src", .want = null },
    .{ .line = "/ho~me/runner/work", .want = null },
    .{ .line = "/Us~ers/me/src", .want = null },
    .{ .line = "C:\\Us~ers\\<name>\\AppData", .want = null },
    .{ .line = "/ho~me/$USER/x", .want = null },
    .{ .line = "/ho~me/ and nothing after it", .want = null },
    .{ .line = "/Us~ers/Shared/x", .want = null },
    // Case matters.
    .{ .line = "/HO~ME/jdoe/x", .want = null },
};

test "home_path: a home directory naming a person is found, a placeholder is not" {
    for (HOMES) |row| {
        var buf: [512]u8 = undefined;
        try expectFound(row, rules.findHome(unmask(&buf, row.line)));
    }
}

const IPS = [_]Row{
    .{ .line = "Reach it at 10.1.2~.3.", .want = "10.1.2~.3" },
    .{ .line = "172.20.0~.5 private", .want = "172.20.0~.5" },
    // The edges of 172.16/12: 172.16 and 172.31 are in it, 172.15 and 172.32 are not.
    .{ .line = "172.16.0~.1 private, the first /16", .want = "172.16.0~.1" },
    .{ .line = "172.31.255~.254 private, the last /16", .want = "172.31.255~.254" },
    .{ .line = "172.15.255.254 public, below the range", .want = null },
    .{ .line = "172.32.0.1 public, above the range", .want = null },
    .{ .line = "192.168.10~.1 private", .want = "192.168.10~.1" },
    .{ .line = "Reach it at 100.100.1~.2.", .want = "100.100.1~.2" },
    .{ .line = "Reach it at 169.254.1~.1.", .want = "169.254.1~.1" },
    .{ .line = "Resolve with 8.8.4~.4:53.", .want = "8.8.4~.4" },
    .{ .line = "grpc:~//9.9.9~.9 public, after a scheme", .want = "9.9.9~.9" },
    .{ .line = "admin~@11.12.13~.14 public, after an at sign", .want = "11.12.13~.14" },
    // Loopback, unspecified, documentation and published metadata addresses.
    .{ .line = "127.0.0.1:8080", .want = null },
    .{ .line = "0.0.0.0:80", .want = null },
    .{ .line = "192.0.2.10:443", .want = null },
    .{ .line = "198.51.100.7", .want = null },
    .{ .line = "203.0.113.9:22", .want = null },
    .{ .line = "169.254.169.254 and 169.254.170.2", .want = null },
    .{ .line = "255.255.255.255", .want = null },
    // OIDs, section numbers, versions and public ranges as text.
    .{ .line = "the OID 2.5.4.3", .want = null },
    .{ .line = "section 8.1.2.6", .want = null },
    .{ .line = "version 1.2.3.4.5", .want = null },
    .{ .line = "the range 35.191.0.0/16", .want = null },
    .{ .line = "v10.1.2.3 is a tag", .want = null },
    .{ .line = "300.1.2.3:80", .want = null },
};

test "ip: a private, shared or link-local address, or one written as an address, is found" {
    for (IPS) |row| {
        var buf: [512]u8 = undefined;
        try expectFound(row, rules.findIp(unmask(&buf, row.line)));
    }
}

const HOSTS = [_]Row{
    .{ .line = "Build on http:~//builder:8980/.", .want = "builder" },
    .{ .line = "See https:~//build.corp.zz/x.", .want = "build.corp.zz" },
    .{ .line = "See http:~//svc.corp.internal/.", .want = "svc.corp.internal" },
    .{ .line = "See http:~//[2001:db8::1]:80/.", .want = "[2001:db8::1]" },
    .{ .line = "https:~//u:p~@deploy.corp.zz:8443/ userinfo and a port", .want = "deploy.corp.zz" },
    .{ .line = "HTTPS:~//UPPER.CORP.ZZ/ capitals", .want = "upper.corp.zz" },
    .{ .line = "postgres:~//db.corp.zz:5432/x another scheme", .want = "db.corp.zz" },
    .{ .line = "git+ssh:~//build.corp.zz/r", .want = null },
    .{ .line = "see (https:~//build.corp.zz).", .want = "build.corp.zz" },
    // Reserved names, ledger domains, templates, patterns, object stores.
    .{ .line = "https://example.com/x https://api.example/x http://localhost:9000", .want = null },
    .{ .line = "https://bucket.localhost/k https://svc.test https://x.invalid/p", .want = null },
    .{ .line = "https://www.example.org https://u:p@example.com:8443/x", .want = null },
    .{ .line = "https:~//s3.us-west-2.amazonaws.com/b", .want = null },
    .{ .line = "http://[::1]:8080/ http://[fd00:ec2::254]/token", .want = null },
    .{ .line = "https://{host}/x https://$HOST/p https://<host>/p", .want = null },
    .{ .line = "s3:~//bucket/key gs:~//b/o file:///home/user/x", .want = null },
    .{ .line = "https://\xe2\x80\xa6 and the pattern https://[^\"]+", .want = null },
    .{ .line = "http:~//169.254.169.254/latest", .want = null },
};

const DOMAINS = [_][]const u8{ "amazonaws.com", "github.com", "windows.net" };

test "host: a URL host neither reserved nor under a ledger domain is found" {
    var used = [_]bool{false} ** DOMAINS.len;
    const hosts = rules.Hosts{ .domains = &DOMAINS, .used = &used };
    for (HOSTS) |row| {
        var buf: [512]u8 = undefined;
        var lbuf: [512]u8 = undefined;
        const line = unmask(&buf, row.line);
        try expectFound(row, rules.findHost(line, std.ascii.lowerString(&lbuf, line), hosts));
    }
    // Only a host under amazonaws.com was read.
    try std.testing.expectEqual([_]bool{ true, false, false }, used);
}

const EMAILS = [_]Row{
    .{ .line = "Ask jdoe~@corp.zz.", .want = "jdoe~@corp.zz" },
    .{ .line = "Write to mailto:jdoe~@corp.zz.", .want = "jdoe~@corp.zz" },
    .{ .line = "See s3:~//bucket/jdoe~@corp.zz.", .want = "jdoe~@corp.zz" },
    .{ .line = "The lake abfss:~//lake~@acct.dfs.core.windows.net/p is owned by jdoe~@corp.zz.", .want = "jdoe~@corp.zz" },
    .{ .line = "The bucket s3:~//jdoe~@corp.zz/k has a user before a host no row names.", .want = "jdoe~@corp.zz" },
    .{ .line = "Clone git+ssh:~//jdoe~@corp.zz/r to build.", .want = "jdoe~@corp.zz" },
    .{ .line = "# Jane.Doe+tag~@mail.corp.zz", .want = "Jane.Doe+tag~@mail.corp.zz" },
    .{ .line = "https:~//u:p~@deploy.corp.zz:8443/", .want = "p~@deploy.corp.zz" },
    .{ .line = "x~@y.co.uk9", .want = "x~@y.co.uk" },
    .{ .line = "a@b@c~@corp.zz", .want = "c~@corp.zz" },
    // Trailers, reserved domains, decorators, a URL's user on a ledger domain.
    .{ .line = "noreply~@tools.zz, no-reply~@tools.zz", .want = null },
    .{ .line = "alice~@example.com, ops~@team.example, x~@y.test, user~@host.invalid", .want = null },
    .{ .line = "a decorator @always_inline.", .want = null },
    .{ .line = "abfss:~//lake~@acct.dfs.core.windows.net/p", .want = null },
    .{ .line = "az:~//lake~@acct.blob.core.windows.net/p", .want = null },
    .{ .line = "x~@y.c", .want = null },
};

test "email: an address outside the reserved domains is found" {
    var used = [_]bool{false} ** DOMAINS.len;
    const hosts = rules.Hosts{ .domains = &DOMAINS, .used = &used };
    for (EMAILS) |row| {
        var buf: [512]u8 = undefined;
        var lbuf: [512]u8 = undefined;
        const line = unmask(&buf, row.line);
        try expectFound(row, rules.findEmail(line, std.ascii.lowerString(&lbuf, line), hosts));
    }
    // A URL's user on a ledger domain marks the domain used.
    try std.testing.expectEqual([_]bool{ false, false, true }, used);
}

/// A file's lines and the commit id each one's prose holds.
const ShaFile = struct { path: []const u8, lines: []const []const u8, want: []const ?[]const u8 };

const SHAS = [_]ShaFile{
    .{ .path = "docs/plant.md", .lines = &.{"Fixed in 1a2b3c~4d."}, .want = &.{"1a2b3c~4d"} },
    .{ .path = "a/plant.mojo", .lines = &.{"x = 1  # fixed in 9f8e7d~6c5b"}, .want = &.{"9f8e7d~6c5b"} },
    .{ .path = "a/plant.mojo", .lines = &.{ "\"\"\"Doc.", "", "Fixed in 9f8e7d~6c5b.", "\"\"\"", "y = 9f8e7d~6c5b" }, .want = &.{ null, null, "9f8e7d~6c5b", null, null } },
    .{ .path = "a/held.mojo", .lines = &.{"\"\"\"Held: fixed in 1a2b3c~4."}, .want = &.{"1a2b3c~4"} },
    .{ .path = "a/held.mojo", .lines = &.{"# 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a~0b"}, .want = &.{"1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a~0b"} },
    .{ .path = "a/plant.c", .lines = &.{"int z; // fixed in 9f8e7d~6c5b"}, .want = &.{"9f8e7d~6c5b"} },
    .{ .path = "a/plant.c", .lines = &.{"const char *s = \"a//b\"; // fixed in 9f8e7d~6c5b"}, .want = &.{"9f8e7d~6c5b"} },
    .{ .path = "a/shim.c", .lines = &.{ "/* a block comment", " * 9f8e7d~6c5b on a line of it", " */" }, .want = &.{ null, "9f8e7d~6c5b", null } },
    .{ .path = "third_party/up/BUCK", .lines = &.{"# Built from 4e5f6a~7b8c."}, .want = &.{"4e5f6a~7b8c"} },
    // Digests, literals, UUIDs, quoted, run-in and over-long hex in prose.
    .{ .path = "docs/near.md", .lines = &.{
        "ba7816bf... and cf83e13~5\xe2\x80\xa6, 0b00001101, 86400e9, ed25519",
        "0190ab1c-3d4e-7f80-8a1b-2c3d4e5f6071, \"1a2b3c~4d\", deadbeef, x1a2b3c~4d",
        "1a2b3c4d5e6f7a8b9c, /commit/1a2b3c~4d5e, checkout@1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a~0b",
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b~855.",
    }, .want = &.{ null, null, null, null } },
    // Code is not prose.
    .{ .path = "a/near.mojo", .lines = &.{
        "comptime PIN = pin_of(9f8e7d~6c5b)",
        "var s = \"a # 9f8e7d~6c5b\"",
        "var t = \"b\" + \"c # 1a2b3c~4d5e\"",
        "    return h(1a2b3c~4d5e)  # a trailing comment with none",
    }, .want = &.{ null, null, null, null } },
    .{ .path = "a/near.c", .lines = &.{
        "static const char *pin = PIN(9f8e7d~6c5b);",
        "int x = 0x1a2b3c~4d; // hex literal after 0x",
        "const char *v = \"a // 1a2b3c~4d5e\"; /* a // in a string is no comment */",
    }, .want = &.{ null, null, null } },
    .{ .path = "a/data.json", .lines = &.{"// 9f8e7d~6c5b"}, .want = &.{null} },
};

test "commit_sha: a commit id in prose is found; code, digests and literals are not" {
    for (SHAS) |f| {
        var prose = rules.Prose.init(std.testing.allocator, f.path);
        defer prose.deinit();
        for (f.lines, f.want) |line, want| {
            var buf: [512]u8 = undefined;
            const l = unmask(&buf, line);
            try expectFound(.{ .line = line, .want = want }, rules.findSha(try prose.line(l)));
        }
    }
}

test "kind: the prose of each file kind" {
    const K = rules.Kind;
    for ([_]struct { []const u8, K }{
        .{ "docs/a.md", .text },
        .{ "a/notes.txt", .text },
        .{ "third_party/up/BUCK", .hash },
        .{ "Makefile", .hash },
        .{ ".buckconfig", .hash },
        .{ "tools/build/tests/.buckconfig.local", .hash },
        .{ "a/x.mojo", .hash },
        .{ "a/x.tsv", .hash },
        .{ "a/x.zig", .slash },
        .{ "a/x.S", .slash },
        .{ "a/x.h", .slash },
        .{ "a/x.json", .none },
        .{ ".clang-format", .none },
        .{ "a/LICENSE", .none },
    }) |row| {
        if (rules.kindOf(row[0]) != row[1]) {
            std.debug.print("{s}: want {s}, got {s}\n", .{ row[0], @tagName(row[1]), @tagName(rules.kindOf(row[0])) });
            return error.TestUnexpectedResult;
        }
    }
}
