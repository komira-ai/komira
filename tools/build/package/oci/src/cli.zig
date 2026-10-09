//! The commands of komira_oci (main.zig): their flags, the OCI layout they
//! read back, and the busybox gzip they run.

const std = @import("std");
const C = @import("common.zig");
const image = @import("image.zig");
const json = @import("json.zig");
const pack = @import("pack.zig");
const tar = @import("tar.zig");
const tree = @import("tree.zig");
const Fail = C.Fail;
const Value = json.Value;

pub const Pair = struct { flag: []const u8, value: []const u8 };

pub const Args = struct {
    cmd: []const u8,
    pairs: []const Pair,

    pub fn parse(argv: []const []const u8) Fail!Args {
        if (argv.len < 2) return C.failS("no command (tree, image, layers, check)");
        var pairs = C.list(Pair);
        var i: usize = 2;
        while (i < argv.len) : (i += 2) {
            if (i + 1 >= argv.len) return C.fail("{s} needs a value", .{argv[i]});
            C.push(Pair, &pairs, .{ .flag = argv[i], .value = argv[i + 1] });
        }
        return .{ .cmd = argv[1], .pairs = pairs.items };
    }

    pub fn allow(self: Args, flags: []const []const u8) Fail!void {
        for (self.pairs) |p| {
            const known = for (flags) |f| {
                if (C.eql(f, p.flag)) break true;
            } else false;
            if (!known) return C.fail("unknown flag {s} for {s}", .{ p.flag, self.cmd });
        }
    }

    pub fn opt(self: Args, flag: []const u8) Fail!?[]const u8 {
        var first: ?[]const u8 = null;
        for (self.pairs) |p| {
            if (!C.eql(p.flag, flag)) continue;
            if (first != null) return C.fail("{s} given twice", .{flag});
            first = p.value;
        }
        return first;
    }

    pub fn one(self: Args, flag: []const u8) Fail![]const u8 {
        return (try self.opt(flag)) orelse return C.fail("missing {s}", .{flag});
    }

    pub fn all(self: Args, flag: []const u8) [][]const u8 {
        var out = C.list([]const u8);
        for (self.pairs) |p| {
            if (C.eql(p.flag, flag)) C.push([]const u8, &out, p.value);
        }
        return out.items;
    }
};

fn readPath(p: []const u8) Fail![]u8 {
    return C.readFile(p) catch |e| return C.fail("cannot read {s}: {s}", .{ p, C.ioErr(e) });
}

fn writePath(p: []const u8, data: []const u8) Fail!void {
    C.writeFile(p, data) catch |e| return C.fail("cannot write {s}: {s}", .{ p, C.ioErr(e) });
}

/// A `sha256:<64 lower-case hex>` digest; anything else could name a path
/// outside the layout.
pub fn digest(v: ?Value, what: []const u8) Fail![]const u8 {
    const d = (if (v) |x| x.asStr() else null) orelse return C.fail("{s}: no digest", .{what});
    const hex = if (C.startsWith(d, "sha256:")) d["sha256:".len..] else "";
    var ok = hex.len == 64;
    for (hex) |b| {
        if (!((b >= '0' and b <= '9') or (b >= 'a' and b <= 'f'))) ok = false;
    }
    if (!ok) return C.fail("{s}: `{s}` is not a sha256:<64 hex> digest", .{ what, d });
    return d;
}

pub const Layout = struct {
    dir: []const u8,
    busybox: []const u8,
    layers: [][]const u8,
    config: Value,

    pub fn blob(self: Layout, d: []const u8) []const u8 {
        return C.pathJoin(C.pathJoin(self.dir, "blobs/sha256"), d["sha256:".len..]);
    }

    pub fn open(dir: []const u8, busybox: []const u8) Fail!Layout {
        var l = Layout{ .dir = dir, .busybox = busybox, .layers = &.{}, .config = .nul };
        const index = json.parse(try readPath(C.pathJoin(l.dir, "index.json"))) catch return C.fail("index.json: {s}", .{C.msg});
        const ms = (if (index.get("manifests")) |x| x.asArr() else null) orelse return C.failS("index.json: no `manifests` array");
        if (ms.len != 1) return C.fail("index.json names {d} manifests, want 1", .{ms.len});
        const m = json.parse(try readPath(l.blob(try digest(ms[0].get("digest"), "index.json manifest")))) catch return C.fail("manifest: {s}", .{C.msg});
        const c = try digest(if (m.get("config")) |x| x.get("digest") else null, "manifest config");
        const ls = (if (m.get("layers")) |x| x.asArr() else null) orelse return C.failS("manifest: no `layers` array");
        var lds = C.list([]const u8);
        for (ls, 0..) |d, i| C.push([]const u8, &lds, try digest(d.get("digest"), C.fmt("manifest layer {d}", .{i})));
        if (lds.items.len == 0) return C.failS("the manifest names no layer");
        l.layers = lds.items;
        l.config = json.parse(try readPath(l.blob(c))) catch return C.fail("config: {s}", .{C.msg});
        return l;
    }

    /// The config's Entrypoint, if it is an array of strings.
    pub fn entrypoint(self: Layout) ?[]const []const u8 {
        const cc = self.config.get("config") orelse return null;
        const ep = (cc.get("Entrypoint") orelse return null).asArr() orelse return null;
        var out = C.list([]const u8);
        for (ep) |v| C.push([]const u8, &out, v.asStr() orelse return null);
        return out.items;
    }

    /// Layer `i`'s entries: a gzip stream through busybox, else a tar.
    pub fn entries(self: Layout, i: usize) Fail![]tar.Entry {
        const p = self.blob(self.layers[i]);
        const raw = try readPath(p);
        var data: []const u8 = raw;
        if (raw.len >= 2 and raw[0] == 0x1f and raw[1] == 0x8b) {
            const r = std.ChildProcess.run(.{
                .allocator = C.a(),
                .argv = C.a().dupe([]const u8, &.{ self.busybox, "gzip", "-dc", p }) catch C.oom(),
                .max_output_bytes = std.math.maxInt(usize),
            }) catch |e| return C.fail("cannot run {s}: {s}", .{ self.busybox, C.ioErr(e) });
            if (!(r.term == .Exited and r.term.Exited == 0)) {
                return C.fail("layer {s}: gzip -dc failed: {s}", .{ self.layers[i], C.trim(C.lossy(r.stderr)) });
            }
            data = r.stdout;
        }
        return tar.read(data) catch return C.fail("layer {s}: {s}", .{ self.layers[i], C.msg });
    }
};

/// `<path>=<src>`: the path holds no `=`, so the first one splits.
pub fn place(v: []const u8, bundle: bool) Fail!tree.Place {
    const eq = std.mem.indexOfScalar(u8, v, '=') orelse return C.fail("`{s}` is not <path>=<source>", .{v});
    return .{ .path = v[0..eq], .src = v[eq + 1 ..], .bundle = bundle };
}

pub fn treeCmd(a: Args) Fail!void {
    try a.allow(&.{ "--out", "--bundle", "--file" });
    var places = C.list(tree.Place);
    for (a.all("--bundle")) |v| C.push(tree.Place, &places, try place(v, true));
    for (a.all("--file")) |v| C.push(tree.Place, &places, try place(v, false));
    switch (tree.plan(places.items)) {
        .refused => |bad| return C.fail("the tree is refused:\n  {s}", .{C.join(bad, "\n  ")}),
        .plan => |p| return tree.lay(try a.one("--out"), p),
    }
}

const Feed = struct { file: std.fs.File, data: []const u8, err: ?anyerror = null };

fn feed(f: *Feed) void {
    f.file.writeAll(f.data) catch |e| {
        f.err = e;
    };
    f.file.close();
}

/// A failed write of gzip's input as Rust's Debug writes it.
fn feedDebug(e: anyerror) []const u8 {
    if (e == error.BrokenPipe) return "Ok(Err(Os { code: 32, kind: BrokenPipe, message: \"Broken pipe\" }))";
    return C.fmt("Ok(Err({s}))", .{@errorName(e)});
}

/// `data` gzipped by `<busybox> gzip -c`, the header's modification time
/// zeroed so the bytes depend on `data` alone (the header is not in the
/// stream's CRC, which covers the uncompressed bytes).
pub fn gzip(busybox: []const u8, data: []const u8) Fail![]u8 {
    const argv = C.a().dupe([]const u8, &.{ busybox, "gzip", "-c" }) catch C.oom();
    var child = std.ChildProcess.init(argv, C.a());
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch |e| return C.fail("cannot run {s}: {s}", .{ busybox, C.ioErr(e) });
    var fd = Feed{ .file = child.stdin.?, .data = data };
    child.stdin = null;
    const th = std.Thread.spawn(.{}, feed, .{&fd}) catch |e| return C.fail("gzip: {s}", .{C.ioErr(e)});
    var out = C.list(u8);
    var errs = C.list(u8);
    const collected = child.collectOutput(&out, &errs, std.math.maxInt(usize));
    th.join();
    // A program that cannot be run is reported here, not by spawn.
    const term = child.wait() catch |e| return C.fail("cannot run {s}: {s}", .{ busybox, C.ioErr(e) });
    collected catch |e| return C.fail("gzip: {s}", .{C.ioErr(e)});
    if (fd.err) |e| return C.fail("gzip: cannot write its input: {s}", .{feedDebug(e)});
    if (!(term == .Exited and term.Exited == 0)) return C.fail("gzip -c failed: {s}", .{C.trim(C.lossy(errs.items))});
    return zeroMtime(out.items);
}

/// `gz` with its header's modification time zeroed, refused unless it is
/// a whole gzip stream's plain header: ID1 ID2, deflate, no flags (no name,
/// no comment, no header CRC), and room for the 8-byte trailer.
pub fn zeroMtime(gz: []u8) Fail![]u8 {
    if (gz.len < 18 or !C.eql(gz[0..4], &.{ 0x1f, 0x8b, 8, 0 })) {
        return C.fail("gzip -c wrote no plain gzip header: {s}", .{C.debugHex(gz[0..@min(gz.len, 4)])});
    }
    @memset(gz[4..8], 0);
    return gz;
}

pub fn imageCmd(a: Args) Fail!void {
    try a.allow(&.{ "--tree", "--entrypoint", "--name", "--version", "--repo", "--manifest", "--manifest-digest", "--config", "--layer", "--busybox", "--out", "--archive", "--digest" });
    const ep = try a.one("--entrypoint");
    if (ep.len < 2 or !C.startsWith(ep, "/")) return C.fail("entrypoint `{s}` is not an absolute path", .{ep});
    const name = try pack.plain(try a.one("--name"), "name", "");
    const version = try pack.plain(try a.one("--version"), "version", "~");
    const repo = try pack.plain(try a.one("--repo"), "repo", "/:");
    const n = pack.Named{ .name = name, .version = version, .repo = repo, .entrypoint = ep };
    const manifest = try readPath(try a.one("--manifest"));
    const pin = try a.one("--manifest-digest");
    const cfg = try readPath(try a.one("--config"));
    var blobs = C.list([]const u8);
    for (a.all("--layer")) |p| C.push([]const u8, &blobs, try readPath(p));
    const base = pack.Base{ .manifest = manifest, .pin = pin, .config = cfg, .layers = blobs.items };
    const layer_tar = try tar.write(try pack.treeItems(try a.one("--tree")));
    const layer_gz = try gzip(try a.one("--busybox"), layer_tar);
    const img = try pack.image(base, layer_tar, layer_gz, n);
    const out = try a.one("--out");
    const archive = try a.one("--archive");
    const dg = try a.one("--digest");
    return pack.write(img, out, archive, dg);
}

pub fn layers(a: Args) Fail!void {
    try a.allow(&.{ "--layout", "--busybox", "--out" });
    const dir = try a.one("--layout");
    const l = try Layout.open(dir, try a.one("--busybox"));
    const got = l.entrypoint();
    const ep = blk: {
        if (got) |g| {
            if (g.len == 1 and g[0].len > 1 and C.startsWith(g[0], "/")) break :blk g[0];
        }
        return C.fail("the config's Entrypoint is not one absolute path: {s}", .{C.debugOptStrs(got)});
    };
    const last = try l.entries(l.layers.len - 1);
    const want = image.normalize(ep);
    const found = for (last) |e| {
        if (C.eql(image.normalize(e.path), want) and e.kind == .file and e.mode == 0o755) break true;
    } else false;
    if (!found) return C.fail("entrypoint {s} is not a regular file with mode 0755 in the image's last layer", .{ep});
    var out = C.list(u8);
    for (l.layers) |d| C.add(&out, C.fmt("{s}\n", .{d}));
    return writePath(try a.one("--out"), out.items);
}

/// Green only when the config's Entrypoint is exactly `[want]`: one
/// element, spelled the same (another path to the same file is red).
pub fn entrypointFinding(got: ?[]const []const u8, want: []const u8) Fail![]const u8 {
    if (got) |g| {
        if (g.len == 1 and C.eql(g[0], want)) return C.fmt("entrypoint {s}", .{want});
    }
    return C.fail("the config's Entrypoint is not [\"{s}\"]: {s}", .{ want, C.debugOptStrs(got) });
}

/// Every path the check reads: the entrypoint and each `--exec` as an
/// executable, each `--file` as a file, in that order.
pub fn wants(entrypoint: []const u8, execs: []const []const u8, files: []const []const u8) []image.Wanted {
    var w = C.list(image.Wanted);
    C.push(image.Wanted, &w, .{ .want = .exec, .path = entrypoint });
    for (execs) |p| C.push(image.Wanted, &w, .{ .want = .exec, .path = p });
    for (files) |p| C.push(image.Wanted, &w, .{ .want = .file, .path = p });
    return w.items;
}

/// What the check found, and its failures.
pub const Findings = struct { ok: [][]const u8, bad: [][]const u8 };

fn findings(a: Args) Fail!Findings {
    const dir = try a.one("--layout");
    const l = try Layout.open(dir, try a.one("--busybox"));
    const want_ep = try a.one("--entrypoint");
    var ok = C.list([]const u8);
    var bad = C.list([]const u8);
    const list = try readPath(try a.one("--layers"));
    if (!C.utf8Valid(list)) return C.failS("the layer list is not UTF-8");
    const listed = C.lines(list);
    const same = listed.len == l.layers.len and for (listed, l.layers) |x, y| {
        if (!C.eql(x, y)) break false;
    } else true;
    if (!same) {
        C.push([]const u8, &bad, C.fmt("the layer list is not the manifest's layers in order: list {s} | manifest {s}", .{ C.join(listed, " "), C.join(l.layers, " ") }));
    }
    if (entrypointFinding(l.entrypoint(), want_ep)) |f| {
        C.push([]const u8, &ok, f);
    } else |_| C.push([]const u8, &bad, C.msg);
    var fs = image.Fs.init();
    for (l.layers, 0..) |d, i| {
        const es = try l.entries(i);
        if (i == l.layers.len - 1) C.add2([]const u8, &bad, image.typeChanges(&fs, es));
        fs.apply(es) catch return C.fail("layer {s}: {s}", .{ d, C.msg });
    }
    C.push([]const u8, &ok, C.fmt("layers {d}", .{l.layers.len}));
    const r = image.checkPaths(&fs, wants(want_ep, a.all("--exec"), a.all("--file")));
    C.add2([]const u8, &ok, r.ok);
    C.add2([]const u8, &bad, r.bad);
    return .{ .ok = ok.items, .bad = bad.items };
}

pub fn check(a: Args) Fail!void {
    try a.allow(&.{ "--layout", "--busybox", "--layers", "--entrypoint", "--exec", "--file", "--out", "--expect-red" });
    const out = try a.one("--out");
    const expect = try a.opt("--expect-red");
    // An image that cannot be read is red too.
    const f: Findings = findings(a) catch blk: {
        const one = C.a().dupe([]const u8, &.{C.msg}) catch C.oom();
        break :blk .{ .ok = &.{}, .bad = one };
    };
    var listed = C.list(u8);
    for (f.bad) |b| C.add(&listed, C.fmt("\n  {s}", .{b}));
    const t = expect orelse {
        if (f.bad.len == 0) {
            var text = C.list(u8);
            for (f.ok) |x| C.add(&text, C.fmt("{s}\n", .{x}));
            return writePath(out, text.items);
        }
        return C.fail("{s}:{s}", .{ try a.one("--layout"), listed.items });
    };
    if (t.len == 0) return C.failS("--expect-red is empty");
    for (f.bad) |b| {
        if (C.contains(b, t)) return writePath(out, C.fmt("red as expected, naming `{s}`:{s}\n", .{ t, listed.items }));
    }
    if (f.bad.len == 0) return C.fail("green, want red naming `{s}`", .{t});
    return C.fail("red, but no failure names `{s}`:{s}", .{ t, listed.items });
}

pub fn run(argv: []const []const u8) Fail!void {
    const a = try Args.parse(argv);
    if (C.eql(a.cmd, "tree")) return treeCmd(a);
    if (C.eql(a.cmd, "image")) return imageCmd(a);
    if (C.eql(a.cmd, "layers")) return layers(a);
    if (C.eql(a.cmd, "check")) return check(a);
    return C.fail("unknown command `{s}` (tree, image, layers, check)", .{a.cmd});
}

/// What the process does with `argv`: its exit code and the bytes it writes
/// to stderr (main.zig writes them and exits, nothing more). An argument that
/// is not UTF-8 is refused before any command runs. A refusal is code 1 and
/// the one line `komira_oci: <refusal>`; Buck2 must not take a `--out` that a
/// late refusal left half written. Success is code 0 and no stderr.
pub const Outcome = struct { code: u8, stderr: []const u8 };

pub fn outcome(argv: []const []const u8) Outcome {
    for (argv, 0..) |arg, i| {
        if (!C.utf8Valid(arg)) return refused(C.fmt("argument {d} is not UTF-8: {s}", .{ i, C.debugOsStr(arg) }));
    }
    run(argv) catch return refused(C.msg);
    return .{ .code = 0, .stderr = "" };
}

fn refused(m: []const u8) Outcome {
    return .{ .code = 1, .stderr = C.fmt("komira_oci: {s}\n", .{m}) };
}
