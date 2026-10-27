//! The plan that moves one komira Mojo library (`src/<name>`, a `mojo_library`) onto buildrules'
//! `mojo_package`, as `recipe` steps 1 to 3 and 5 of the hand migrations do it. `plan` reads the
//! repository as a list of files (`File`) and returns what to move and write; it touches nothing,
//! so the dry run and the tests call it directly.
//!
//! It refuses, with a message that names the file and the fact, rather than guess:
//!  - an import that maps to no package of this repository, or to a package still on `mojo_library`;
//!  - a native library: C sources, a `native*` or `dlopen` attribute, a dependency whose manifest
//!    declares natives;
//!  - a BUCK file it cannot read as data (variables, comprehensions, operators, triple-quoted
//!    strings) or reads as more than the recipe covers (other rules, other attributes, other loads);
//!  - `deps` or `test_deps` that disagree with the imports, a `test_srcs` list that is not the
//!    `tests/test_*.mojo` files, a `test_data` with no `--test-layout`, a test-only import without
//!    `--dev-dependencies`, a package that has a `src/` or `generated/` directory already.
//!
//! What it leaves to the farm (`Plan.farm`): `buildrules.mojo.bzl` and `buildrules.mojo.lock.bzl`
//! (`buildrules mojo sync`), `coverage_floor.txt` (a measure) and the regeneration of the `ci/targets`
//! rows (generated, so the tool does not edit them).
const std = @import("std");
const sl = @import("starlark.zig");
const imp = @import("mojo_imports.zig");
const emit = @import("emit.zig");

const Allocator = std.mem.Allocator;
pub const Error = sl.Error;
pub const Ctx = sl.Ctx;

/// A file of the repository, by path from its root. `text` is null for a file not read (binary).
pub const File = struct { path: []const u8, text: ?[]const u8 = null };

pub const Options = struct {
    package: []const u8,
    description: []const u8,
    mopm: []const u8 = "0.0.73",
    /// `installed` or `default`; required when the old BUCK file has `test_data` or `test_env`.
    test_layout: ?[]const u8 = null,
    dev_dependencies: bool = false,
};

pub const Move = struct { from: []const u8, to: []const u8 };

/// A file the migration writes. `shown` is what a dry run prints: the whole text of a new file,
/// the inserted lines (`+ ...`) of an edited shared file.
pub const Write = struct { path: []const u8, text: []const u8, shown: []const u8, replaces: bool };

pub const Plan = struct {
    moves: []const Move,
    writes: []const Write,
    notes: []const []const u8,
    farm: []const []const u8,
};

const Repo = struct {
    files: []const File,

    fn text(self: Repo, path: []const u8) ?[]const u8 {
        for (self.files) |f| if (std.mem.eql(u8, f.path, path)) return f.text;
        return null;
    }

    fn has(self: Repo, path: []const u8) bool {
        for (self.files) |f| if (std.mem.eql(u8, f.path, path)) return true;
        return false;
    }

    fn hasPrefix(self: Repo, prefix: []const u8) bool {
        for (self.files) |f| if (std.mem.startsWith(u8, f.path, prefix)) return true;
        return false;
    }
};

fn fmt(c: *Ctx, comptime f: []const u8, args: anytype) Error![]u8 {
    return std.fmt.allocPrint(c.a, f, args);
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn contains(items: []const []const u8, s: []const u8) bool {
    for (items) |i| if (std.mem.eql(u8, i, s)) return true;
    return false;
}

/// `items` sorted, without duplicates.
fn uniqueSorted(a: Allocator, items: []const []const u8) ![][]const u8 {
    const sorted = try a.dupe([]const u8, items);
    std.mem.sort([]const u8, sorted, {}, lessStr);
    var out = std.ArrayList([]const u8).empty;
    for (sorted) |s| {
        if (out.items.len > 0 and std.mem.eql(u8, out.items[out.items.len - 1], s)) continue;
        try out.append(a, s);
    }
    return out.toOwnedSlice(a);
}

fn validName(n: []const u8) bool {
    if (n.len == 0) return false;
    for (n) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_')) return false;
    return true;
}

fn isNativeExt(path: []const u8) bool {
    const exts = [_][]const u8{ ".c", ".h", ".cc", ".cpp", ".cxx", ".hpp", ".s", ".S", ".cu", ".m", ".mm", ".a", ".so", ".dylib", ".o" };
    for (exts) |e| if (std.mem.endsWith(u8, path, e)) return true;
    return false;
}

/// The `name` of a label `//path:name`.
fn labelName(c: *Ctx, label: []const u8) Error![]const u8 {
    const colon = std.mem.lastIndexOfScalar(u8, label, ':') orelse return c.refuse("BUCK: the label '{s}' has no ':name'", .{label});
    if (!std.mem.startsWith(u8, label, "//")) return c.refuse("BUCK: the label '{s}' is not an absolute '//path:name' label of this repository", .{label});
    return label[colon + 1 ..];
}

fn strList(c: *Ctx, attr: []const u8, v: sl.Value) Error![]const []const u8 {
    switch (v.kind) {
        .list => |items| {
            const out = try c.a.alloc([]const u8, items.len);
            for (items, out) |it, *o| switch (it.kind) {
                .str => |s| o.* = s,
                else => return c.refuse("BUCK: '{s}' holds something that is not a string", .{attr}),
            };
            return out;
        },
        else => return c.refuse("BUCK: '{s}' is not a list of strings", .{attr}),
    }
}

fn isStandardGlob(v: sl.Value) bool {
    const call = switch (v.kind) {
        .call => |x| x,
        else => return false,
    };
    if (!std.mem.eql(u8, call.func, "glob") or call.args.len != 2) return false;
    const inc = call.args[0];
    const exc = call.kwarg("exclude") orelse return false;
    if (inc.name != null) return false;
    return oneString(inc.value, "**/*.mojo") and oneString(exc, "tests/**/*.mojo");
}

fn oneString(v: sl.Value, want: []const u8) bool {
    switch (v.kind) {
        .list => |items| {
            if (items.len != 1) return false;
            return switch (items[0].kind) {
                .str => |s| std.mem.eql(u8, s, want),
                else => false,
            };
        },
        else => return false,
    }
}

const Manifest = struct { version: []const u8, deps: []const []const u8, native: bool };

/// What the migration needs from another package's `mopm.toml`: its version, the names under
/// `[dependencies]` and whether it declares natives.
fn readManifest(c: *Ctx, who: []const u8, toml: []const u8) Error!Manifest {
    var version: ?[]const u8 = null;
    var deps = std.ArrayList([]const u8).empty;
    var native = false;
    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, toml, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            section = std.mem.trim(u8, line, "[] \t");
            if (std.mem.startsWith(u8, section, "native")) native = true;
            if (std.mem.startsWith(u8, section, "dependencies.")) try deps.append(c.a, section["dependencies.".len..]);
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (std.mem.eql(u8, section, "package") and std.mem.eql(u8, key, "version")) {
            const val = std.mem.trim(u8, line[eq + 1 ..], " \t\"");
            version = val;
        } else if (std.mem.eql(u8, section, "dependencies")) {
            try deps.append(c.a, key);
        }
    }
    const sorted = try uniqueSorted(c.a, deps.items);
    return .{ .version = version orelse return c.refuse("{s}/mopm.toml has no [package] version", .{who}), .deps = sorted, .native = native };
}

fn makeDep(c: *Ctx, name: []const u8, version: []const u8) Error!emit.Dep {
    var it = std.mem.splitScalar(u8, version, '.');
    const maj = it.next() orelse "";
    const min = it.next() orelse "";
    const minor = std.fmt.parseInt(u32, min, 10) catch return c.refuse("src/{s}/mopm.toml: version '{s}' is not MAJOR.MINOR.PATCH", .{ name, version });
    _ = std.fmt.parseInt(u32, maj, 10) catch return c.refuse("src/{s}/mopm.toml: version '{s}' is not MAJOR.MINOR.PATCH", .{ name, version });
    return .{
        .name = name,
        .short = try fmt(c, "{s}.{s}", .{ maj, min }),
        .requirement = try fmt(c, "mojo-{s} >={s}.{s},<{s}.{d}", .{ name, maj, min, maj, minor + 1 }),
    };
}

const Seen = struct { module: []const u8, file: []const u8 };

fn firstFile(seen: []const Seen, module: []const u8) []const u8 {
    for (seen) |s| if (std.mem.eql(u8, s.module, module)) return s.file;
    return "";
}

// ---- the shared rows --------------------------------------------------------------------------

const Region = struct { open: []const u8, close: []const u8 };
const KeyFn = *const fn ([]const u8) ?[]const u8;

/// `    "key": ...` -> key.
fn keyQuoted(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "    \"")) return null;
    const end = std.mem.indexOfScalarPos(u8, line, 5, '"') orelse return null;
    if (!std.mem.startsWith(u8, line[end..], "\": ")) return null;
    return line[5..end];
}

/// `    "key",` -> key.
fn keyTarget(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "    \"") or !std.mem.endsWith(u8, line, "\",")) return null;
    return line[5 .. line.len - 2];
}

/// `load("//src/key:buildrules.mojo.lock.bzl", ...)` -> key.
fn keyLoad(line: []const u8) ?[]const u8 {
    const pre = "load(\"//src/";
    if (!std.mem.startsWith(u8, line, pre)) return null;
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    if (!std.mem.containsAtLeast(u8, line, 1, "buildrules.mojo.lock.bzl")) return null;
    return line[pre.len..colon];
}

/// Inserts `new_line` among the entries of `src` that `key_fn` reads, keeping their byte order.
/// `region` limits the entries to a block. A key already present is a refusal.
fn insertSorted(c: *Ctx, src: []const u8, region: ?Region, key_fn: KeyFn, new_line: []const u8, new_key: []const u8, file: []const u8) Error![]const u8 {
    var lines = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |l| try lines.append(c.a, l);
    var in_region = region == null;
    var insert_at: ?usize = null;
    var last_entry: ?usize = null;
    var close_idx: ?usize = null;
    for (lines.items, 0..) |ln, i| {
        if (region) |r| {
            if (!in_region) {
                if (std.mem.startsWith(u8, ln, r.open)) in_region = true;
                continue;
            }
            if (std.mem.eql(u8, ln, r.close)) {
                close_idx = i;
                break;
            }
        }
        if (key_fn(ln)) |k| {
            if (std.mem.eql(u8, k, new_key)) return c.refuse("{s}: '{s}' is already listed", .{ file, new_key });
            if (insert_at == null and std.mem.lessThan(u8, new_key, k)) insert_at = i;
            last_entry = i;
        }
    }
    if (region != null and !in_region) return c.refuse("{s}: the block '{s}' was not found", .{ file, region.?.open });
    const at = insert_at orelse if (last_entry) |l| l + 1 else close_idx orelse return c.refuse("{s}: no place to insert '{s}'", .{ file, new_key });
    var out = std.ArrayList([]const u8).empty;
    try out.appendSlice(c.a, lines.items[0..at]);
    try out.append(c.a, new_line);
    try out.appendSlice(c.a, lines.items[at..]);
    return std.mem.join(c.a, "\n", out.items);
}

fn requireText(c: *Ctx, repo: Repo, path: []const u8) Error![]const u8 {
    return repo.text(path) orelse c.refuse("{s} was not read: the shared rows cannot be updated", .{path});
}

/// A BUCK dep label's alias form (`//tools/build/mojo/runtime_paths:komira_runtime_paths`) is
/// written as the package's own label in a binary kept from the old file.
fn fixBinary(c: *Ctx, repo: Repo, buck: []const u8, st: sl.Stmt) Error![]const u8 {
    const deps = st.call.kwarg("deps") orelse return buck[st.start..st.end];
    const items = switch (deps.kind) {
        .list => |l| l,
        else => return buck[st.start..st.end],
    };
    var out = std.ArrayList(u8).empty;
    var pos = st.start;
    for (items) |it| {
        const label = switch (it.kind) {
            .str => |s| s,
            else => continue,
        };
        if (!std.mem.startsWith(u8, label, "//")) continue;
        const colon = std.mem.lastIndexOfScalar(u8, label, ':') orelse continue;
        const name = label[colon + 1 ..];
        const own = try fmt(c, "//src/{s}", .{name});
        if (std.mem.eql(u8, label[0..colon], own)) continue;
        const sib_buck = repo.text(try fmt(c, "src/{s}/BUCK", .{name})) orelse continue;
        if (!repo.has(try fmt(c, "src/{s}/mopm.toml", .{name})) or !std.mem.containsAtLeast(u8, sib_buck, 1, "mojo_package(")) continue;
        try out.appendSlice(c.a, buck[pos..it.start]);
        try out.appendSlice(c.a, try fmt(c, "\"//src/{s}:{s}\"", .{ name, name }));
        pos = it.end;
    }
    try out.appendSlice(c.a, buck[pos..st.end]);
    return out.toOwnedSlice(c.a);
}

/// Whether a comment says, in so many words, that the package has no dependencies.
fn claimsNoDependencies(comment: []const u8) bool {
    const phrases = [_][]const u8{ "no dependenc", "no deps", "no dependency", "dependency-free", "dependency free", "without dependenc", "zero dependenc", "no other dependenc", "no external dependenc" };
    var buf: [4096]u8 = undefined;
    const lower = std.ascii.lowerString(&buf, comment[0..@min(comment.len, buf.len)]);
    for (phrases) |ph| if (std.mem.indexOf(u8, lower, ph) != null) return true;
    return false;
}

pub fn plan(c: *Ctx, files: []const File, o: Options) Error!Plan {
    const repo = Repo{ .files = files };
    const n = o.package;
    if (!validName(n)) return c.refuse("'{s}' is not a package name (lower-case letters, digits and '_')", .{n});
    if (o.description.len == 0) return c.refuse("--description is required: it is the one-sentence description in mopm.toml, and nothing in the old files states it", .{});
    if (std.mem.indexOfAny(u8, o.description, "\"\\\n") != null) return c.refuse("--description must not hold a quote, a backslash or a newline", .{});
    const pkg = try fmt(c, "src/{s}/", .{n});
    const buck_path = try fmt(c, "{s}BUCK", .{pkg});
    const buck = repo.text(buck_path) orelse return c.refuse("{s} not found: src/{s} is not a package of this repository", .{ buck_path, n });
    if (repo.has(try fmt(c, "{s}mopm.toml", .{pkg}))) return c.refuse("src/{s} has a mopm.toml: it is migrated already", .{n});
    if (repo.hasPrefix(try fmt(c, "{s}src/", .{pkg}))) return c.refuse("src/{s}/src exists: the library would move into it", .{n});
    if (repo.hasPrefix(try fmt(c, "{s}generated/", .{pkg}))) return c.refuse("src/{s}/generated exists: generated sources are not a plain migration (recipe step 0)", .{n});
    for (files) |f| {
        if (std.mem.startsWith(u8, f.path, pkg) and isNativeExt(f.path)) {
            return c.refuse("{s}: a native source or library; a package with native code is not a plain migration (recipe step 0)", .{f.path});
        }
    }
    const readme_path = try fmt(c, "{s}README.md", .{pkg});
    const readme = repo.text(readme_path) orelse return c.refuse("{s} not found: the adopted rule gates on the README", .{readme_path});
    if (std.mem.containsAtLeast(u8, readme, 1, "\n## Build files")) return c.refuse("{s} has a 'Build files' section already", .{readme_path});

    // ---- the old BUCK file
    const stmts = sl.parse(c, buck) catch |e| return if (e == error.Refused) c.refuse("{s}: {s}", .{ buck_path, c.why }) else e;
    var lib: ?sl.Stmt = null;
    var bins = std.ArrayList(sl.Stmt).empty;
    for (stmts) |st| {
        const f = st.call.func;
        if (std.mem.eql(u8, f, "load")) {
            if (st.call.args.len < 2) return c.refuse("{s}: a load with no symbols (line {d})", .{ buck_path, st.line });
            const label = switch (st.call.args[0].value.kind) {
                .str => |s| s,
                else => return c.refuse("{s}: load (line {d}) does not start with a label string", .{ buck_path, st.line }),
            };
            if (!std.mem.eql(u8, label, "@komira//tools/build/mojo:defs.bzl")) return c.refuse("{s}: line {d} loads {s}; the recipe covers only the mojo rules of @komira//tools/build/mojo:defs.bzl", .{ buck_path, st.line, label });
            for (st.call.args[1..]) |arg| {
                const sym = switch (arg.value.kind) {
                    .str => |s| s,
                    else => return c.refuse("{s}: load symbol on line {d} is not a string", .{ buck_path, st.line }),
                };
                if (!std.mem.eql(u8, sym, "mojo_library") and !std.mem.eql(u8, sym, "mojo_binary")) return c.refuse("{s}: line {d} loads {s}; the recipe covers mojo_library and mojo_binary", .{ buck_path, st.line, sym });
            }
        } else if (std.mem.eql(u8, f, "mojo_library")) {
            if (lib != null) return c.refuse("{s}: a second mojo_library (line {d}); a package has one library", .{ buck_path, st.line });
            lib = st;
        } else if (std.mem.eql(u8, f, "mojo_binary")) {
            try bins.append(c.a, st);
        } else if (std.mem.indexOf(u8, f, "native") != null) {
            return c.refuse("{s}: line {d} is {s}: a native library; not a plain migration (recipe step 0)", .{ buck_path, st.line, f });
        } else {
            return c.refuse("{s}: line {d} is a call to {s}; the recipe covers only mojo_library and mojo_binary", .{ buck_path, st.line, f });
        }
    }
    const ml = lib orelse return c.refuse("{s} has no mojo_library: the package is not on the old rule", .{buck_path});

    var buck_deps: []const []const u8 = &.{};
    var buck_test_deps: []const []const u8 = &.{};
    var test_srcs: []const []const u8 = &.{};
    var extras = std.ArrayList(emit.Extra).empty;
    var data: ?sl.Value = null;
    var env: ?sl.Value = null;
    for (ml.call.args) |arg| {
        const an = arg.name orelse return c.refuse("{s}: mojo_library has a positional argument", .{buck_path});
        const v = arg.value;
        if (std.mem.eql(u8, an, "name")) {
            switch (v.kind) {
                .str => |s| if (!std.mem.eql(u8, s, n)) return c.refuse("{s}: the library is named '{s}', not the directory's '{s}'", .{ buck_path, s, n }),
                else => return c.refuse("{s}: name is not a string", .{buck_path}),
            }
        } else if (std.mem.eql(u8, an, "srcs")) {
            if (!isStandardGlob(v)) return c.refuse("{s}: srcs is not glob([\"**/*.mojo\"], exclude = [\"tests/**/*.mojo\"]); the recipe moves exactly those files", .{buck_path});
        } else if (std.mem.eql(u8, an, "deps")) {
            buck_deps = try strList(c, "deps", v);
        } else if (std.mem.eql(u8, an, "test_srcs")) {
            test_srcs = try strList(c, "test_srcs", v);
        } else if (std.mem.eql(u8, an, "test_deps")) {
            buck_test_deps = try strList(c, "test_deps", v);
        } else if (std.mem.eql(u8, an, "test_data")) {
            data = v;
        } else if (std.mem.eql(u8, an, "test_env")) {
            env = v;
        } else if (std.mem.eql(u8, an, "visibility")) {
            if (!oneString(v, "PUBLIC")) return c.refuse("{s}: visibility is not [\"PUBLIC\"]", .{buck_path});
        } else if (std.mem.startsWith(u8, an, "native") or std.mem.eql(u8, an, "dlopen") or std.mem.eql(u8, an, "c_deps")) {
            return c.refuse("{s}: '{s}' declares native code; not a plain migration (recipe step 0)", .{ buck_path, an });
        } else {
            return c.refuse("{s}: the attribute '{s}' of mojo_library is not covered by the recipe", .{ buck_path, an });
        }
    }
    if (data) |v| try extras.append(c.a, .{ .name = "test_data", .text = v.text(buck) });
    if (env) |v| try extras.append(c.a, .{ .name = "test_env", .text = v.text(buck) });
    if (o.test_layout) |l| {
        if (!std.mem.eql(u8, l, "installed") and !std.mem.eql(u8, l, "default")) return c.refuse("--test-layout is '{s}'; it is 'installed' or 'default'", .{l});
        if (std.mem.eql(u8, l, "installed")) try extras.append(c.a, .{ .name = "test_layout", .text = "\"installed\"" });
    } else if (data != null or env != null) {
        return c.refuse("{s} declares test_data or test_env: the layout the test runs in is not in the old file. Pass --test-layout=installed when the test reads share/ (recipe step 3), else --test-layout=default", .{buck_path});
    }

    // ---- the files of the package
    var lib_files = std.ArrayList([]const u8).empty;
    var test_files = std.ArrayList([]const u8).empty;
    var tests_found = std.ArrayList([]const u8).empty;
    for (files) |f| {
        if (!std.mem.startsWith(u8, f.path, pkg)) continue;
        const rel = f.path[pkg.len..];
        if (!std.mem.endsWith(u8, rel, ".mojo")) continue;
        if (std.mem.startsWith(u8, rel, "tests/")) {
            try test_files.append(c.a, f.path);
            const base = rel["tests/".len..];
            if (std.mem.indexOfScalar(u8, base, '/') == null and std.mem.startsWith(u8, base, "test_")) try tests_found.append(c.a, rel);
        } else try lib_files.append(c.a, f.path);
    }
    std.mem.sort([]const u8, lib_files.items, {}, lessStr);
    if (!contains(lib_files.items, try fmt(c, "{s}__init__.mojo", .{pkg}))) return c.refuse("{s}__init__.mojo not found: a library has one", .{pkg});
    if (tests_found.items.len == 0) return c.refuse("src/{s}/tests has no test_*.mojo: the package has no test to gate on", .{n});
    for (tests_found.items) |t| if (!contains(test_srcs, t)) return c.refuse("{s}: tests/test_*.mojo file '{s}' is not in test_srcs; the new glob would add it to the gate", .{ buck_path, t });
    for (test_srcs) |t| if (!contains(tests_found.items, t)) return c.refuse("{s}: test_srcs lists '{s}', which is not a tests/test_*.mojo file of the package; the new glob would drop it", .{ buck_path, t });

    // ---- imports
    var lib_mods = std.ArrayList([]const u8).empty;
    var test_mods = std.ArrayList([]const u8).empty;
    var seen = std.ArrayList(Seen).empty;
    const groups = [_]struct { paths: []const []const u8, out: *std.ArrayList([]const u8) }{
        .{ .paths = lib_files.items, .out = &lib_mods },
        .{ .paths = test_files.items, .out = &test_mods },
    };
    for (groups) |g| {
        for (g.paths) |p| {
            const src = repo.text(p) orelse return c.refuse("{s} was not read: its imports are unknown", .{p});
            if (imp.findDlopen(src)) |ln| return c.refuse("{s}:{d}: uses DLHandle: a library loaded at run time is native code that no BUCK attribute declares; not a plain migration (recipe step 0)", .{ p, ln });
            var found = std.ArrayList([]const u8).empty;
            var bad = imp.Bad{};
            imp.scan(c.a, src, &found, &bad) catch |e| switch (e) {
                error.BadImport => return c.refuse("{s}:{d}: an import line that names no module", .{ p, bad.line }),
                error.OutOfMemory => return error.OutOfMemory,
            };
            for (found.items) |m| {
                try g.out.append(c.a, m);
                try seen.append(c.a, .{ .module = m, .file = p });
            }
        }
    }
    const lib_set = try uniqueSorted(c.a, lib_mods.items);
    const test_set = try uniqueSorted(c.a, test_mods.items);
    var deps_names = std.ArrayList([]const u8).empty;
    var dev_names = std.ArrayList([]const u8).empty;
    const classes = [_]struct { set: []const []const u8, out: *std.ArrayList([]const u8), lib_side: bool }{
        .{ .set = lib_set, .out = &deps_names, .lib_side = true },
        .{ .set = test_set, .out = &dev_names, .lib_side = false },
    };
    for (classes) |cl| {
        for (cl.set) |m| {
            if (std.mem.eql(u8, m, "std") or std.mem.eql(u8, m, n)) continue;
            if (!cl.lib_side and contains(lib_set, m)) continue;
            const sib_buck_path = try fmt(c, "src/{s}/BUCK", .{m});
            const sib_buck = repo.text(sib_buck_path) orelse {
                if (repo.has(sib_buck_path)) return c.refuse("{s} was not read", .{sib_buck_path});
                return c.refuse("{s} imports '{s}', which maps to no known package: there is no {s}", .{ firstFile(seen.items, m), m, sib_buck_path });
            };
            const migrated = repo.has(try fmt(c, "src/{s}/mopm.toml", .{m})) and std.mem.containsAtLeast(u8, sib_buck, 1, "mojo_package(");
            if (!migrated) {
                if (std.mem.containsAtLeast(u8, sib_buck, 1, "mojo_library(")) return c.refuse("{s} imports '{s}', which is still on the old rule (mojo_library): migrate it first, a dependency on an unmigrated library is refused by the adopted rule", .{ firstFile(seen.items, m), m });
                return c.refuse("{s} imports '{s}', whose BUCK file has no mojo_library or mojo_package: not a Mojo package this tool knows", .{ firstFile(seen.items, m), m });
            }
            try cl.out.append(c.a, m);
        }
    }
    const deps_sorted = try uniqueSorted(c.a, deps_names.items);
    const dev_sorted = try uniqueSorted(c.a, dev_names.items);

    // the old BUCK lists what the sources import
    const declared = try c.a.alloc([]const u8, buck_deps.len);
    for (buck_deps, declared) |l, *d| d.* = try labelName(c, l);
    const declared_set = try uniqueSorted(c.a, declared);
    for (deps_sorted) |d| if (!contains(declared_set, d)) return c.refuse("{s}: the library sources import '{s}' but deps does not list it", .{ buck_path, d });
    for (declared_set) |d| if (!contains(deps_sorted, d)) return c.refuse("{s}: deps lists '{s}' but no library source imports it; the manifest is derived from the imports", .{ buck_path, d });
    const declared_test = try c.a.alloc([]const u8, buck_test_deps.len);
    for (buck_test_deps, declared_test) |l, *d| d.* = try labelName(c, l);
    const declared_test_set = try uniqueSorted(c.a, declared_test);
    for (dev_sorted) |d| if (!contains(declared_test_set, d)) return c.refuse("{s}: the tests import '{s}' but test_deps does not list it", .{ buck_path, d });
    for (declared_test_set) |d| if (!contains(dev_sorted, d) and !contains(deps_sorted, d)) return c.refuse("{s}: test_deps lists '{s}' but no test imports it", .{ buck_path, d });
    if (dev_sorted.len > 0 and !o.dev_dependencies) {
        return c.refuse("the tests import {s} (not imported by the library): that is a [dev-dependencies] entry, and no migrated package has one, so its lock rows and sync workspaces are unverified. Pass --dev-dependencies to write it anyway", .{try std.mem.join(c.a, ", ", dev_sorted)});
    }

    // ---- the closure
    var closure = std.ArrayList(emit.Member).empty;
    var queue = std.ArrayList([]const u8).empty;
    try queue.appendSlice(c.a, deps_sorted);
    try queue.appendSlice(c.a, dev_sorted);
    var direct = std.ArrayList(emit.Dep).empty;
    var direct_dev = std.ArrayList(emit.Dep).empty;
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const name = queue.items[qi];
        var done = false;
        for (closure.items) |m| done = done or std.mem.eql(u8, m.name, name);
        if (done) continue;
        const toml_path = try fmt(c, "src/{s}/mopm.toml", .{name});
        const toml = repo.text(toml_path) orelse return c.refuse("{s} was not read or is missing: '{s}' is in the dependency closure", .{ toml_path, name });
        const man = try readManifest(c, try fmt(c, "src/{s}", .{name}), toml);
        if (man.native) return c.refuse("{s} declares natives; '{s}' is in the dependency closure, and a native dependency is not a plain migration (recipe step 0)", .{ toml_path, name });
        try closure.append(c.a, .{ .name = name, .version = man.version, .deps = man.deps });
        try queue.appendSlice(c.a, man.deps);
    }
    std.mem.sort(emit.Member, closure.items, {}, struct {
        fn less(_: void, x: emit.Member, y: emit.Member) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.less);
    for (deps_sorted) |d| for (closure.items) |m| if (std.mem.eql(u8, m.name, d)) try direct.append(c.a, try makeDep(c, d, m.version));
    for (dev_sorted) |d| for (closure.items) |m| if (std.mem.eql(u8, m.name, d)) try direct_dev.append(c.a, try makeDep(c, d, m.version));

    // ---- the binaries kept from the old file
    var binaries = std.ArrayList(emit.Binary).empty;
    for (bins.items) |b| try binaries.append(c.a, .{ .comment = b.comment, .text = try fixBinary(c, repo, buck, b) });

    var release_files = std.ArrayList([]const u8).empty;
    const conda_label = try fmt(c, "//src/{s}:{s}_conda", .{ n, n });
    for ([_][]const u8{ "release/BUCK", "release/artifacts.textproto" }) |rf| {
        if (repo.text(rf)) |t| if (std.mem.containsAtLeast(u8, t, 1, conda_label)) try release_files.append(c.a, rf);
    }

    const model = emit.Model{
        .name = n,
        .description = o.description,
        .mopm = o.mopm,
        .deps = direct.items,
        .dev_deps = direct_dev.items,
        .closure = closure.items,
        .n_tests = tests_found.items.len,
        .extras = extras.items,
        .header = ml.comment,
        .binaries = binaries.items,
        .release_files = release_files.items,
    };

    // ---- the result
    var moves = std.ArrayList(Move).empty;
    for (lib_files.items) |p| try moves.append(c.a, .{ .from = p, .to = try fmt(c, "{s}src/{s}/{s}", .{ pkg, n, p[pkg.len..] }) });

    var writes = std.ArrayList(Write).empty;
    const toml_text = try emit.manifest(c.a, model);
    const tc_text = try emit.toolchain(c.a, o.mopm);
    const lock_text = try emit.lock(c.a, closure.items);
    const buck_text = try emit.buck(c.a, model);
    const section = try emit.readmeSection(c.a, model);
    const readme_text = try fmt(c, "{s}{s}\n{s}", .{ readme, if (std.mem.endsWith(u8, readme, "\n")) "" else "\n", section });
    try writes.append(c.a, .{ .path = try fmt(c, "{s}mopm.toml", .{pkg}), .text = toml_text, .shown = toml_text, .replaces = false });
    try writes.append(c.a, .{ .path = try fmt(c, "{s}mopm-toolchain.toml", .{pkg}), .text = tc_text, .shown = tc_text, .replaces = false });
    try writes.append(c.a, .{ .path = try fmt(c, "{s}mopm.lock", .{pkg}), .text = lock_text, .shown = lock_text, .replaces = false });
    try writes.append(c.a, .{ .path = buck_path, .text = buck_text, .shown = buck_text, .replaces = true });
    try writes.append(c.a, .{ .path = readme_path, .text = readme_text, .shown = try fmt(c, "(appended)\n{s}", .{section}), .replaces = true });

    // shared rows
    const pk_path = "release/readme_e2e/packages.bzl";
    const pk_line = try fmt(c, "    \"{s}\": \"{s}\",", .{ n, emit.package_version });
    try writes.append(c.a, .{
        .path = pk_path,
        .text = try insertSorted(c, try requireText(c, repo, pk_path), .{ .open = "PACKAGES = {", .close = "}" }, keyQuoted, pk_line, n, pk_path),
        .shown = try fmt(c, "+ {s}", .{pk_line}),
        .replaces = true,
    });
    const ids_path = "release/mopm_native_ids.bzl";
    const load_line = try fmt(c, "load(\"//src/{s}:buildrules.mojo.lock.bzl\", {s} = \"GRAPH\")", .{ n, n });
    const row_line = try fmt(c, "    \"{s}\": {s},", .{ n, n });
    const ids_a = try insertSorted(c, try requireText(c, repo, ids_path), null, keyLoad, load_line, n, ids_path);
    try writes.append(c.a, .{
        .path = ids_path,
        .text = try insertSorted(c, ids_a, .{ .open = "_GRAPHS = {", .close = "}" }, keyQuoted, row_line, n, ids_path),
        .shown = try fmt(c, "+ {s}\n+ {s}", .{ load_line, row_line }),
        .replaces = true,
    });
    var notes = std.ArrayList([]const u8).empty;
    if (direct_dev.items.len > 0) try notes.append(c.a, "dev-dependencies are written to mopm.toml and mopm.lock, but no migrated package has one: the sync decides whether they are accepted.");
    if (deps_sorted.len > 0 and claimsNoDependencies(ml.comment)) try notes.append(c.a, "the comment above the old mojo_library says the package has no dependencies, and it has some: it is kept as written, so edit it.");
    if (closure.items.len > 1) try notes.append(c.a, "the dependency closure has more than one package: only a one-level dependency has been built by hand; if `members` of the closure is refused, see the chain form in the recipe.");
    try notes.append(c.a, "the comment above the old mojo_library is kept as written: a path in it (a library file now under src/<name>/src/<name>/) is not rewritten.");
    var farm = std.ArrayList([]const u8).empty;
    try farm.append(c.a, try fmt(c, "generate the tables: `buildrules mojo sync` for src/{s} on the farm (recipe step 4); copy buildrules.mojo.bzl and buildrules.mojo.lock.bzl into src/{s}", .{ n, n }));
    try farm.append(c.a, try fmt(c, "measure: ./buck2 build //src/{s}:coverage --show-full-output, write coverage_floor.txt ('lines NN.NN', 'branches NN.NN'), then build //src/{s}:coverage_floor", .{ n, n }));
    if (repo.has("ci/targets/shard_0.bzl")) {
        try farm.append(c.a, "regenerate the check roots (ci/targets.bzl and its shards are generated; the tool does not edit them): cp -rL --no-preserve=mode \"$(./buck2 bxl komira//tools/build/ci/targets.bxl:generate)\"/. ci/ ; then ./buck2 bxl komira//tools/build/ci/guard.bxl:check");
    } else {
        try farm.append(c.a, "regenerate the check roots (ci/targets.bzl is generated; the tool does not edit it): ./buck2 bxl komira//tools/build/ci/targets.bxl:generate > ci/targets.bzl ; then ./buck2 bxl komira//tools/build/ci/guard.bxl:check");
    }
    try farm.append(c.a, try fmt(c, "build: //src/{s}:lib //src/{s}:{s} \"//src/{s}:{s}[tests]\" //src/{s}:{s}_conda //src/{s}:conda //src/{s}:table //src/{s}:ci (all `local: 0`), then one dependent of the old label", .{ n, n, n, n, n, n, n, n, n, n }));
    return .{ .moves = moves.items, .writes = writes.items, .notes = notes.items, .farm = farm.items };
}
