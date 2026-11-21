//! Helpers of the cases of pypi_smoke: wheels made in memory, an index and a command runner that answer from
//! tables, and scratch paths. Nothing here touches the network, a clock or a real process.
const std = @import("std");
const lib = @import("pypi_smoke_lib");

pub const rbf = lib.fetch;
pub const zip = lib.zip;
const t = std.testing;
const Alloc = std.mem.Allocator;

/// What a test wheel holds; the defaults are komira's wheel.
pub const WheelSpec = struct {
    name: []const u8 = "komira",
    version: []const u8 = "0.1.7",
    tag: []const u8 = "py3-none-manylinux_2_34_x86_64",
    /// The `Tag:` lines of WHEEL; null is the one line `tag`.
    tags: ?[]const []const u8 = null,
    requires_python: ?[]const u8 = ">=3.13",
    requires_dist: []const []const u8 = &.{"mojo-compiler==1.0.0"},
    /// The .dist-info directory's name; null is the one the name and version give.
    info: ?[]const u8 = null,
    with_metadata: bool = true,
    with_second_info: bool = false,
    payload: []const u8 = "print('hello')\n",
};

pub fn makeWheel(a: Alloc, spec: WheelSpec) ![]u8 {
    const normal = try lib.meta.normalizeName(a, spec.name);
    const info = spec.info orelse try std.fmt.allocPrint(a, "{s}-{s}.dist-info", .{ normal, spec.version });
    var md = std.Io.Writer.Allocating.init(a);
    try md.writer.print("Metadata-Version: 2.4\nName: {s}\nVersion: {s}\n", .{ spec.name, spec.version });
    if (spec.requires_python) |rp| try md.writer.print("Requires-Python: {s}\n", .{rp});
    for (spec.requires_dist) |r| try md.writer.print("Requires-Dist: {s}\n", .{r});
    try md.writer.writeAll("Summary: a wheel for the cases\n\nthe description\n");
    var wh = std.Io.Writer.Allocating.init(a);
    try wh.writer.writeAll("Wheel-Version: 1.0\nGenerator: cases\nRoot-Is-Purelib: false\n");
    const own = [_][]const u8{spec.tag};
    const tags: []const []const u8 = spec.tags orelse &own;
    for (tags) |tag| try wh.writer.print("Tag: {s}\n", .{tag});
    var members = std.ArrayList(zip.Member).empty;
    try members.append(a, .{ .name = "komira/__init__.py", .data = spec.payload });
    if (spec.with_metadata) try members.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}/METADATA", .{info}), .data = md.written() });
    try members.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}/WHEEL", .{info}), .data = wh.written() });
    if (spec.with_second_info) {
        try members.append(a, .{ .name = "other-1.0.dist-info/METADATA", .data = "Name: other\nVersion: 1.0\n" });
        try members.append(a, .{ .name = "other-1.0.dist-info/WHEEL", .data = "Tag: py3-none-any\n" });
    }
    var d: lib.common.Diag = .{};
    return zip.write(a, &d, members.items, .{});
}

/// A wheel the driver has read.
pub fn built(a: Alloc, spec: WheelSpec) !lib.meta.Wheel {
    var why: []const u8 = "";
    return lib.meta.parseWheel(a, &why, try makeWheel(a, spec));
}

pub fn hex(a: Alloc, bytes: []const u8) ![]u8 {
    const h = lib.common.hexSha(bytes);
    return a.dupe(u8, &h);
}

pub const Listed = struct { file: []const u8, sha256: []const u8, size: usize, url: []const u8 };

/// The JSON of a release as an index answers it, with the fields the driver does not read as well.
pub fn releaseJson(a: Alloc, listed: []const Listed) ![]u8 {
    var w = std.Io.Writer.Allocating.init(a);
    try w.writer.writeAll("{\"info\":{\"name\":\"komira\"},\"urls\":[");
    for (listed, 0..) |l, i| {
        if (i != 0) try w.writer.writeAll(",");
        try w.writer.print("{{\"filename\":\"{s}\",\"size\":{d},\"digests\":{{\"md5\":\"00\",\"sha256\":\"{s}\"}},\"url\":\"{s}\",\"yanked\":false,\"packagetype\":\"bdist_wheel\"}}", .{ l.file, l.size, l.sha256, l.url });
    }
    try w.writer.writeAll("]}");
    return w.written();
}

pub const Route = struct { url: []const u8, got: rbf.Got };

/// An index and a file host in memory: a table of answers, 404 for any other URL.
pub const Fake = struct {
    alloc: Alloc,
    routes: []const Route,
    /// Every URL asked, in order, and the `max` it was asked with.
    urls: std.ArrayList([]const u8) = .empty,
    maxes: std.ArrayList(usize) = .empty,
    /// The first this many requests for a release's JSON answer 404: an index that lags an upload.
    lag: usize = 0,
    json_hits: usize = 0,

    pub fn fetcher(self: *Fake) rbf.Fetcher {
        return .{ .ctx = self, .getFn = get };
    }

    fn get(ctx: *anyopaque, _: Alloc, url: []const u8, max: usize) rbf.Got {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.urls.append(self.alloc, url) catch @panic("out of memory");
        self.maxes.append(self.alloc, max) catch @panic("out of memory");
        if (std.mem.endsWith(u8, url, "/json")) {
            self.json_hits += 1;
            if (self.json_hits <= self.lag) return .{ .status = 404 };
        }
        for (self.routes) |r| if (std.mem.eql(u8, r.url, url)) return r.got;
        return .{ .status = 404 };
    }
};

/// What a command of a `FakeRunner` answers when its line contains `contains`.
pub const Rule = struct {
    contains: []const u8,
    code: ?u8 = 1,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    /// The runner's error: the command cannot be started.
    spawn: ?anyerror = null,
    /// How many commands the rule applies to; then they succeed.
    times: usize = std.math.maxInt(usize),
};

/// A command runner in memory: records each command (its work directory shown as `W`) and its directory, answers
/// from `rules`, and otherwise succeeds, with `pip show`'s and the example's output as set.
pub const FakeRunner = struct {
    alloc: Alloc,
    work: []const u8,
    rules: []const Rule = &.{},
    /// How many commands each rule has answered.
    hits: std.ArrayList(usize) = .empty,
    calls: std.ArrayList([]const u8) = .empty,
    cwds: std.ArrayList([]const u8) = .empty,
    shown_version: []const u8 = "0.1.7",
    example_output: []const u8 = "0.1.7\n1001\nregistered readings\nTrue\n",

    pub fn runner(self: *FakeRunner) lib.install.Runner {
        return .{ .ctx = self, .runFn = run };
    }

    fn run(ctx: *anyopaque, a: Alloc, argv: []const []const u8, cwd: []const u8) anyerror!lib.install.Ran {
        const self: *FakeRunner = @ptrCast(@alignCast(ctx));
        const line = try std.mem.replaceOwned(u8, self.alloc, try std.mem.join(a, " ", argv), self.work, "W");
        try self.calls.append(self.alloc, line);
        try self.cwds.append(self.alloc, try self.alloc.dupe(u8, cwd));
        while (self.hits.items.len < self.rules.len) try self.hits.append(self.alloc, 0);
        for (self.rules, 0..) |r, i| {
            if (self.hits.items[i] >= r.times or std.mem.indexOf(u8, line, r.contains) == null) continue;
            self.hits.items[i] += 1;
            if (r.spawn) |e| return e;
            return .{ .code = r.code, .stdout = r.stdout, .stderr = r.stderr };
        }
        if (std.mem.endsWith(u8, line, " show komira")) return .{ .code = 0, .stdout = try std.fmt.allocPrint(a, "Name: komira\nVersion: {s}\nSummary: x\n", .{self.shown_version}) };
        if (std.mem.endsWith(u8, line, " freeze")) return .{ .code = 0, .stdout = try std.fmt.allocPrint(a, "komira=={s}\n", .{self.shown_version}) };
        if (std.mem.indexOf(u8, line, "find_spec") != null) return .{ .code = 0, .stdout = "none\n" };
        if (std.mem.endsWith(u8, line, " -I quickstart.py")) return .{ .code = 0, .stdout = self.example_output };
        return .{ .code = 0 };
    }
};

/// The absolute path of `rel` in the scratch directory.
pub fn path(a: Alloc, tmp: *t.TmpDir, rel: []const u8) ![]u8 {
    const root = try tmp.dir.realpathAlloc(a, ".");
    return std.fs.path.join(a, &.{ root, rel });
}

pub fn sink(a: Alloc) std.Io.Writer.Allocating {
    return std.Io.Writer.Allocating.init(a);
}

pub fn readAll(a: Alloc, tmp: *t.TmpDir, rel: []const u8) ![]u8 {
    return tmp.dir.readFileAlloc(a, rel, 1 << 28);
}
