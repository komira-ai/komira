//! The text the migration writes: `mopm.toml`, `mopm-toolchain.toml`, `mopm.lock`, the new BUCK
//! file and the README section. Each is a function of the `Model` that `plan.zig` derives from the
//! old BUCK file and the sources; nothing here reads the tree.
//!
//! The BUCK file's comments are prose, wrapped at 100 columns (`para`). The hand migrations were
//! wrapped by eye, so the tests compare comments word for word, not line for line.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Buf = struct {
    a: Allocator,
    list: std.ArrayList(u8) = .empty,

    pub fn add(self: *Buf, s: []const u8) !void {
        try self.list.appendSlice(self.a, s);
    }

    pub fn print(self: *Buf, comptime fmt: []const u8, args: anytype) !void {
        try self.add(try std.fmt.allocPrint(self.a, fmt, args));
    }

    pub fn done(self: *Buf) ![]u8 {
        return self.list.toOwnedSlice(self.a);
    }
};

/// A direct dependency, with the range its manifest line and its `.conda` requirement carry.
pub const Dep = struct {
    name: []const u8,
    /// `MAJOR.MINOR` of the dependency's version: `version = "0.1"` accepts every 0.1.x.
    short: []const u8,
    /// The conda requirement: `mojo-<name> >=0.1,<0.2`.
    requirement: []const u8,
};

/// One package of the dependency closure, for `mopm.lock` and `members`.
pub const Member = struct {
    name: []const u8,
    version: []const u8,
    /// Its direct dependencies, sorted.
    deps: []const []const u8,
};

pub const Extra = struct { name: []const u8, text: []const u8 };

pub const Binary = struct { comment: []const u8, text: []const u8 };

pub const Model = struct {
    name: []const u8,
    description: []const u8,
    mopm: []const u8,
    deps: []const Dep,
    dev_deps: []const Dep,
    /// Every package `deps` reaches, direct and transitive, sorted by name.
    closure: []const Member,
    n_tests: usize,
    /// `test_data`, `test_env`, `test_layout` for `mojo_package`, as written.
    extras: []const Extra,
    /// The comment above the old `mojo_library`, as written; empty for none.
    header: []const u8,
    binaries: []const Binary,
    /// The files of release/ that name the `<name>_conda` label.
    release_files: []const []const u8,
    /// The packages of the closure whose manifest declares static natives (`[native.<id>]`), sorted.
    /// The package owns no C, but its link takes their archives from the closure.
    native_deps: []const []const u8 = &.{},
};

pub const mojo_version = "1.0.0";
pub const package_version = "0.1.0";

/// Comment prose inside a call, wrapped to 100 columns: every line starts with `    # `.
fn indentedPara(b: *Buf, prose: []const u8) !void {
    var len: usize = 5;
    try b.add("    #");
    var it = std.mem.tokenizeScalar(u8, prose, ' ');
    while (it.next()) |w| {
        if (len > 5 and len + 1 + w.len > 100) {
            try b.add("\n    #");
            len = 5;
        }
        try b.add(" ");
        try b.add(w);
        len += 1 + w.len;
    }
    try b.add("\n");
}

/// Comment prose, wrapped to 100 columns: every line starts with `# `.
pub fn para(b: *Buf, prose: []const u8) !void {
    var len: usize = 1;
    try b.add("#");
    var it = std.mem.tokenizeScalar(u8, prose, ' ');
    while (it.next()) |w| {
        if (len > 1 and len + 1 + w.len > 100) {
            try b.add("\n#");
            len = 1;
        }
        try b.add(" ");
        try b.add(w);
        len += 1 + w.len;
    }
    try b.add("\n");
}

fn plural(n: usize, one: []const u8, many: []const u8) []const u8 {
    return if (n == 1) one else many;
}

/// `a`, `a and b`, `a, b and c`.
fn andList(a: Allocator, items: []const []const u8) ![]const u8 {
    var b = Buf{ .a = a };
    for (items, 0..) |it, i| {
        if (i > 0) try b.add(if (i + 1 == items.len) " and " else ", ");
        try b.add(it);
    }
    return b.done();
}

fn depNames(a: Allocator, deps: []const Dep) ![]const []const u8 {
    const out = try a.alloc([]const u8, deps.len);
    for (deps, out) |d, *o| o.* = d.name;
    return out;
}

fn requirements(a: Allocator, deps: []const Dep) ![]const u8 {
    var b = Buf{ .a = a };
    for (deps, 0..) |d, i| {
        if (i > 0) try b.add(if (i + 1 == deps.len) " and " else ", ");
        try b.print("`{s}`", .{d.requirement});
    }
    return b.done();
}

pub fn manifest(a: Allocator, m: Model) ![]u8 {
    var b = Buf{ .a = a };
    try b.print(
        \\[package]
        \\name = "{s}"
        \\version = "{s}"
        \\description = "{s}"
        \\license = "Apache-2.0"
        \\repository = "https://github.com/komira-ai/komira"
        \\readme = "README.md"
        \\mojo = ["{s}"]
        \\
    , .{ m.name, package_version, m.description, mojo_version });
    const tables = [_]struct { head: []const u8, deps: []const Dep }{
        .{ .head = "[dependencies]", .deps = m.deps },
        .{ .head = "[dev-dependencies]", .deps = m.dev_deps },
    };
    for (tables) |t| {
        if (t.deps.len == 0) continue;
        try b.print("\n{s}\n", .{t.head});
        for (t.deps) |d| try b.print("{s} = {{ path = \"../{s}\", version = \"{s}\" }}\n", .{ d.name, d.name, d.short });
    }
    try b.print(
        \\
        \\[targets]
        \\lib = {{ path = "src/{s}" }}
        \\tests = ["tests"]
        \\
    , .{m.name});
    return b.done();
}

pub fn toolchain(a: Allocator, mopm: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "[toolchain]\nmopm = \"{s}\"\nmojo = \"{s}\"\n", .{ mopm, mojo_version });
}

const lock_head =
    \\{
    \\  "lock_version": 2,
    \\  "mojo": [
    \\    "1.0.0"
    \\  ],
    \\  "toolchain": {
    \\    "1.0.0": {
    \\      "linux-64": "fd654c4192487587d8f8d9402d060e45e218b79da7b8964503a703710e49b15d",
    \\      "linux-aarch64": "3e7db5a0f9255c9086d9d29f385e7fd90e8536fa16ffe55414f6bba4e0ef3d3e",
    \\      "osx-arm64": "dfb1ddbe32564e406967054fbccd4ad643bf01e72532a3eb3add28253908ac5f"
    \\    }
    \\  },
    \\  "channels": [
    \\    "https://conda.mopm.dev/"
    \\  ],
    \\
;

/// `mopm.lock`: the toolchain pins and one `path` row per package of the closure.
pub fn lock(a: Allocator, closure: []const Member) ![]u8 {
    var b = Buf{ .a = a };
    try b.add(lock_head);
    if (closure.len == 0) {
        try b.add("  \"packages\": []\n}\n");
        return b.done();
    }
    try b.add("  \"packages\": [\n");
    for (closure, 0..) |mem, i| {
        try b.print(
            \\    {{
            \\      "name": "{s}",
            \\      "version": "{s}",
            \\      "source": "path",
            \\      "path": "../{s}"
        , .{ mem.name, mem.version, mem.name });
        if (mem.deps.len > 0) {
            try b.add(",\n      \"deps\": [\n");
            for (mem.deps, 0..) |d, j| try b.print("        \"{s}\"{s}\n", .{ d, if (j + 1 < mem.deps.len) "," else "" });
            try b.add("      ]");
        }
        try b.print("\n    }}{s}\n", .{if (i + 1 < closure.len) "," else ""});
    }
    try b.add("  ]\n}\n");
    return b.done();
}

fn listAttr(b: *Buf, name: []const u8, items: []const []const u8) !void {
    if (items.len == 1) {
        try b.print("    {s} = [\"{s}\"],\n", .{ name, items[0] });
        return;
    }
    try b.print("    {s} = [\n", .{name});
    for (items) |it| try b.print("        \"{s}\",\n", .{it});
    try b.add("    ],\n");
}

pub fn buck(a: Allocator, m: Model) ![]u8 {
    var b = Buf{ .a = a };
    const has_deps = m.deps.len > 0;
    const one = m.n_tests == 1;
    const names = try depNames(a, m.deps);
    const dep_list = try andList(a, names);
    const reqs = try requirements(a, m.deps);

    try b.add("load(\"@buildrules//rules/mojo:pack.bzl\", \"mojo_conda\"");
    if (has_deps) try b.add(", \"mojo_conda_holds\"");
    try b.add(")\nload(\"@komira//tools/build/mojo:adopt.bzl\", \"mojo_adopted_library\")\n");
    if (m.binaries.len > 0) try b.add("load(\"@komira//tools/build/mojo:defs.bzl\", \"mojo_binary\")\n");
    try b.add("load(\"@komira//tools/build/package:conda.bzl\", \"conda_package\")\nload(\":buildrules.mojo.bzl\", \"mojo_package\")\n\n");

    // mojo_package
    if (m.header.len > 0) {
        try b.add(m.header);
        try b.add("\n#\n");
    }
    var prose = Buf{ .a = a };
    try prose.print("Built with buildrules' `mojo_package` from mopm.toml (README.md, \"Build files\"): `:lib` is the library file and exists only once {s}test of tests/ has passed.", .{if (one) "the " else "every "});
    if (has_deps) {
        try prose.print(" The package depends on {s}, {s} (`[dependencies]` of mopm.toml): its `:lib` is built from {s} `:lib`.", .{
            dep_list,
            plural(m.deps.len, "a sibling package", "sibling packages"),
            plural(m.deps.len, "that package's", "those packages'"),
        });
    }
    try para(&b, prose.list.items);
    if (m.extras.len == 0) {
        try b.add("mojo_package(path = \".\")\n\n");
    } else {
        try b.add("mojo_package(\n    path = \".\",\n");
        for (m.extras) |e| try b.print("    {s} = {s},\n", .{ e.name, e.text });
        try b.add(")\n\n");
    }

    // mojo_adopted_library
    prose = Buf{ .a = a };
    try prose.print("`:{s}`, the target the packages that depend on this library name, is `:lib` as komira's Mojo rules take it (tools/build/mojo/adopt.bzl): the same file, so a dependent builds only once {s} passed.", .{ m.name, if (one) "the test has" else "the tests have" });
    if (has_deps) try prose.add(" `deps` is `[dependencies]` of mopm.toml, as the adopted targets of those packages: the rule refuses a list that is not the closure `:lib` was built from.");
    try prose.print(" It carries the README gate too (`[tests][readme]`): the examples run against `:lib`; {s} not run again.", .{if (one) "the test is" else "the tests are"});
    try para(&b, prose.list.items);
    try b.print("mojo_adopted_library(\n    name = \"{s}\",\n", .{m.name});
    if (has_deps) {
        const labels = try a.alloc([]const u8, m.deps.len);
        for (m.deps, labels) |d, *l| l.* = try std.fmt.allocPrint(a, "//src/{s}:{s}", .{ d.name, d.name });
        try listAttr(&b, "deps", labels);
    }
    if (m.native_deps.len > 0) {
        // The adopted library hands the archives of its closure to a dependent's link; it needs the
        // C toolchain's link facts for that, whether or not it owns C itself.
        const who = try andList(a, m.native_deps);
        try indentedPara(&b, try std.fmt.allocPrint(a, "{s} {s} in the closure and link{s} C (static `[native.<id>]` archives), so `lib`'s closure carries {s} and a dependent's link takes {s} from here. This package owns no C, so it names no `c_deps`: it takes the C toolchain's link facts directly.", .{
            who,
            plural(m.native_deps.len, "is", "are"),
            plural(m.native_deps.len, "s", ""),
            plural(m.native_deps.len, "that archive", "those archives"),
            plural(m.native_deps.len, "it", "them"),
        }));
        try b.add("    cxx_toolchain = \"komira//tools/build/mojo:adopt_cxx_link_facts\",\n");
    }
    try b.print(
        \\    lib = ":lib",
        \\    readme = "README.md",
        \\    srcs = glob(["src/{s}/**/*.mojo"]),
        \\    test_srcs = glob(["tests/test_*.mojo"]),
        \\    test_runs = ":test",
        \\    visibility = ["PUBLIC"],
        \\)
        \\
        \\
    , .{m.name});

    for (m.binaries) |bin| {
        if (bin.comment.len > 0) {
            try b.add(bin.comment);
            try b.add("\n");
        }
        try b.add(bin.text);
        try b.add("\n\n");
    }

    // mojo_conda
    prose = Buf{ .a = a };
    try prose.print("The mopm package: `mopm pack` over `:lib`, the `.conda` a mopm registry serves (`mojo-{s}-{s}-mojo{s}_0.conda`)", .{ m.name, package_version, mojo_version });
    if (has_deps) {
        try prose.print(", which records {s} as {s} ({s}) and holds {s} files nowhere. `members` is the manifests of the path dependencies{s}, staged at their repository paths, because `mopm pack` reads the manifest of each beside the one it is given.", .{
            dep_list,
            plural(m.deps.len, "a dependency", "dependencies"),
            reqs,
            plural(m.deps.len, "that package's", "those packages'"),
            if (m.closure.len > m.deps.len) @as([]const u8, " of the closure") else "",
        });
    } else try prose.add(".");
    try prose.print(" `:lib` exists only once {s} passed, so this file exists only then. Publishing it (`mopm publish`) uploads, which is not a build action: it is a step of a CI job that takes this target's output. `mopm` is the one `mojo_package` pins (mopm-toolchain.toml).", .{if (one) "the test" else "the tests"});
    try para(&b, prose.list.items);
    try b.add("mojo_conda(\n    name = \"conda\",\n");
    if (has_deps) try b.print("    dir = \"src/{s}\",\n", .{m.name});
    try b.add("    lib = \":lib\",\n    manifest = \"mopm.toml\",\n");
    if (has_deps) {
        if (m.closure.len == 1) {
            try b.print("    members = {{\"../{s}\": \"//src/{s}:mopm.toml\"}},\n", .{ m.closure[0].name, m.closure[0].name });
        } else {
            try b.add("    members = {\n");
            for (m.closure) |c| try b.print("        \"../{s}\": \"//src/{s}:mopm.toml\",\n", .{ c.name, c.name });
            try b.add("    },\n");
        }
    }
    try b.print(
        \\    mojo = "{s}",
        \\    mopm = "toolchains//:mopm_{s}",
        \\    package = "{s}",
        \\    version = "{s}",
        \\    visibility = ["PUBLIC"],
        \\)
        \\
        \\
    , .{ mojo_version, try std.mem.replaceOwned(u8, a, m.mopm, ".", "_"), m.name, package_version });

    // mojo_conda_holds
    if (has_deps) {
        prose = Buf{ .a = a };
        try prose.print("What `:conda` holds, read back from the built file (buildrules' `prebuilt_unpack`): this package's own `.mojoc` and nothing else under `lib/mojo/` ({s} {s} not in it), and exactly {s}, {s}, which is what installing the package pulls in. Red when the manifest drops {s}, names another range, or the file carries {s}.", .{
            dep_list,
            plural(m.deps.len, "is", "are"),
            if (m.deps.len == 1) @as([]const u8, "one dependency") else try std.fmt.allocPrint(a, "{d} dependencies", .{m.deps.len}),
            reqs,
            plural(m.deps.len, "the dependency", "a dependency"),
            plural(m.deps.len, "the sibling", "a sibling"),
        });
        try para(&b, prose.list.items);
        const depends = try a.alloc([]const u8, m.deps.len);
        for (m.deps, depends) |d, *x| x.* = d.requirement;
        try b.add("mojo_conda_holds(\n    name = \"conda_holds\",\n    conda = \":conda\",\n");
        try listAttr(&b, "depends", depends);
        try b.print("    package = \"{s}\",\n    sole = True,\n    visibility = [\"PUBLIC\"],\n)\n\n", .{m.name});
    }

    // conda_package
    prose = Buf{ .a = a };
    if (m.release_files.len > 0) {
        try prose.print("Kept for the release machine, which still builds it ({s}): komira's conda packer over `:{s}`.", .{ try std.mem.join(a, ", ", m.release_files), m.name });
    } else {
        try prose.print("Kept so the label `:{s}_conda` stays valid: komira's conda packer over `:{s}`.", .{ m.name, m.name });
    }
    try prose.add(" It goes when the release machine takes the mopm package. This library's mopm package is `:conda` above.");
    try para(&b, prose.list.items);
    try b.print(
        \\conda_package(
        \\    name = "{s}_conda",
        \\    lib = ":{s}",
        \\    summary = "The `{s}` Mojo library of komira, as a conda package.",
        \\    visibility = ["PUBLIC"],
        \\)
        \\
    , .{ m.name, m.name, m.name });
    return b.done();
}

/// The `## Build files` section appended to the README.
pub fn readmeSection(a: Allocator, m: Model) ![]u8 {
    var b = Buf{ .a = a };
    const has_deps = m.deps.len > 0;
    const one = m.n_tests == 1;
    try b.print("## Build files\n\nThis package is built with buildrules' `mojo_package` and packaged for mopm as `{s}`, version {s} (`mopm.toml`). The library is `src/{s}/`, its {s} {s} `tests/`.", .{
        m.name, package_version, m.name, if (one) "test" else "tests", if (one) "is" else "are",
    });
    if (has_deps) {
        const dep_list = try andList(a, try depNames(a, m.deps));
        try b.print(" It depends on {s}, {s} (`[dependencies]` of `mopm.toml`), so the `.conda` of this package records {s} as {s} and holds none of {s} files: installing `{s}` installs {s} with it.", .{
            dep_list,
            plural(m.deps.len, "a sibling directory", "sibling directories"),
            try requirements(a, m.deps),
            plural(m.deps.len, "a dependency", "dependencies"),
            plural(m.deps.len, "that package's", "those packages'"),
            m.name,
            plural(m.deps.len, "it", "them"),
        });
    }
    if (m.native_deps.len > 0) {
        try b.print(" {s} in the closure link{s} C of {s} own (static `[native.<id>]` archives); a dependent's link takes {s} from the closure, and this package owns no C.", .{
            try andList(a, m.native_deps),
            plural(m.native_deps.len, "s", ""),
            plural(m.native_deps.len, "its", "their"),
            plural(m.native_deps.len, "it", "them"),
        });
    }
    try b.add(" The files that are not sources:\n\n| file | what |\n|---|---|\n");
    try b.add("| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependencies and where the library and its tests are |\n");
    try b.add("| `mopm.lock` | the toolchain pins and the path dependencies (no registry is reached: every dependency is a sibling) |\n");
    try b.add("| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses |\n");
    try b.add("| `coverage_floor.txt` | `lines NN.NN` and `branches NN.NN`: the least line and branch coverage `:coverage` may measure; `:coverage_floor` fails when either falls below, and above it passes and prints a hint to raise the figure |\n");
    try b.add("| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above");
    if (has_deps) try b.add(" and from the manifests of the dependencies");
    try b.add("; `buildrules mojo check` fails when they are stale |\n\n");
    try b.print("`:lib` is the library file and exists only once {s} of `tests/` has passed. After any change to a source, a test, or a manifest of this package{s}, run `buildrules mojo sync`, commit what it writes, and build `komira//src/{s}:lib` on the farm. A test file that the sync has not listed is not run: run the sync after adding one.\n\n", .{
        if (one) "the test" else "every test",
        if (has_deps) " or of a dependency" else "",
        m.name,
    });
    try b.print("`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package (`mojo-{s}-{s}-mojo{s}_0.conda`), which therefore exists only once {s} passed. Publishing it (`mopm publish`) uploads, so it is a step of a CI job that takes that file, not a build action.\n\n", .{
        m.name, package_version, mojo_version, if (one) "the test has" else "the tests have",
    });
    try b.print("`:{s}` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`).{s} It also compiles and runs the README's examples above (`[tests][readme]`) against `:lib`; {s} not run again.\n", .{
        m.name,
        if (has_deps) " Its `deps` are the adopted target of each package in `[dependencies]`, and the rule refuses a list that is not the closure `:lib` was built from." else "",
        if (one) "the test is" else "the tests are",
    });
    return b.done();
}
