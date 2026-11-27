//! npm_set.json, the record of //release:npm_packages: every npm package of one release, in the order they are
//! published, each with its name, version, file, SHA-256 and the sha512 `integrity` npm reports for it.
//!
//!   {
//!     "main": "@komira-ai/komira",
//!     "version": "0.1.7",
//!     "packages": [
//!       {"name": "@komira-ai/komira-linux-x64-gnu", "version": "0.1.7", "file": "komira-ai-komira-linux-x64-gnu-0.1.7.tgz", "sha256": "<64 hex>", "integrity": "sha512-<base64>"},
//!       {"name": "@komira-ai/komira", "version": "0.1.7", "file": "komira-ai-komira-0.1.7.tgz", "sha256": "<64 hex>", "integrity": "sha512-<base64>"}
//!     ]
//!   }
//!
//! The platform packages come first, sorted by name, and the main package last: the main package names the
//! platform packages, so it is published only after them. One version for every package (the stamp's,
//! `0.1.<N>`, or `0.0.0` unstamped), and each file is the name `npm pack` gives the package at that version.
//! The main package names exactly the set's platform packages as its optional dependencies
//! (`checkOptional`): one it names that the set does not hold would be a name npm finds nothing for, and
//! one the set holds that it does not name would never be installed. `build` makes the set from the
//! tarballs, `render` writes it, `parse` reads it back and refuses anything
//! `render` would not have written (a reader ignores a key it does not know), and `verifyDir` holds a directory
//! of tarballs to it.
const std = @import("std");
const common = @import("common.zig");

const Allocator = common.Allocator;
const Error = common.Error;
const refuse = common.refuse;

/// The scope every package of the set is published under.
pub const scope = "@komira-ai/";

/// The name of the record in the set's directory.
pub const file_name = "npm_set.json";

/// An unstamped package's version, which is never published.
pub const unstamped = "0.0.0";

pub const Package = struct {
    name: []const u8,
    version: []const u8,
    file: []const u8,
    sha256: []const u8,
    integrity: []const u8,
};

pub const Set = struct {
    main: []const u8,
    version: []const u8,
    /// In publish order: the platform packages by name, then the main package.
    packages: []const Package,

    pub fn stamped(self: Set) bool {
        return !std.mem.eql(u8, self.version, unstamped);
    }

    pub fn find(self: Set, name: []const u8) ?Package {
        for (self.packages) |p| if (std.mem.eql(u8, p.name, name)) return p;
        return null;
    }
};

/// A package name of the set: the scope and a name of lowercase letters, digits and inner hyphens.
pub fn isName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, scope)) return false;
    const rest = name[scope.len..];
    if (rest.len == 0 or rest[0] == '-' or rest[rest.len - 1] == '-') return false;
    for (rest) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    }
    return true;
}

/// A version of three dot-separated numbers, none with a leading zero.
pub fn isVersion(v: []const u8) bool {
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, v, '.');
    while (it.next()) |p| {
        parts += 1;
        if (p.len == 0 or (p.len > 1 and p[0] == '0')) return false;
        for (p) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return parts == 3;
}

/// The file name `npm pack` gives `name` at `version`: the name without its `@`, `/` as `-`, then
/// `-<version>.tgz`.
pub fn tarballName(a: Allocator, name: []const u8, version: []const u8) Error![]const u8 {
    const bare = if (std.mem.startsWith(u8, name, "@")) name[1..] else name;
    const dashed = try a.dupe(u8, bare);
    std.mem.replaceScalar(u8, dashed, '/', '-');
    return std.fmt.allocPrint(a, "{s}-{s}.tgz", .{ dashed, version });
}

/// The version a tarball's file name holds for package `name`, or null when it is not `name`'s file.
pub fn versionOfFile(a: Allocator, name: []const u8, file: []const u8) Error!?[]const u8 {
    const prefix = try tarballName(a, name, "");
    // `prefix` ends in "-.tgz"; the file is the part before ".tgz", the version, then ".tgz".
    const head = prefix[0 .. prefix.len - ".tgz".len];
    if (!std.mem.startsWith(u8, file, head) or !std.mem.endsWith(u8, file, ".tgz")) return null;
    if (file.len <= head.len + ".tgz".len) return null;
    const version = file[head.len .. file.len - ".tgz".len];
    if (!isVersion(version)) return null;
    return version;
}

fn isLowerHex(s: []const u8, len: usize) bool {
    if (s.len != len) return false;
    for (s) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

fn isIntegrity(s: []const u8) bool {
    if (s.len != common.integrity_len or !std.mem.startsWith(u8, s, "sha512-")) return false;
    const b64 = s["sha512-".len..];
    const n = std.base64.standard.Decoder.calcSizeForSlice(b64) catch return false;
    if (n != 64) return false;
    var digest: [64]u8 = undefined;
    std.base64.standard.Decoder.decode(&digest, b64) catch return false;
    const again = integrityOfDigest(digest);
    return std.mem.eql(u8, &again, s);
}

fn integrityOfDigest(digest: [64]u8) [common.integrity_len]u8 {
    var out: [common.integrity_len]u8 = undefined;
    @memcpy(out[0..7], "sha512-");
    _ = std.base64.standard.Encoder.encode(out[7..], &digest);
    return out;
}

/// One tarball `build` is given: the package's name and the tarball's path and bytes.
pub const Input = struct {
    name: []const u8,
    path: []const u8,
    bytes: []const u8,
};

fn lessByName(_: void, x: Package, y: Package) bool {
    return std.mem.order(u8, x.name, y.name) == .lt;
}

/// The set of `inputs`, whose main package is `main`; refused unless every name is a name of the scope and
/// given once, `main` is one of them, each file is its package's at one version for all, and that version is
/// stamped when `require_stamped`.
pub fn build(a: Allocator, why: *[]const u8, main: []const u8, inputs: []const Input, require_stamped: bool) Error!Set {
    if (inputs.len == 0) return refuse(a, why, "no package: a set holds the main package at least", .{});
    var platforms = std.ArrayList(Package).empty;
    var main_pkg: ?Package = null;
    var version: ?[]const u8 = null;
    for (inputs, 0..) |in, i| {
        if (!isName(in.name)) return refuse(a, why, "\"{s}\" is not a package name of {s}", .{ in.name, scope });
        for (inputs[0..i]) |prev| {
            if (std.mem.eql(u8, prev.name, in.name)) return refuse(a, why, "{s} is given twice", .{in.name});
        }
        const file = std.fs.path.basename(in.path);
        const v = (try versionOfFile(a, in.name, file)) orelse
            return refuse(a, why, "{s} is not a file name npm pack gives {s} (want {s})", .{ file, in.name, try tarballName(a, in.name, "<version>") });
        if (version) |have| {
            if (!std.mem.eql(u8, have, v)) return refuse(a, why, "{s} is at {s} and {s} at {s}: every package of a set has one version", .{ inputs[0].name, have, in.name, v });
        } else {
            version = v;
        }
        const pkg = Package{
            .name = in.name,
            .version = v,
            .file = file,
            .sha256 = try a.dupe(u8, &common.sha256Hex(in.bytes)),
            .integrity = try a.dupe(u8, &common.integrity(in.bytes)),
        };
        if (std.mem.eql(u8, in.name, main)) main_pkg = pkg else try platforms.append(a, pkg);
    }
    const m = main_pkg orelse return refuse(a, why, "the main package {s} is not one of the packages given", .{main});
    if (platforms.items.len == 0) return refuse(a, why, "the main package {s} is the only package: a set holds a platform package at least", .{main});
    if (require_stamped and std.mem.eql(u8, version.?, unstamped)) return refuse(a, why, "the packages are unstamped ({s}): a release set is stamped", .{unstamped});
    std.mem.sort(Package, platforms.items, {}, lessByName);
    try platforms.append(a, m);
    return .{ .main = main, .version = version.?, .packages = platforms.items };
}

/// `optional` (the main package's optional dependencies, comma-separated, as its rule names them) is
/// exactly the platform packages of `set`, each named once.
pub fn checkOptional(a: Allocator, why: *[]const u8, set: Set, optional: []const u8) Error!void {
    var names = std.ArrayList([]const u8).empty;
    if (optional.len > 0) {
        var it = std.mem.splitScalar(u8, optional, ',');
        while (it.next()) |n| try names.append(a, n);
    }
    for (names.items, 0..) |n, i| {
        for (names.items[0..i]) |prev| {
            if (std.mem.eql(u8, prev, n)) return refuse(a, why, "the main package {s} names the optional dependency {s} twice", .{ set.main, n });
        }
        if (std.mem.eql(u8, n, set.main) or set.find(n) == null)
            return refuse(a, why, "the main package {s} names {s} as an optional dependency, which is no platform package of the set: npm would find nothing to install for it", .{ set.main, n });
    }
    for (set.packages[0 .. set.packages.len - 1]) |p| {
        var named = false;
        for (names.items) |n| named = named or std.mem.eql(u8, n, p.name);
        if (!named) return refuse(a, why, "the platform package {s} is not an optional dependency of the main package {s}: npm would never install it", .{ p.name, set.main });
    }
}

/// The text of npm_set.json for `set`, which `build` or `parse` made (so no value needs escaping).
pub fn render(a: Allocator, set: Set) Error![]const u8 {
    var w = std.Io.Writer.Allocating.init(a);
    const out = &w.writer;
    out.print("{{\n  \"main\": \"{s}\",\n  \"version\": \"{s}\",\n  \"packages\": [\n", .{ set.main, set.version }) catch return error.OutOfMemory;
    for (set.packages, 0..) |p, i| {
        out.print(
            "    {{\"name\": \"{s}\", \"version\": \"{s}\", \"file\": \"{s}\", \"sha256\": \"{s}\", \"integrity\": \"{s}\"}}{s}\n",
            .{ p.name, p.version, p.file, p.sha256, p.integrity, if (i + 1 == set.packages.len) "" else "," },
        ) catch return error.OutOfMemory;
    }
    out.writeAll("  ]\n}\n") catch return error.OutOfMemory;
    return w.written();
}

const Raw = struct {
    main: []const u8,
    version: []const u8,
    packages: []const Package,
};

/// The set `text` holds; refused (naming `path`) unless it is a set `build` could have made: the fields
/// above, each package a name of the scope at the set's version in its own file with a SHA-256 and an
/// integrity of the right form, no name twice, the platform packages sorted by name and the main package
/// last.
pub fn parse(a: Allocator, why: *[]const u8, path: []const u8, text: []const u8) Error!Set {
    const raw = std.json.parseFromSliceLeaky(Raw, a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return refuse(a, why, "{s} is not an npm set ({s}): it is an object of main, version and packages, each package an object of name, version, file, sha256 and integrity", .{ path, @errorName(e) }),
    };
    if (!isVersion(raw.version)) return refuse(a, why, "{s}: \"{s}\" is not a version", .{ path, raw.version });
    if (!isName(raw.main)) return refuse(a, why, "{s}: main \"{s}\" is not a package name of {s}", .{ path, raw.main, scope });
    if (raw.packages.len < 2) return refuse(a, why, "{s} holds {d} package(s): a set holds the main package and a platform package at least", .{ path, raw.packages.len });
    for (raw.packages, 0..) |p, i| {
        if (!isName(p.name)) return refuse(a, why, "{s}: \"{s}\" is not a package name of {s}", .{ path, p.name, scope });
        if (!std.mem.eql(u8, p.version, raw.version)) return refuse(a, why, "{s}: {s} is at {s}, not the set's {s}", .{ path, p.name, p.version, raw.version });
        const want = try tarballName(a, p.name, p.version);
        if (!std.mem.eql(u8, p.file, want)) return refuse(a, why, "{s}: the file of {s} is {s}, not {s}", .{ path, p.name, p.file, want });
        if (!isLowerHex(p.sha256, 64)) return refuse(a, why, "{s}: the sha256 of {s} is not 64 lowercase hex characters", .{ path, p.name });
        if (!isIntegrity(p.integrity)) return refuse(a, why, "{s}: the integrity of {s} is not sha512- and the base64 of 64 bytes", .{ path, p.name });
        for (raw.packages[0..i]) |prev| {
            if (std.mem.eql(u8, prev.name, p.name)) return refuse(a, why, "{s}: {s} is listed twice", .{ path, p.name });
        }
        const last = i + 1 == raw.packages.len;
        const is_main = std.mem.eql(u8, p.name, raw.main);
        if (last and !is_main) return refuse(a, why, "{s}: the last package is {s}, not the main package {s}: the main package is published last", .{ path, p.name, raw.main });
        if (!last and is_main) return refuse(a, why, "{s}: the main package {s} is not last: it is published after every platform package", .{ path, p.name });
        if (!last and i > 0 and std.mem.order(u8, raw.packages[i - 1].name, p.name) != .lt)
            return refuse(a, why, "{s}: the platform packages are not sorted by name ({s} follows {s})", .{ path, p.name, raw.packages[i - 1].name });
    }
    return .{ .main = raw.main, .version = raw.version, .packages = raw.packages };
}

/// The set of the file at `path`.
pub fn load(a: Allocator, why: *[]const u8, path: []const u8) Error!Set {
    return parse(a, why, path, try common.readFile(a, why, "the set", path));
}

/// `dir` holds exactly the set's tarballs and npm_set.json, and each tarball is the bytes the set records
/// (its SHA-256 and its integrity).
pub fn verifyDir(a: Allocator, why: *[]const u8, set: Set, dir: []const u8) Error!void {
    var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch |e|
        return refuse(a, why, "cannot open the set's directory {s}: {s}", .{ dir, @errorName(e) });
    defer d.close();
    var it = d.iterate();
    while (it.next() catch |e| return refuse(a, why, "cannot list {s}: {s}", .{ dir, @errorName(e) })) |entry| {
        var known = std.mem.eql(u8, entry.name, file_name);
        for (set.packages) |p| {
            if (std.mem.eql(u8, entry.name, p.file)) known = true;
        }
        if (!known) return refuse(a, why, "{s} holds {s}, which is no file of the set", .{ dir, entry.name });
    }
    for (set.packages) |p| {
        const path = try std.fs.path.join(a, &.{ dir, p.file });
        const bytes = try common.readFile(a, why, "the tarball", path);
        const sha = common.sha256Hex(bytes);
        if (!std.mem.eql(u8, &sha, p.sha256)) return refuse(a, why, "{s} has the sha256 {s}, not the set's {s}", .{ path, &sha, p.sha256 });
        const sri = common.integrity(bytes);
        if (!std.mem.eql(u8, &sri, p.integrity)) return refuse(a, why, "{s} has the integrity {s}, not the set's {s}", .{ path, &sri, p.integrity });
    }
}
