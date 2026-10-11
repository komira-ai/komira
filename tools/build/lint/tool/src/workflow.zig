//! The lint kinds over GitHub workflow files and committed configuration,
//! which read text only: action_pins, push_verdicts, no_endpoint.

const std = @import("std");
const lint = @import("lint.zig");
const Ctx = lint.Ctx;

/// The end of a `uses:` key at the start of `line` (`^[[:space:]]*(-[[:space:]]+)?uses:`),
/// or null when the line is not one.
fn usesKey(line: []const u8) ?usize {
    var i = lint.skipSpace(line, 0);
    if (i < line.len and line[i] == '-') {
        const j = lint.skipSpace(line, i + 1);
        if (j == i + 1) return null;
        i = j;
    }
    if (!std.mem.startsWith(u8, line[i..], "uses:")) return null;
    return i + "uses:".len;
}

/// Whether the text after a `uses:` names a full commit SHA or a local action:
/// `[[:space:]]*([^@[:space:]]+@[0-9a-f]{40}([[:space:]]|$)|\./)`.
fn pinned(after: []const u8) bool {
    const s = after[lint.skipSpace(after, 0)..];
    if (std.mem.startsWith(u8, s, "./")) return true;
    var i: usize = 0;
    while (i < s.len and s[i] != '@' and !lint.isSpace(s[i])) i += 1;
    if (i == 0 or i >= s.len or s[i] != '@') return false;
    const sha = s[i + 1 ..];
    if (sha.len < 40) return false;
    for (sha[0..40]) |b| if (!std.ascii.isDigit(b) and !(b >= 'a' and b <= 'f')) return false;
    return sha.len == 40 or lint.isSpace(sha[40]);
}

/// kind action_pins, args <workflow>...: every `uses:` names an action by a
/// full 40-hex commit SHA, not a tag. A local action (`uses: ./path`) is part
/// of this checkout, so it has no SHA to pin; its own file is among the
/// <workflow>s, which pins what it uses.
pub fn actionPins(c: *Ctx, args: []const []const u8) !void {
    for (args) |f| {
        const text = try lint.readFile(c.alloc, f);
        var lines = lint.Lines.init(text);
        while (lines.next()) |line| {
            if (usesKey(line) == null) continue;
            c.checked += 1;
            // Any `uses:` of the line that is pinned passes it, as grep reads it.
            var ok = false;
            var from: usize = 0;
            while (std.mem.indexOfPos(u8, line, from, "uses:")) |at| : (from = at + 1) {
                if (pinned(line[at + "uses:".len ..])) ok = true;
            }
            if (!ok) try c.finding("{s}:{d}:{s} -- not pinned to a full commit SHA", .{ f, lines.n, line });
        }
    }
}

/// Whether `rest` names the word `push` (`(^|[^a-z_])push([^a-z_]|$)`).
fn namesPush(rest: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, rest, from, "push")) |at| : (from = at + 1) {
        const before = at == 0 or !(std.ascii.isLower(rest[at - 1]) or rest[at - 1] == '_');
        const end = at + 4;
        const after = end == rest.len or !(std.ascii.isLower(rest[end]) or rest[end] == '_');
        if (before and after) return true;
    }
    return false;
}

/// Whether an indented line is `push` (`^[[:space:]]+(-[[:space:]]+)?push[[:space:]]*(:|$)`).
fn pushLine(line: []const u8) bool {
    var i = lint.skipSpace(line, 0);
    if (i == 0) return false;
    if (i < line.len and line[i] == '-') {
        const j = lint.skipSpace(line, i + 1);
        if (j == i + 1) return false;
        i = j;
    }
    if (!std.mem.startsWith(u8, line[i..], "push")) return false;
    i = lint.skipSpace(line, i + 4);
    return i == line.len or line[i] == ':';
}

/// Whether an indented line is the `group:` key (`^[[:space:]]+group[[:space:]]*:`).
fn groupLine(line: []const u8) bool {
    const i = lint.skipSpace(line, 0);
    if (i == 0 or !std.mem.startsWith(u8, line[i..], "group")) return false;
    const j = lint.skipSpace(line, i + 5);
    return j < line.len and line[j] == ':';
}

/// kind push_verdicts, args <workflow>...: a push-triggered workflow with a
/// top-level `concurrency` group names github.sha in it (read as text):
/// GitHub keeps one pending run per group and cancels it for a newer one, so
/// a group shared by pushes loses the middle push's run. Checks nothing, so
/// fails, when no workflow is push-triggered.
pub fn pushVerdicts(c: *Ctx, args: []const []const u8) !void {
    for (args) |f| {
        const text = try lint.readFile(c.alloc, f);
        var push = false;
        var conc = false;
        var group: []const u8 = "";
        var gline: usize = 0;
        var blk: []const u8 = "";
        var lines = lint.Lines.init(text);
        while (lines.next()) |line| {
            if (line.len > 0 and !lint.isSpace(line[0]) and line[0] != '#') {
                // A top-level key: its name (quotes dropped) and what follows its colon.
                var top: []const u8 = line;
                var rest: []const u8 = line;
                if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                    var e = colon;
                    while (e > 0 and lint.isSpace(line[e - 1])) e -= 1;
                    top = line[0..e];
                    rest = line[lint.skipSpace(line, colon + 1)..];
                }
                const name = try std.mem.replaceOwned(u8, c.alloc, top, "\"", "");
                blk = name;
                if (std.mem.eql(u8, name, "on") and namesPush(rest)) push = true;
                if (std.mem.eql(u8, name, "concurrency") and rest.len > 0 and rest[0] != '#') {
                    group = rest;
                    gline = lines.n;
                    conc = true;
                }
                continue;
            }
            if (std.mem.eql(u8, blk, "on") and pushLine(line)) push = true;
            if (std.mem.eql(u8, blk, "concurrency") and groupLine(line)) {
                group = line;
                gline = lines.n;
                conc = true;
            }
        }
        if (!push) continue;
        c.checked += 1;
        if (conc and std.mem.indexOf(u8, group, "github.sha") == null)
            try c.finding("{s}:{d}: the concurrency group of a push-triggered workflow does not name github.sha, so a push can lose its run to a newer one", .{ f, gline });
    }
}

const endpoint_keys = [_][]const u8{ "engine_address", "action_cache_address", "cas_address", "address", "instance_name", "tls_ca_certs", "http_headers" };

/// Whether a buckconfig line sets an endpoint or instance key.
fn endpointKey(line: []const u8) bool {
    const i = lint.skipSpace(line, 0);
    for (endpoint_keys) |k| {
        if (!std.mem.startsWith(u8, line[i..], k)) continue;
        const j = lint.skipSpace(line, i + k.len);
        if (j < line.len and line[j] == '=') return true;
    }
    return false;
}

/// Whether the host part of a grpc address (after `://`) is under an
/// example.* domain: `[^:]*example\.[a-z]+(:[0-9]+)?$`.
fn exampleHost(h: []const u8) bool {
    var host = h;
    if (std.mem.indexOfScalar(u8, h, ':')) |colon| {
        const port = h[colon + 1 ..];
        if (port.len == 0) return false;
        for (port) |b| if (!std.ascii.isDigit(b)) return false;
        host = h[0..colon];
    }
    const at = std.mem.lastIndexOf(u8, host, "example.") orelse return false;
    const tld = host[at + "example.".len ..];
    if (tld.len == 0) return false;
    for (tld) |b| if (!std.ascii.isLower(b)) return false;
    return true;
}

fn addressByte(b: u8) bool {
    return !lint.isSpace(b) and b != '"' and b != '\'' and b != '/';
}

/// kind no_endpoint, args <.gitignore> <n> <buckconfig>*n <file>...: no
/// committed buckconfig sets a remote-execution endpoint or instance key,
/// .gitignore ignores /.buckconfig.local, and no buckconfig or <file> names a
/// grpc:// or grpcs:// address outside the example.* domains.
pub fn noEndpoint(c: *Ctx, args: []const []const u8) !void {
    if (args.len < 2) return error.Usage;
    const gitignore = args[0];
    const n = std.fmt.parseInt(usize, args[1], 10) catch return error.Usage;
    const files = args[2..];
    c.checked = files.len;
    for (files[0..@min(n, files.len)]) |f| {
        const text = try lint.readFile(c.alloc, f);
        var lines = lint.Lines.init(text);
        while (lines.next()) |line| {
            if (endpointKey(line))
                try c.finding("{s}:{d}:{s} -- an endpoint belongs in .buckconfig.local or the machine's buckconfig", .{ f, lines.n, line });
        }
    }
    {
        const text = try lint.readFile(c.alloc, gitignore);
        var ignored = false;
        var lines = lint.Lines.init(text);
        while (lines.next()) |line| {
            if (std.mem.eql(u8, line, "/.buckconfig.local")) ignored = true;
        }
        if (!ignored) try c.finding("{s}: does not ignore /.buckconfig.local", .{gitignore});
    }
    for (files) |f| {
        const text = try lint.readFile(c.alloc, f);
        var lines = lint.Lines.init(text);
        while (lines.next()) |line| {
            var from: usize = 0;
            while (std.mem.indexOfPos(u8, line, from, "grpc")) |at| {
                var i = at + 4;
                if (i < line.len and line[i] == 's') i += 1;
                if (!std.mem.startsWith(u8, line[i..], "://")) {
                    from = at + 1;
                    continue;
                }
                const h = i + 3;
                var e = h;
                while (e < line.len and addressByte(line[e])) e += 1;
                if (e == h) {
                    from = at + 1;
                    continue;
                }
                if (!exampleHost(line[h..e]))
                    try c.finding("{s}:{d}:{s} -- a remote-execution address is committed", .{ f, lines.n, line[at..e] });
                from = e;
            }
        }
    }
}
