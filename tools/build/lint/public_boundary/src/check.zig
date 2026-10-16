//! The public boundary lint over a tree: every path is read for the date,
//! home_path and deny rules (a finding at line 0, marked `(in the path)`),
//! and every file but binary data (BINARY, by suffix) is read line by line
//! for every rule (rules.zig says what each matches). Then the findings no
//! row of the holds ledger holds, and each defect of the two ledgers, are the
//! report.
//!
//! The holds ledger: rows `<rule>\t<file>\t<count>\t<reason>`. <file> (a path
//! of the tree, binary data included) must have exactly <count> findings of
//! <rule>. More is a new finding; fewer is a row to lower or delete, so the
//! holds only shrink. A malformed, repeated or unknown-rule row, a file the
//! tree does not hold, a count that is not a positive whole number and an
//! empty reason are findings. The rule `deny` cannot be held, so a public
//! ledger never says where a private word was.
//!
//! The hosts ledger: rows `<domain>\t<reason>`; a URL host is allowed when it
//! is the domain or ends in `.<domain>`. A row no URL host of the tree is
//! under, a repeated row, a reserved name or an empty reason is a finding:
//! the list only names what the tree uses.
//!
//! The deny list: words kept outside the repository, one per line, matched as
//! a fixed string ignoring case anywhere in a line or path.
//!
//! In all three, `#` lines and blank lines are comments. "Only shrinks" is
//! held by exact counts: a site more or one fewer fails. A row added or a
//! count raised in the same change as the site passes, so review of the
//! ledger's diff is the other half of the rule.

const std = @import("std");
const rules = @import("rules.zig");

/// Binary data, by suffix: its path is read, its contents are not.
pub const BINARY = [_][]const u8{
    "arrow", "orc", "parquet", "avro", "tensor", "frame", "request", "whl", "conda", "gz",  "tgz",   "xz",   "zst",   "bz2",
    "tar",   "zip", "jar",     "png",  "jpg",    "jpeg",  "gif",     "ico", "pdf",   "der", "so", "a",    "o",     "dylib",
    "wasm",  "mojoc", "mojopkg",
};

pub fn binary(path: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    const ext = path[dot + 1 ..];
    if (std.mem.indexOfScalar(u8, ext, '/') != null) return false;
    for (BINARY) |b| if (std.mem.eql(u8, ext, b)) return true;
    return false;
}

/// The rules a holds row can name.
const HOLDABLE = [_][]const u8{ "date", "home_path", "ip", "host", "email", "commit_sha" };

pub const Config = struct {
    /// What a finding's file is named after: `<cell>//<package>/`.
    prefix: []const u8,
    /// What findings call the two ledgers.
    holds_name: []const u8,
    hosts_name: []const u8,
    /// The window: the first year read, and the first day of the public
    /// history (YYYY-MM-01).
    from: []const u8,
    public: []const u8,
};

pub const Ledgers = struct {
    holds: []const u8,
    hosts: []const u8,
    /// The deny list, or "".
    deny: []const u8,
};

pub const Report = struct {
    /// The finding lines, sorted; none when the tree passes.
    lines: []const []const u8,
    /// The files read (every path but binary data).
    checked: usize,
};

const Held = struct { count: usize, row: usize };

const Scan = struct {
    alloc: std.mem.Allocator,
    cfg: Config,
    window: rules.Window,
    hosts: rules.Hosts,
    deny: []const []const u8,
    /// `<rule>\t<file>` -> the sites found, in order.
    sites: std.StringArrayHashMap(std.ArrayList([]const u8)),
    problems: std.ArrayList([]const u8),

    fn add(self: *Scan, rule: []const u8, f: []const u8, line: usize, text: []const u8, in_path: bool) !void {
        const key = try std.fmt.allocPrint(self.alloc, "{s}\t{s}", .{ rule, f });
        const gop = try self.sites.getOrPut(key);
        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList([]const u8).empty;
        const msg = try self.message(rule);
        try gop.value_ptr.append(self.alloc, try std.fmt.allocPrint(self.alloc, "{s}{s}:{d}: {s}: {s}{s} -- {s}", .{
            self.cfg.prefix, f, line, rule, text, if (in_path) " (in the path)" else "", msg,
        }));
    }

    fn message(self: *Scan, rule: []const u8) ![]const u8 {
        if (std.mem.eql(u8, rule, "date")) return std.fmt.allocPrint(self.alloc, "a date before {s}, when the public history starts", .{self.cfg.public});
        if (std.mem.eql(u8, rule, "home_path")) return "a home directory names a person: use a placeholder such as /home/user";
        if (std.mem.eql(u8, rule, "ip")) return "an address of a private, shared or link-local network, or one written as an address: use 127.0.0.1 or a documentation range (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24)";
        if (std.mem.eql(u8, rule, "host")) return std.fmt.allocPrint(self.alloc, "a URL host that is neither a reserved example name nor under a domain of {s}", .{self.cfg.hosts_name});
        if (std.mem.eql(u8, rule, "email")) return "an email address outside the reserved example domains";
        if (std.mem.eql(u8, rule, "commit_sha")) return "a commit id in prose: name the change by its pull request or release";
        return "a word of the private deny list";
    }

    fn denied(self: *Scan, lc: []const u8) ?[]const u8 {
        for (self.deny) |w| if (std.mem.indexOf(u8, lc, w) != null) return w;
        return null;
    }

    /// A date, a home directory or a word of the deny list in the path.
    fn scanPath(self: *Scan, f: []const u8) !void {
        const p = try std.fmt.allocPrint(self.alloc, "/{s}", .{f});
        const lc = try std.ascii.allocLowerString(self.alloc, p);
        if (rules.findDate(self.window, lc)) |t| try self.add("date", f, 0, t, true);
        if (rules.findHome(p)) |t| try self.add("home_path", f, 0, t, true);
        if (self.denied(lc)) |w| try self.add("deny", f, 0, w, true);
    }

    /// Every rule over every line of file f, whose contents are text.
    fn scanFile(self: *Scan, f: []const u8, text: []const u8) !void {
        var prose = rules.Prose.init(self.alloc, f);
        defer prose.deinit();
        var lc_buf = std.ArrayList(u8).empty;
        defer lc_buf.deinit(self.alloc);
        var lines = std.mem.splitScalar(u8, text, '\n');
        var n: usize = 0;
        while (lines.next()) |line| {
            // A final newline ends the last line; it starts no other.
            if (lines.index == null and line.len == 0) break;
            n += 1;
            try lc_buf.resize(self.alloc, line.len);
            const lc = std.ascii.lowerString(lc_buf.items, line);
            if (rules.findDate(self.window, lc)) |t| try self.add("date", f, n, t, false);
            if (rules.findHome(line)) |t| try self.add("home_path", f, n, t, false);
            if (rules.findIp(line)) |t| try self.add("ip", f, n, t, false);
            if (rules.findHost(line, lc, self.hosts)) |t| try self.add("host", f, n, t, false);
            if (rules.findEmail(line, lc, self.hosts)) |t| try self.add("email", f, n, t, false);
            if (rules.findSha(try prose.line(line))) |t| try self.add("commit_sha", f, n, t, false);
            if (self.denied(lc)) |w| try self.add("deny", f, n, w, false);
        }
    }

    fn problem(self: *Scan, comptime fmt: []const u8, args: anytype) !void {
        try self.problems.append(self.alloc, try std.fmt.allocPrint(self.alloc, fmt, args));
    }
};

/// Whether a ledger line is a comment: `#` first, or blank.
fn comment(line: []const u8) bool {
    const t = std.mem.trimLeft(u8, line, " \t");
    return t.len == 0 or t[0] == '#';
}

fn blank(s: []const u8) bool {
    return std.mem.trim(u8, s, " \t").len == 0;
}

fn fields(alloc: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, line, '\t');
    while (it.next()) |f| try out.append(alloc, f);
    return out.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Splits text into lines: a final newline starts no line.
fn lineList(alloc: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (it.index == null and l.len == 0) break;
        try out.append(alloc, l);
    }
    return out.items;
}

/// The lint over `paths` (every file of the tree, sorted), whose contents
/// `reader.read(path)` returns (and `reader.free` releases). `alloc` holds
/// the report; it is meant to be an arena.
pub fn run(alloc: std.mem.Allocator, cfg: Config, ledgers: Ledgers, paths: []const []const u8, reader: anytype) !Report {
    var checked: usize = 0;
    for (paths) |p| {
        if (!binary(p)) checked += 1;
    }
    var out = std.ArrayList([]const u8).empty;
    const window = rules.Window.parse(cfg.from, cfg.public) orelse {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "public_boundary: the window is from year `{s}` to `{s}`; name a year and a later first day of a month (YYYY-MM-01)", .{ cfg.from, cfg.public }));
        return .{ .lines = out.items, .checked = checked };
    };

    var scan = Scan{
        .alloc = alloc,
        .cfg = cfg,
        .window = window,
        .hosts = undefined,
        .deny = &.{},
        .sites = std.StringArrayHashMap(std.ArrayList([]const u8)).init(alloc),
        .problems = std.ArrayList([]const u8).empty,
    };

    // The hosts ledger.
    var domains = std.ArrayList([]const u8).empty;
    var domain_rows = std.ArrayList(usize).empty;
    for (try lineList(alloc, ledgers.hosts), 1..) |line, row| {
        if (comment(line)) continue;
        const f = try fields(alloc, line);
        if (f.len != 2) {
            try scan.problem("{s}:{d}: a row has 2 tab-separated fields (domain, reason), not {d}", .{ cfg.hosts_name, row, f.len });
            continue;
        }
        const d = try std.ascii.allocLowerString(alloc, f[0]);
        if (blank(f[1])) {
            try scan.problem("{s}:{d}: empty reason: say whose service {s} is", .{ cfg.hosts_name, row, d });
            continue;
        }
        if (rules.reserved(d)) {
            try scan.problem("{s}:{d}: {s} is reserved for examples and needs no row; delete the row", .{ cfg.hosts_name, row, d });
            continue;
        }
        var repeated = false;
        for (domains.items) |e| repeated = repeated or std.mem.eql(u8, e, d);
        if (repeated) {
            try scan.problem("{s}:{d}: a second row for {s}", .{ cfg.hosts_name, row, d });
            continue;
        }
        try domains.append(alloc, d);
        try domain_rows.append(alloc, row);
    }
    const used = try alloc.alloc(bool, domains.items.len);
    @memset(used, false);
    scan.hosts = .{ .domains = domains.items, .used = used };

    // The deny list.
    var deny = std.ArrayList([]const u8).empty;
    for (try lineList(alloc, ledgers.deny)) |line| {
        if (comment(line)) continue;
        const w = std.mem.trim(u8, try std.ascii.allocLowerString(alloc, line), " \t");
        if (w.len > 0) try deny.append(alloc, w);
    }
    scan.deny = deny.items;

    // The holds ledger.
    var known = std.StringHashMap(void).init(alloc);
    for (paths) |p| try known.put(p, {});
    var held = std.StringArrayHashMap(Held).init(alloc);
    for (try lineList(alloc, ledgers.holds), 1..) |line, row| {
        if (comment(line)) continue;
        const f = try fields(alloc, line);
        if (f.len != 4) {
            try scan.problem("{s}:{d}: a row has 4 tab-separated fields (rule, file, count, reason), not {d}", .{ cfg.holds_name, row, f.len });
            continue;
        }
        var holdable = false;
        for (HOLDABLE) |r| holdable = holdable or std.mem.eql(u8, f[0], r);
        if (!holdable) {
            try scan.problem("{s}:{d}: unknown rule `{s}` (the rules a row can hold: date, home_path, ip, host, email, commit_sha)", .{ cfg.holds_name, row, f[0] });
            continue;
        }
        if (!known.contains(f[1])) {
            try scan.problem("{s}:{d}: {s} is not a file of the tree; delete the row", .{ cfg.holds_name, row, f[1] });
            continue;
        }
        const count = positive(f[2]) orelse {
            try scan.problem("{s}:{d}: count `{s}` is not a positive whole number", .{ cfg.holds_name, row, f[2] });
            continue;
        };
        if (blank(f[3])) {
            try scan.problem("{s}:{d}: empty reason: say why the file holds it", .{ cfg.holds_name, row });
            continue;
        }
        const key = try std.fmt.allocPrint(alloc, "{s}\t{s}", .{ f[0], f[1] });
        const gop = try held.getOrPut(key);
        if (gop.found_existing) {
            try scan.problem("{s}:{d}: a second row for {s} in {s}", .{ cfg.holds_name, row, f[0], f[1] });
            continue;
        }
        gop.value_ptr.* = .{ .count = count, .row = row };
    }

    // The tree.
    for (paths) |p| try scan.scanPath(p);
    for (paths) |p| {
        if (binary(p)) continue;
        const text = reader.read(p) catch |err| {
            try scan.problem("{s}{s}: cannot be read ({s}); the lint read nothing of it", .{ cfg.prefix, p, @errorName(err) });
            continue;
        };
        defer reader.free(text);
        try scan.scanFile(p, text);
    }

    // Findings over their holds, holds over their findings, unused hosts.
    var it = scan.sites.iterator();
    while (it.next()) |e| {
        const n = e.value_ptr.items.len;
        const h = if (held.get(e.key_ptr.*)) |x| x.count else 0;
        if (n <= h) continue;
        for (e.value_ptr.items) |site| {
            if (h == 0) {
                try out.append(alloc, site);
            } else try out.append(alloc, try std.fmt.allocPrint(alloc, "{s} ({d} findings, held {d})", .{ site, n, h }));
        }
    }
    var hit = held.iterator();
    while (hit.next()) |e| {
        const c = if (scan.sites.get(e.key_ptr.*)) |s| s.items.len else 0;
        if (c >= e.value_ptr.count) continue;
        const tab = std.mem.indexOfScalar(u8, e.key_ptr.*, '\t').?;
        const rule = e.key_ptr.*[0..tab];
        const f = e.key_ptr.*[tab + 1 ..];
        if (c > 0) {
            try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}:{d}: {s} in {s} is held at {d} and has {d}: lower the count to {d}", .{ cfg.holds_name, e.value_ptr.row, rule, f, e.value_ptr.count, c, c }));
        } else try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}:{d}: {s} in {s} is held at {d} and has 0: delete the row", .{ cfg.holds_name, e.value_ptr.row, rule, f, e.value_ptr.count }));
    }
    for (domains.items, used, domain_rows.items) |d, u, row| {
        if (!u) try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}:{d}: no URL host of the tree is {s} or under it; delete the row", .{ cfg.hosts_name, row, d }));
    }
    try out.appendSlice(alloc, scan.problems.items);
    std.mem.sort([]const u8, out.items, {}, lessThan);
    if (checked == 0) try out.append(alloc, "public_boundary: checked nothing (no inputs, or no lines to check)");
    return .{ .lines = out.items, .checked = checked };
}

/// `[1-9][0-9]*` as a number, or null.
fn positive(s: []const u8) ?usize {
    if (s.len == 0 or s[0] == '0' or s.len > 18) return null;
    for (s) |c| if (c < '0' or c > '9') return null;
    return std.fmt.parseInt(usize, s, 10) catch null;
}

/// The validation result Buck2 reads: status "failure" with the report (its
/// first 200 lines) as the message when there are finding lines, "success"
/// with the number of files read otherwise.
pub fn result(alloc: std.mem.Allocator, report: Report) ![]const u8 {
    var msg = std.ArrayList(u8).empty;
    const w = msg.writer(alloc);
    if (report.lines.len > 0) {
        try w.print("public_boundary: {d} finding line(s)\n", .{report.lines.len});
        for (report.lines[0..@min(report.lines.len, 200)]) |l| try w.print("{s}\n", .{l});
    } else try w.print("public_boundary: {d} checked", .{report.checked});
    var json = std.Io.Writer.Allocating.init(alloc);
    const jw = &json.writer;
    try jw.print("{{\"version\": 1, \"data\": {{\"status\": \"{s}\", \"message\": ", .{if (report.lines.len > 0) "failure" else "success"});
    try std.json.Stringify.encodeJsonString(msg.items, .{}, jw);
    try jw.writeAll("}}\n");
    return json.written();
}

/// Every file of dir (regular files and symlinks), by its path in it, sorted.
pub fn list(alloc: std.mem.Allocator, dir: std.fs.Dir) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next()) |e| {
        if (e.kind == .file or e.kind == .sym_link) try out.append(alloc, try alloc.dupe(u8, e.path));
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.items;
}

/// Reads the files of a directory for `run`.
pub const DirReader = struct {
    dir: std.fs.Dir,
    alloc: std.mem.Allocator,

    pub fn read(self: DirReader, p: []const u8) ![]const u8 {
        return self.dir.readFileAlloc(self.alloc, p, 1 << 30);
    }

    pub fn free(self: DirReader, text: []const u8) void {
        self.alloc.free(text);
    }
};
