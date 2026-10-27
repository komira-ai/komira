//! release_beta_version: gives every member of a mopm workspace one beta version.
//!
//!   release_beta_version --workspace-root <dir> --version 0.1.<n>
//!
//! The beta registry accepts a (name, version) pair once, and mopm versions are exactly
//! MAJOR.MINOR.PATCH, so each push to main needs a fresh number. release.yml's `mopm-stage-beta`
//! job runs this on its own checkout, before `mopm stage`, with `0.1.<github.run_number>`: the
//! number stays inside the `>=0.1,<0.2` every package asks of its siblings, sorts above 0.1.0,
//! and the newest push is the newest version. Nothing is committed back; prod never runs this.
//!
//! `mopm stage` reads each version from `mopm.toml` when it runs (src/cli/stage_cmd.zig walks
//! the workspace and packs `.mojoc` bytes that carry no version), so rewriting the manifests
//! before the stage is enough.
//!
//! What it changes, as text edits that keep every other byte of the file:
//!  - `[package] version` of each member (the members are found the way `mopm stage` finds
//!    them: every directory holding a `mopm.toml`, below the root, not below another member,
//!    skipping hidden directories and buck-out, node_modules, zig-out, zig-cache);
//!  - in `[dependencies]` and `[dev-dependencies]`, a requirement on another member that has an
//!    exact comparator `=MAJOR.MINOR.PATCH`: that number becomes the new version, because
//!    `mopm stage` checks each such requirement against the member's version. Every other
//!    comparator (`^0.1`, `>=0.1, <0.2`, `~0.1.0`, `0.1`, `*`, `=0.1`) accepts every 0.1.x and is
//!    kept as written.
//!
//! It refuses, and writes nothing, when: the version is not exactly 0.1.<PATCH> (digits, no
//! leading zeros); a member's version is not in 0.1.x; a member's name or version is missing
//! or not a plain one-line string; two members share a name; a requirement on a member is not
//! comparators it can read, or its exact comparator is not the member's current version; a
//! manifest holds a multi-line string or a dependency line it cannot read. Running it again
//! with the same version changes nothing.
const std = @import("std");

const Allocator = std.mem.Allocator;
pub const Error = error{ Refused, OutOfMemory };

const skipped_dirs = [_][]const u8{ "buck-out", "node_modules", "zig-out", "zig-cache" };
const max_depth: usize = 12;

fn refuse(a: Allocator, why: *[]const u8, comptime fmt: []const u8, args: anytype) Error {
    why.* = try std.fmt.allocPrint(a, fmt, args);
    return error.Refused;
}

pub const Version = struct {
    major: u64,
    minor: u64,
    patch: u64,
};

/// One number of a version: digits, no leading zero, at most 18 digits (mopm's own bound).
fn number(s: []const u8) ?u64 {
    if (s.len == 0 or s.len > 18 or (s.len > 1 and s[0] == '0')) return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u64, s, 10) catch null;
}

/// MAJOR.MINOR.PATCH and nothing else, or null.
pub fn parseVersion(s: []const u8) ?Version {
    var it = std.mem.splitScalar(u8, s, '.');
    const major = number(it.next() orelse return null) orelse return null;
    const minor = number(it.next() orelse return null) orelse return null;
    const patch = number(it.next() orelse return null) orelse return null;
    if (it.next() != null) return null;
    return .{ .major = major, .minor = minor, .patch = patch };
}

/// The version to give: exactly 0.1.<PATCH>.
pub fn checkTarget(a: Allocator, text: []const u8, why: *[]const u8) Error!void {
    const v = parseVersion(text) orelse return refuse(a, why, "version '{s}' is not MAJOR.MINOR.PATCH (digits, no leading zeros, no suffix)", .{text});
    if (v.major != 0 or v.minor != 1) return refuse(a, why, "version '{s}' is not in 0.1.x: the packages ask their siblings for >=0.1,<0.2", .{text});
}

const Section = enum { package, deps, dep_table, other };

/// What a `[header]` line opens.
const Header = struct { section: Section, dep: []const u8 = "" };

fn isBareKey(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    return true;
}

fn header(a: Allocator, why: *[]const u8, where: []const u8, line_no: usize, inner_raw: []const u8) Error!Header {
    const inner = std.mem.trim(u8, inner_raw, " \t");
    if (std.mem.eql(u8, inner, "package")) return .{ .section = .package };
    if (std.mem.eql(u8, inner, "dependencies") or std.mem.eql(u8, inner, "dev-dependencies")) return .{ .section = .deps };
    inline for (.{ "dependencies.", "dev-dependencies." }) |p| {
        if (std.mem.startsWith(u8, inner, p)) {
            const name = inner[p.len..];
            if (!isBareKey(name)) return refuse(a, why, "{s}:{d}: the table '[{s}]' is a form this tool does not read", .{ where, line_no, inner });
            return .{ .section = .dep_table, .dep = name };
        }
    }
    // `[package.metadata]` and the like are other tools' settings; any other spelling of a
    // table this tool edits (spaces in a dotted name) could hide a pin, so it is refused.
    if (std.mem.startsWith(u8, inner, "package.")) return .{ .section = .other };
    inline for (.{ "package", "dependencies", "dev-dependencies" }) |p| {
        if (std.mem.startsWith(u8, inner, p)) return refuse(a, why, "{s}:{d}: the table '[{s}]' is a form this tool does not read", .{ where, line_no, inner });
    }
    return .{ .section = .other };
}

/// A basic one-line string at the start of `v` (after trimming): its text range inside `v`, or
/// null. Only a comment may follow it.
const Quoted = struct { start: usize, end: usize };

fn quoted(v: []const u8) ?Quoted {
    if (v.len < 2 or v[0] != '"') return null;
    var i: usize = 1;
    while (i < v.len and v[i] != '"') : (i += 1) {
        if (v[i] == '\\') return null;
    }
    if (i >= v.len) return null;
    const rest = std.mem.trim(u8, v[i + 1 ..], " \t");
    if (rest.len != 0 and rest[0] != '#') return null;
    return .{ .start = 1, .end = i };
}

/// A `key = value` line: the key, and the offset of the value in the line.
const Pair = struct { key: []const u8, value_at: usize };

fn pair(line: []const u8) ?Pair {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const key = std.mem.trim(u8, line[0..eq], " \t");
    var at = eq + 1;
    while (at < line.len and (line[at] == ' ' or line[at] == '\t')) at += 1;
    return .{ .key = key, .value_at = at };
}

fn lineKind(line: []const u8) enum { skip, header, entry } {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len == 0 or t[0] == '#') return .skip;
    if (t[0] == '[') return .header;
    return .entry;
}

/// The text between the brackets of a header line, or null if the line is not one header.
fn headerInner(line: []const u8) ?[]const u8 {
    var t = std.mem.trim(u8, line, " \t\r");
    if (std.mem.indexOfScalar(u8, t, '#')) |h| t = std.mem.trim(u8, t[0..h], " \t");
    if (t.len < 3 or t[0] != '[' or t[t.len - 1] != ']') return null;
    const inner = t[1 .. t.len - 1];
    if (std.mem.indexOfAny(u8, inner, "[]=,") != null) return null;
    return inner;
}

/// What a header-looking line opens: null when it is no header at all (the line of a nested array);
/// an array of tables (`[[x]]`) opens a section this tool does not read.
fn headerOf(a: Allocator, why: *[]const u8, where: []const u8, line_no: usize, line: []const u8) Error!?Header {
    if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t\r"), "[[")) return Header{ .section = .other };
    const inner = headerInner(line) orelse return null;
    return try header(a, why, where, line_no, inner);
}

fn noMultiline(a: Allocator, why: *[]const u8, where: []const u8, text: []const u8) Error!void {
    if (std.mem.indexOf(u8, text, "\"\"\"") != null or std.mem.indexOf(u8, text, "'''") != null)
        return refuse(a, why, "{s}: holds a multi-line string, which this tool does not read", .{where});
}

pub const Identity = struct { name: []const u8, version: []const u8 };

/// A member's `[package]` name and version.
pub fn readIdentity(a: Allocator, why: *[]const u8, where: []const u8, text: []const u8) Error!Identity {
    try noMultiline(a, why, where, text);
    var name: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var section: Section = .other;
    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        line_no += 1;
        const line = std.mem.trimRight(u8, raw, "\r");
        switch (lineKind(line)) {
            .skip => {},
            .header => if (try headerOf(a, why, where, line_no, line)) |h| {
                section = h.section;
            } else if (section == .package) {
                return refuse(a, why, "{s}:{d}: a line this tool does not read", .{ where, line_no });
            },
            .entry => {
                if (section != .package) continue;
                const p = pair(line) orelse continue;
                const is_name = std.mem.eql(u8, p.key, "name");
                const is_version = std.mem.eql(u8, p.key, "version");
                if (!is_name and !is_version) continue;
                const q = quoted(line[p.value_at..]) orelse return refuse(a, why, "{s}:{d}: '{s}' is not a plain one-line string", .{ where, line_no, p.key });
                const value = line[p.value_at..][q.start..q.end];
                const slot = if (is_name) &name else &version;
                if (slot.* != null) return refuse(a, why, "{s}:{d}: '{s}' is set twice", .{ where, line_no, p.key });
                slot.* = value;
            },
        }
    }
    return .{
        .name = name orelse return refuse(a, why, "{s}: [package] has no name", .{where}),
        .version = version orelse return refuse(a, why, "{s}: [package] has no version", .{where}),
    };
}

/// A member of the workspace.
pub const Member = struct { name: []const u8, version: []const u8 };

fn memberVersion(members: []const Member, name: []const u8) ?[]const u8 {
    for (members) |m| if (std.mem.eql(u8, m.name, name)) return m.version;
    return null;
}

/// Rewrites the requirement text `req` of a dependency on a member now at `current`: each
/// exact comparator `=X.Y.Z` becomes `=new`, the others stay. How many were changed is in `changed`.
pub fn rewriteRequirement(a: Allocator, why: *[]const u8, where: []const u8, dep: []const u8, req: []const u8, current: []const u8, new: []const u8, changed: *usize) Error![]u8 {
    var out = std.ArrayList(u8).empty;
    var it = std.mem.splitScalar(u8, req, ',');
    var first = true;
    while (it.next()) |piece| {
        if (!first) try out.append(a, ',');
        first = false;
        const lead = piece.len - std.mem.trimLeft(u8, piece, " \t").len;
        const body = std.mem.trim(u8, piece, " \t");
        var op_len: usize = 0;
        for ([_][]const u8{ ">=", "<=", ">", "<", "=", "~", "^" }) |op| {
            if (std.mem.startsWith(u8, body, op)) {
                op_len = op.len;
                break;
            }
        }
        const op = body[0..op_len];
        const after = std.mem.trimLeft(u8, body[op_len..], " \t");
        if (after.len == 0) return refuse(a, why, "{s}: the requirement '{s}' on {s} has an empty comparator", .{ where, req, dep });
        var parts: usize = 0;
        var wild = false;
        var pit = std.mem.splitScalar(u8, after, '.');
        while (pit.next()) |p| : (parts += 1) {
            if (wild or parts >= 3) return refuse(a, why, "{s}: the requirement '{s}' on {s} is not comparators this tool reads", .{ where, req, dep });
            if (std.mem.eql(u8, p, "*")) {
                wild = true;
            } else if (number(p) == null) {
                return refuse(a, why, "{s}: the requirement '{s}' on {s} is not comparators this tool reads", .{ where, req, dep });
            }
        }
        if (wild and op.len != 0) return refuse(a, why, "{s}: the requirement '{s}' on {s} is not comparators this tool reads", .{ where, req, dep });
        try out.appendSlice(a, piece[0..lead]);
        if (std.mem.eql(u8, op, "=") and parts == 3 and !wild) {
            if (!std.mem.eql(u8, after, current))
                return refuse(a, why, "{s}: {s} is pinned at '={s}', but the member is at {s}", .{ where, dep, after, current });
            try out.appendSlice(a, piece[lead..][0 .. body.len - after.len]);
            try out.appendSlice(a, new);
            if (!std.mem.eql(u8, after, new)) changed.* += 1;
        } else {
            try out.appendSlice(a, piece[lead..][0 .. body.len]);
        }
        try out.appendSlice(a, piece[lead + body.len ..]);
    }
    return out.toOwnedSlice(a);
}

pub const Rewritten = struct {
    text: []u8,
    /// Whether `[package] version` was different.
    version_changed: bool,
    /// Requirements on other members that got a new number.
    pins_changed: usize,
};

/// The manifest `text` with the member's version set to `new` and the exact pins on members
/// (`members`, with the versions they have now) set to match.
pub fn rewriteManifest(a: Allocator, why: *[]const u8, where: []const u8, text: []const u8, members: []const Member, new: []const u8) Error!Rewritten {
    try noMultiline(a, why, where, text);
    var out = std.ArrayList(u8).empty;
    var section: Section = .other;
    var dep_table: []const u8 = "";
    var line_no: usize = 0;
    var version_changed = false;
    var saw_version = false;
    var pins: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |raw| {
        line_no += 1;
        if (!first) try out.append(a, '\n');
        first = false;
        const cr = raw.len > 0 and raw[raw.len - 1] == '\r';
        const line = if (cr) raw[0 .. raw.len - 1] else raw;
        var edited: ?[]u8 = null;
        switch (lineKind(line)) {
            .skip => {},
            .header => if (try headerOf(a, why, where, line_no, line)) |h| {
                section = h.section;
                dep_table = h.dep;
            } else if (section == .package or section == .deps or section == .dep_table) {
                return refuse(a, why, "{s}:{d}: a line this tool does not read", .{ where, line_no });
            },
            .entry => switch (section) {
                .package => if (pair(line)) |p| if (std.mem.eql(u8, p.key, "version")) {
                    const q = quoted(line[p.value_at..]) orelse return refuse(a, why, "{s}:{d}: 'version' is not a plain one-line string", .{ where, line_no });
                    const old = line[p.value_at..][q.start..q.end];
                    saw_version = true;
                    if (!std.mem.eql(u8, old, new)) version_changed = true;
                    edited = try std.mem.concat(a, u8, &.{ line[0 .. p.value_at + q.start], new, line[p.value_at + q.end ..] });
                },
                .deps => {
                    const p = pair(line) orelse return refuse(a, why, "{s}:{d}: a dependency line this tool does not read", .{ where, line_no });
                    if (!isBareKey(p.key)) return refuse(a, why, "{s}:{d}: the dependency name '{s}' is not a plain name", .{ where, line_no, p.key });
                    const value = line[p.value_at..];
                    if (value.len == 0 or (value[0] != '"' and value[0] != '{'))
                        return refuse(a, why, "{s}:{d}: the dependency '{s}' is not a string or a one-line table", .{ where, line_no, p.key });
                    if (memberVersion(members, p.key)) |current| {
                        if (value[0] == '"') {
                            const q = quoted(value) orelse return refuse(a, why, "{s}:{d}: the requirement on {s} is not a plain one-line string", .{ where, line_no, p.key });
                            const r = try rewriteRequirement(a, why, where, p.key, value[q.start..q.end], current, new, &pins);
                            edited = try std.mem.concat(a, u8, &.{ line[0 .. p.value_at + q.start], r, line[p.value_at + q.end ..] });
                        } else {
                            edited = try rewriteInline(a, why, where, line_no, line, p, current, new, &pins);
                        }
                    } else if (value[0] == '{' and std.mem.indexOfScalar(u8, value, '}') == null) {
                        return refuse(a, why, "{s}:{d}: the dependency '{s}' is not a one-line table", .{ where, line_no, p.key });
                    }
                },
                .dep_table => if (memberVersion(members, dep_table)) |current| {
                    const p = pair(line) orelse return refuse(a, why, "{s}:{d}: a line this tool does not read", .{ where, line_no });
                    if (std.mem.eql(u8, p.key, "version")) {
                        const q = quoted(line[p.value_at..]) orelse return refuse(a, why, "{s}:{d}: the requirement on {s} is not a plain one-line string", .{ where, line_no, dep_table });
                        const r = try rewriteRequirement(a, why, where, dep_table, line[p.value_at..][q.start..q.end], current, new, &pins);
                        edited = try std.mem.concat(a, u8, &.{ line[0 .. p.value_at + q.start], r, line[p.value_at + q.end ..] });
                    }
                },
                .other => {},
            },
        }
        try out.appendSlice(a, edited orelse line);
        if (cr) try out.append(a, '\r');
    }
    if (!saw_version) return refuse(a, why, "{s}: [package] has no version", .{where});
    return .{ .text = try out.toOwnedSlice(a), .version_changed = version_changed, .pins_changed = pins };
}

/// `name = { version = "req", path = "../x" }` with the requirement rewritten.
fn rewriteInline(a: Allocator, why: *[]const u8, where: []const u8, line_no: usize, line: []const u8, p: Pair, current: []const u8, new: []const u8, pins: *usize) Error![]u8 {
    const value = line[p.value_at..];
    // The table ends at the first '}' outside a string; only a comment may follow it.
    var in_str = false;
    var close: ?usize = null;
    for (value, 0..) |c, i| {
        if (c == '"') in_str = !in_str;
        if (!in_str and c == '}') {
            close = i;
            break;
        }
    }
    const end = close orelse return refuse(a, why, "{s}:{d}: the dependency '{s}' is not a one-line table", .{ where, line_no, p.key });
    const rest = std.mem.trim(u8, value[end + 1 ..], " \t");
    if (rest.len != 0 and rest[0] != '#') return refuse(a, why, "{s}:{d}: the dependency '{s}' has text after its table", .{ where, line_no, p.key });
    var seg_start: usize = 1;
    var i: usize = 1;
    in_str = false;
    var found = false;
    var result: ?[]u8 = null;
    while (i <= end) : (i += 1) {
        const c = value[i];
        if (c == '"') in_str = !in_str;
        if (in_str or (c != ',' and i != end)) continue;
        const seg = value[seg_start..i];
        if (pair(seg)) |sp| {
            if (std.mem.eql(u8, sp.key, "version")) {
                if (found) return refuse(a, why, "{s}:{d}: '{s}' sets version twice", .{ where, line_no, p.key });
                found = true;
                const sv = seg[sp.value_at..];
                const trimmed = std.mem.trimRight(u8, sv, " \t");
                const q = quoted(trimmed) orelse return refuse(a, why, "{s}:{d}: the requirement on {s} is not a plain string", .{ where, line_no, p.key });
                if (q.end + 1 != trimmed.len) return refuse(a, why, "{s}:{d}: the requirement on {s} is not a plain string", .{ where, line_no, p.key });
                const r = try rewriteRequirement(a, why, where, p.key, trimmed[q.start..q.end], current, new, pins);
                const at = p.value_at + seg_start + sp.value_at + q.start;
                result = try std.mem.concat(a, u8, &.{ line[0..at], r, line[at + (q.end - q.start) ..] });
            }
        } else if (std.mem.trim(u8, seg, " \t").len != 0) {
            return refuse(a, why, "{s}:{d}: the table of '{s}' holds text this tool does not read", .{ where, line_no, p.key });
        }
        seg_start = i + 1;
    }
    return result orelse try a.dupe(u8, line);
}

/// A member's manifest as found on disk.
pub const Found = struct { dir: []const u8, file: []const u8, text: []const u8, id: Identity };

fn walk(a: Allocator, why: *[]const u8, dir: []const u8, depth: usize, found: *std.ArrayList(Found)) anyerror!void {
    if (depth > max_depth) return;
    const file = try std.fs.path.join(a, &.{ dir, "mopm.toml" });
    if (std.fs.cwd().readFileAlloc(a, file, 1 << 20)) |text| {
        try found.append(a, .{ .dir = dir, .file = file, .text = text, .id = try readIdentity(a, why, file, text) });
        return;
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => return refuse(a, why, "{s}: {s}", .{ file, @errorName(e) }),
    }
    var d = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer d.close();
    var names = std.ArrayList([]const u8).empty;
    var it = d.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory or entry.name[0] == '.') continue;
        var skip = false;
        for (skipped_dirs) |s| skip = skip or std.mem.eql(u8, s, entry.name);
        if (!skip) try names.append(a, try a.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    for (names.items) |n| try walk(a, why, try std.fs.path.join(a, &.{ dir, n }), depth + 1, found);
}

/// What `run` did, for the report.
pub const Report = struct { members: usize, versions_changed: usize, pins_changed: usize };

/// Rewrites every member below `root` to `version`; writes nothing unless every member passes.
/// Lines of what changed go to `log`.
pub fn run(a: Allocator, why: *[]const u8, root: []const u8, version: []const u8, log: *std.Io.Writer) !Report {
    try checkTarget(a, version, why);
    var found = std.ArrayList(Found).empty;
    try walk(a, why, root, 0, &found);
    if (found.items.len == 0) return refuse(a, why, "{s} holds no mopm.toml: there are no members", .{root});
    var members = std.ArrayList(Member).empty;
    for (found.items, 0..) |f, i| {
        for (found.items[0..i]) |o| {
            if (std.mem.eql(u8, o.id.name, f.id.name)) return refuse(a, why, "{s} and {s} are both the package {s}", .{ o.file, f.file, f.id.name });
        }
        const v = parseVersion(f.id.version) orelse return refuse(a, why, "{s}: version '{s}' is not MAJOR.MINOR.PATCH", .{ f.file, f.id.version });
        if (v.major != 0 or v.minor != 1) return refuse(a, why, "{s}: version {s} is not in 0.1.x", .{ f.file, f.id.version });
        try members.append(a, .{ .name = f.id.name, .version = f.id.version });
    }
    const outs = try a.alloc(Rewritten, found.items.len);
    for (found.items, 0..) |f, i| outs[i] = try rewriteManifest(a, why, f.file, f.text, members.items, version);
    var rep = Report{ .members = found.items.len, .versions_changed = 0, .pins_changed = 0 };
    for (found.items, outs) |f, o| {
        if (std.mem.eql(u8, f.text, o.text)) continue;
        try std.fs.cwd().writeFile(.{ .sub_path = f.file, .data = o.text });
        if (o.version_changed) rep.versions_changed += 1;
        rep.pins_changed += o.pins_changed;
        try log.print("{s}: version {s} -> {s}, {d} pin(s) changed\n", .{ f.file, f.id.version, version, o.pins_changed });
    }
    return rep;
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ebuf: [1024]u8 = undefined;
    var err = std.fs.File.stderr().writer(&ebuf);
    var obuf: [1024]u8 = undefined;
    var out = std.fs.File.stdout().writer(&obuf);
    const args = try std.process.argsAlloc(a);
    var root: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        const slot: *?[]const u8 = if (std.mem.eql(u8, flag, "--workspace-root")) &root else if (std.mem.eql(u8, flag, "--version")) &version else {
            try err.interface.print("release_beta_version: unknown argument {s}\n", .{flag});
            try err.interface.flush();
            return 2;
        };
        i += 1;
        if (i >= args.len or slot.* != null) {
            try err.interface.print("release_beta_version: {s} needs one value, given once\n", .{flag});
            try err.interface.flush();
            return 2;
        }
        slot.* = args[i];
    }
    if (root == null or version == null) {
        try err.interface.writeAll("usage: release_beta_version --workspace-root <dir> --version 0.1.<n>\n");
        try err.interface.flush();
        return 2;
    }
    var why: []const u8 = "";
    const rep = run(a, &why, root.?, version.?, &out.interface) catch |e| {
        const msg = if (e == error.Refused) why else @errorName(e);
        try err.interface.print("release_beta_version: refused: {s}\n", .{msg});
        try err.interface.flush();
        return 1;
    };
    try out.interface.print("release_beta_version: {d} member(s) at {s}: {d} version(s) and {d} pin(s) changed\n", .{ rep.members, version.?, rep.versions_changed, rep.pins_changed });
    try out.interface.flush();
    return 0;
}
