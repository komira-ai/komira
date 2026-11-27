//! changelog: what the Python package's changelog is made of, and how a release's section is written.
//!
//! Every change to the package adds one file, `python/changelog.d/<slug>.md`, and never a line of
//! `python/CHANGELOG.md`, so two changes never edit the same line. The file holds Markdown bullets
//! (`- **Title.** text`, a continuation line indented two spaces, no heading). The release assembles the
//! changelog: `assemble` puts a new section, `## 0.1.<n>` for the release the build is stamped as or
//! `## Unreleased` for an unstamped build, before the first release heading of CHANGELOG.md, holding the
//! bullets of every file in file-name order. `description` is the text of the wheel's page: the README,
//! then the assembled changelog with each heading one level down so that it nests under the README, and in a
//! stamped build every link to the repository's `main` pinned to the commit the wheel was built from, so the
//! pages its PyPI page links to describe that wheel and not a later `main`.
//!
//! Every function that can refuse returns `error.Refused` and leaves the reason in the `why` it was given,
//! naming the file and, when a line is at fault, its number.
const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const Error = error{ Refused, OutOfMemory };

pub fn refuse(a: Allocator, why: *[]const u8, comptime fmt: []const u8, args: anytype) Error {
    why.* = try std.fmt.allocPrint(a, fmt, args);
    return error.Refused;
}

/// One file of `changelog.d`: its name there and its bytes.
pub const Fragment = struct { name: []const u8, text: []const u8 };

/// What the changelog is made of, with the paths messages call the files by (`python/CHANGELOG.md`, and
/// `python/changelog.d/` before a fragment's name).
pub const Inputs = struct {
    changelog_path: []const u8,
    changelog: []const u8,
    fragments_dir: []const u8,
    fragments: []const Fragment,
};

/// The line the section holds when no file is in `changelog.d`.
pub const no_entries = "No change to what the package does or needs is listed since the release below.";

/// The heading text of the build's stamp (`-c komira.package_stamp`): `Unreleased` when the build is not
/// stamped (`0` or empty), else `0.1.<n>`, the version the wheel is given (tools/build/package/wheel/stamp.zig).
pub fn headingOf(a: Allocator, why: *[]const u8, stamp: []const u8) Error![]const u8 {
    if (stamp.len == 0 or std.mem.eql(u8, stamp, "0")) return "Unreleased";
    var digits = stamp.len != 0;
    for (stamp) |c| {
        if (!std.ascii.isDigit(c)) digits = false;
    }
    if (!digits or stamp[0] == '0') return refuse(a, why, "the stamp `{s}` is not a positive number without leading zeros", .{stamp});
    return std.fmt.allocPrint(a, "0.1.{s}", .{stamp});
}

/// Whether `name` is `<slug>.md` with a slug of lower-case letters, digits and hyphens, not starting with a hyphen.
pub fn isFragmentName(name: []const u8) bool {
    const suffix = ".md";
    if (name.len <= suffix.len or !std.mem.endsWith(u8, name, suffix)) return false;
    const slug = name[0 .. name.len - suffix.len];
    for (slug, 0..) |c, i| {
        const letter = c >= 'a' and c <= 'z';
        const digit = c >= '0' and c <= '9';
        if (!(letter or digit or (c == '-' and i != 0))) return false;
    }
    return true;
}

fn blank(line: []const u8) bool {
    return std.mem.trim(u8, line, " ").len == 0;
}

/// The bullets of one fragment: its lines with the blank ones before the first and after the last cut, or the
/// refusal naming the file and the line.
fn body(a: Allocator, why: *[]const u8, dir: []const u8, f: Fragment) Error![]const u8 {
    if (!isFragmentName(f.name)) {
        return refuse(a, why, "{s}{s}: the name is not `<slug>.md` with a slug of lower-case letters, digits and hyphens that does not start with a hyphen", .{ dir, f.name });
    }
    var lines = std.ArrayList([]const u8).empty;
    var bullets: usize = 0;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, f.text, '\n');
    while (it.next()) |line| {
        n += 1;
        if (std.mem.indexOfScalar(u8, line, '\r') != null) {
            return refuse(a, why, "{s}{s}:{d}: the line holds a carriage return: a fragment's lines end with a line feed alone", .{ dir, f.name, n });
        }
        if (blank(line)) {
            if (bullets != 0) try lines.append(a, "");
            continue;
        }
        if (line[0] == '#') {
            return refuse(a, why, "{s}{s}:{d}: a heading: a fragment holds bullets only, and the title is the bold text of its bullet", .{ dir, f.name, n });
        }
        if (std.mem.startsWith(u8, line, "- ")) {
            bullets += 1;
        } else if (std.mem.startsWith(u8, line, "  ")) {
            if (bullets == 0) return refuse(a, why, "{s}{s}:{d}: an indented line before the first bullet: a continuation continues a bullet", .{ dir, f.name, n });
        } else {
            return refuse(a, why, "{s}{s}:{d}: the line is neither a bullet (`- `) nor a continuation indented two spaces", .{ dir, f.name, n });
        }
        try lines.append(a, line);
    }
    if (bullets == 0) return refuse(a, why, "{s}{s}: the fragment is empty: it holds no bullet", .{ dir, f.name });
    while (lines.items.len != 0 and lines.items[lines.items.len - 1].len == 0) _ = lines.pop();
    return std.mem.join(a, "\n", lines.items);
}

fn nameLess(_: void, x: Fragment, y: Fragment) bool {
    return std.mem.lessThan(u8, x.name, y.name);
}

fn isFence(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "```");
}

/// A version heading's text: numbers joined by dots, at least two (`0.1.1512`), as the release workflow spells
/// a release; the same as the install page check's.
fn isVersion(text: []const u8) bool {
    var parts = std.mem.splitScalar(u8, text, '.');
    var n: usize = 0;
    while (parts.next()) |part| : (n += 1) {
        if (part.len == 0) return false;
        for (part) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return n >= 2;
}

/// `in.changelog` with the new section, headed `## <heading>`, placed before its first release heading.
pub fn assemble(a: Allocator, why: *[]const u8, in: Inputs, heading: []const u8) Error![]u8 {
    var first: ?struct { offset: usize, line: usize, text: []const u8 } = null;
    var fenced = false;
    var offset: usize = 0;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, in.changelog, '\n');
    while (it.next()) |line| : (offset += line.len + 1) {
        n += 1;
        if (isFence(line)) fenced = !fenced;
        if (fenced or !std.mem.startsWith(u8, line, "## ")) continue;
        const text = std.mem.trimRight(u8, line["## ".len..], " ");
        if (std.ascii.eqlIgnoreCase(text, "Unreleased")) {
            return refuse(a, why, "{s}:{d}: a `## Unreleased` heading: entries go in {s} as files, and the release writes its section", .{ in.changelog_path, n, in.fragments_dir });
        }
        if (first == null) first = .{ .offset = offset, .line = n, .text = text };
    }
    const at = first orelse return refuse(a, why, "{s}: no release heading (`## <version>`) to put the new section before", .{in.changelog_path});
    if (!isVersion(at.text)) {
        return refuse(a, why, "{s}:{d}: the first second-level heading is `## {s}`, not a release heading `## <version>` (numbers joined by dots)", .{ in.changelog_path, at.line, at.text });
    }

    const fragments = try a.dupe(Fragment, in.fragments);
    std.mem.sort(Fragment, fragments, {}, nameLess);
    var bullets = std.ArrayList([]const u8).empty;
    for (fragments) |f| try bullets.append(a, try body(a, why, in.fragments_dir, f));

    var out = std.ArrayList(u8).empty;
    const before = in.changelog[0..at.offset];
    try out.appendSlice(a, before);
    // a heading starts a line, so `before` is empty or ends with a line feed
    if (before.len != 0 and !std.mem.endsWith(u8, before, "\n\n")) try out.append(a, '\n');
    try out.appendSlice(a, try std.fmt.allocPrint(a, "## {s}\n\n", .{heading}));
    try out.appendSlice(a, if (bullets.items.len == 0) no_entries else try std.mem.join(a, "\n", bullets.items));
    try out.appendSlice(a, "\n\n");
    try out.appendSlice(a, in.changelog[at.offset..]);
    return out.toOwnedSlice(a);
}

/// `text` with every heading one level down (`# x` is `## x`), the lines of a fenced block left as they are; a
/// level 6 heading has no level below it and is refused, naming `path` and the line.
pub fn nest(a: Allocator, why: *[]const u8, path: []const u8, text: []const u8) Error![]u8 {
    var out = std.ArrayList(u8).empty;
    var fenced = false;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (n != 0) try out.append(a, '\n');
        n += 1;
        if (isFence(line)) fenced = !fenced;
        var level: usize = 0;
        while (level < line.len and line[level] == '#') level += 1;
        const heading = !fenced and level != 0 and level <= 6 and (level == line.len or line[level] == ' ');
        if (heading and level == 6) return refuse(a, why, "{s}:{d}: a level 6 heading cannot go one level down", .{ path, n });
        if (heading) try out.append(a, '#');
        try out.appendSlice(a, line);
    }
    return out.toOwnedSlice(a);
}

/// The prefix of a link to the repository's files on `main`, before `blob/main/` or `tree/main/`.
pub const repository = "https://github.com/komira-ai/komira/";

/// The branch part of the two link forms `pin` rewrites, after `repository`.
const branch_links = [_][]const u8{ "blob/main/", "tree/main/" };

fn isCommit(commit: []const u8) bool {
    if (commit.len != 40) return false;
    for (commit) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

/// `text` with every link to a file or directory of the repository on `main` (`<repository>blob/main/...`,
/// `<repository>tree/main/...`) pinned to `commit`, the 40 lower-case hexadecimal digits of the commit the
/// build is stamped with (`-c komira.package_commit`); `commit` in any other spelling is refused. Every other
/// byte is kept, a link inside a fenced block too.
pub fn pin(a: Allocator, why: *[]const u8, text: []const u8, commit: []const u8) Error![]u8 {
    if (!isCommit(commit)) return refuse(a, why, "the commit `{s}` is not 40 lower-case hexadecimal digits", .{commit});
    var out = std.ArrayList(u8).empty;
    var rest = text;
    while (std.mem.indexOf(u8, rest, repository)) |at| {
        const after = rest[at + repository.len ..];
        try out.appendSlice(a, rest[0 .. at + repository.len]);
        rest = after;
        for (branch_links) |link| {
            if (!std.mem.startsWith(u8, after, link)) continue;
            // `blob/` or `tree/`, the commit, and the path after `main/`
            try out.appendSlice(a, link[0.."blob/".len]);
            try out.appendSlice(a, commit);
            try out.append(a, '/');
            rest = after[link.len..];
            break;
        }
    }
    try out.appendSlice(a, rest);
    return out.toOwnedSlice(a);
}

/// Where the description's links point: `main` for an unstamped build, or the commit a stamped build is
/// stamped with.
pub const Links = union(enum) { main, commit: []const u8 };

/// Where the description of a build stamped `stamp` (as `headingOf` reads it) links to, given the commit the
/// build is stamped with (`-c komira.package_commit`) or null: `main` for an unstamped build, the commit for a
/// stamped one. A stamped build with no commit, or an unstamped one with a commit, is refused: the wheel's
/// stamp is all of its parts or none (tools/build/package/wheel/stamp.zig).
pub fn linksOf(a: Allocator, why: *[]const u8, stamp: []const u8, commit: ?[]const u8) Error!Links {
    const stamped = !std.mem.eql(u8, try headingOf(a, why, stamp), "Unreleased");
    if (commit) |c| {
        if (!stamped) return refuse(a, why, "the commit `{s}` is given for an unstamped build, whose description links to `main`: a commit needs a stamp", .{c});
        if (!isCommit(c)) return refuse(a, why, "the commit `{s}` is not 40 lower-case hexadecimal digits", .{c});
        return .{ .commit = c };
    }
    if (stamped) return refuse(a, why, "the stamp `{s}` is given with no commit: a stamped description pins its links to the commit the wheel is built from", .{stamp});
    return .main;
}

/// The wheel's description: `readme`, a blank line, then the assembled changelog `changelog` (named `path` in
/// refusals) with its headings one level down; with `links` a commit, every link to the repository's `main`
/// pinned to it (`pin`).
pub fn description(a: Allocator, why: *[]const u8, readme: []const u8, path: []const u8, changelog: []const u8, links: Links) Error![]u8 {
    const nested = try nest(a, why, path, changelog);
    const head = std.mem.trimRight(u8, readme, "\n");
    const text = try std.fmt.allocPrint(a, "{s}\n\n{s}", .{ head, nested });
    return switch (links) {
        .main => text,
        .commit => |commit| pin(a, why, text, commit),
    };
}
