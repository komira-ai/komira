//! uv_fidelity: capture what `uv publish` SENDS, against a loopback recorder
//! only, as the fixtures of kci_pkg_upload's fidelity test.
//!
//!   uv_fidelity capture --uv <uv> --out <dir>
//!       writes <case>.whl, <case>.METADATA and <case>.request for each case
//!       (uv_fidelity.zig) into <dir>
//!   uv_fidelity check --uv <uv> --fixtures <dir> --out <file>
//!       captures the same way and compares with the committed fixtures in
//!       <dir>, byte for byte (a `.request` after its random boundary is
//!       normalised); writes <file> only when every file is the same
//!
//! Exit: 0 done (check: the same); 1 check: DIFFERENT, a diff summary on
//! stderr, and nothing else; 2 bad usage; 3 cannot measure, a reason on
//! stderr: the recorder could not listen or its bound address is not
//! loopback (`fid.isLoopback`), the scratch directory, the probe wheel or
//! the recorder thread could not be made, uv could not be started or failed,
//! the recorder failed or saw not exactly one request, the
//! request is not the expected shape, or any other error (reading the
//! committed fixtures, writing the output). A fixture the capture writes but
//! that is not committed is DIFFERENT (1). A check that did not measure is
//! never a pass.
//!
//! Both run as Buck2 build actions (BUCK, `uv_fidelity_capture` and
//! `uv_fidelity_check`), so the recorder binds `fid.RECORDER_HOST`
//! (127.0.0.1) inside the action.
//!
//! NO REAL REGISTRY IS CONTACTED. The publish URL is
//! `http://<fid.RECORDER_HOST>:<ephemeral>/legacy/`; the credential is the fixed
//! placeholder of uv_fidelity.zig, passed as `--username`/`--password`; uv
//! runs with an environment of exactly HOME, XDG_CONFIG_HOME, UV_CACHE_DIR
//! (all in the action's scratch directory), UV_NO_CONFIG=1 and
//! UV_KEYRING_PROVIDER=disabled, plus `--no-config` and
//! `--trusted-publishing never`.

const std = @import("std");
const fid = @import("uv_fidelity.zig");
const Allocator = std.mem.Allocator;

const EXIT_DIFFERENT: u8 = 1;
const EXIT_USAGE: u8 = 2;
const EXIT_CANNOT_MEASURE: u8 = 3;

fn stderr() std.fs.File.DeprecatedWriter {
    return std.fs.File.stderr().deprecatedWriter();
}

fn usage(why: []const u8) noreturn {
    stderr().print("uv_fidelity: {s}\nusage: uv_fidelity capture --uv <uv> --out <dir>\n" ++
        "       uv_fidelity check --uv <uv> --fixtures <dir> --out <file>\n", .{why}) catch {};
    std.process.exit(EXIT_USAGE);
}

fn cannotMeasure(comptime fmt: []const u8, args: anytype) noreturn {
    stderr().print("uv_fidelity: CANNOT MEASURE: " ++ fmt ++ "\n", args) catch {};
    std.process.exit(EXIT_CANNOT_MEASURE);
}

// ---- The recorder -----------------------------------------------------------

const Recorder = struct {
    server: std.net.Server,
    /// The recorder thread's own arena: the main thread allocates while it runs.
    arena: std.heap.ArenaAllocator,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    captured: std.ArrayList(fid.Request),
    failure: ?anyerror = null,

    fn loop(r: *Recorder) void {
        while (!r.stop.load(.acquire)) {
            var fds = [_]std.posix.pollfd{.{ .fd = r.server.stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&fds, 100) catch |e| {
                r.failure = e;
                return;
            };
            if (ready == 0) continue;
            const conn = r.server.accept() catch |e| {
                r.failure = e;
                return;
            };
            defer conn.stream.close();
            r.serve(conn.stream) catch |e| {
                if (r.failure == null) r.failure = e;
            };
        }
    }

    /// Records every request of one connection and answers each `200 OK`,
    /// until uv closes it (by a reset, which is how uv ends: not a failure).
    fn serve(r: *Recorder, stream: std.net.Stream) !void {
        const a = r.arena.allocator();
        var buf = std.ArrayList(u8).empty;
        var chunk: [1 << 16]u8 = undefined;
        while (true) {
            while (try fid.parseRequest(a, buf.items)) |p| {
                try r.captured.append(a, p.request);
                try stream.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK");
                const rest = buf.items.len - p.consumed;
                std.mem.copyForwards(u8, buf.items[0..rest], buf.items[p.consumed..]);
                buf.shrinkRetainingCapacity(rest);
            }
            const n = stream.read(&chunk) catch |e| switch (e) {
                error.ConnectionResetByPeer => return,
                else => return e,
            };
            if (n == 0) return;
            try buf.appendSlice(a, chunk[0..n]);
        }
    }
};

// ---- Running uv -------------------------------------------------------------

const Ran = struct { ok: bool, why: []const u8, stdout: []const u8, stderr: []const u8 };

/// Runs argv with exactly `env`. It has no time limit of its own: a uv that
/// does not end is ended by the limit of the action that runs this.
fn run(a: Allocator, argv: []const []const u8, env: *const std.process.EnvMap) !Ran {
    var child = std.process.Child.init(argv, a);
    child.env_map = env;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var out = std.ArrayList(u8).empty;
    var err = std.ArrayList(u8).empty;
    const collected = child.collectOutput(a, &out, &err, 1 << 24);
    const term = child.wait();
    try collected;
    const t = try term;
    return switch (t) {
        .Exited => |c| .{
            .ok = c == 0,
            .why = try std.fmt.allocPrint(a, "exited {d}", .{c}),
            .stdout = out.items,
            .stderr = err.items,
        },
        else => .{ .ok = false, .why = "killed by a signal", .stdout = out.items, .stderr = err.items },
    };
}

/// uv's environment: nothing of the action's, no user configuration, cache,
/// keyring or credentials; every directory under `home`.
fn uvEnv(a: Allocator, home: []const u8) !std.process.EnvMap {
    var env = std.process.EnvMap.init(a);
    try env.put("HOME", home);
    try env.put("XDG_CONFIG_HOME", try std.fs.path.join(a, &.{ home, "xdg" }));
    try env.put("UV_CACHE_DIR", try std.fs.path.join(a, &.{ home, "uv-cache" }));
    try env.put("UV_NO_CONFIG", "1");
    try env.put("UV_KEYRING_PROVIDER", "disabled");
    return env;
}

/// The action's private scratch directory (absolute): BUCK_SCRATCH_PATH
/// when buck2 names one, else `.uv_fidelity` in the working directory (a
/// remote action has its working directory to itself).
fn scratch(a: Allocator) ![]const u8 {
    const rel = std.posix.getenv("BUCK_SCRATCH_PATH") orelse "";
    const dir = if (rel.len == 0) ".uv_fidelity" else try std.fs.path.join(a, &.{ rel, "uv_fidelity" });
    try std.fs.cwd().makePath(dir);
    return std.fs.cwd().realpathAlloc(a, dir);
}

fn tail(s: []const u8) []const u8 {
    const t = std.mem.trimRight(u8, s, " \r\n");
    return if (t.len > 800) t[t.len - 800 ..] else t;
}

fn writeFile(dir: std.fs.Dir, name: []const u8, data: []const u8) !void {
    const f = try dir.createFile(name, .{});
    defer f.close();
    try f.writeAll(data);
}

const Fixture = struct { name: []const u8, data: []const u8 };

fn putWheel(dist: []const u8, wheel: []const u8) !void {
    try std.fs.cwd().makePath(dist);
    var dist_dir = try std.fs.cwd().openDir(dist, .{});
    defer dist_dir.close();
    try writeFile(dist_dir, fid.WHEEL_NAME, wheel);
}

/// Publishes one probe wheel with uv at a fresh recorder; returns the case's
/// three fixture files.
fn captureCase(a: Allocator, uv: []const u8, root: []const u8, case: fid.Case, out: *std.ArrayList(Fixture)) !void {
    const home = try std.fs.path.join(a, &.{ root, case.name });
    const dist = try std.fs.path.join(a, &.{ home, "dist" });
    const wheel = fid.makeWheel(a, case.metadata) catch |e|
        cannotMeasure("{s}: cannot make the probe wheel: {s}", .{ case.name, @errorName(e) });
    putWheel(dist, wheel) catch |e|
        cannotMeasure("{s}: cannot write the probe wheel under {s}: {s}", .{ case.name, dist, @errorName(e) });

    const addr = std.net.Address.parseIp(fid.RECORDER_HOST, 0) catch |e|
        cannotMeasure("{s}: recorder address {s}: {s}", .{ case.name, fid.RECORDER_HOST, @errorName(e) });
    var rec = Recorder{
        .server = addr.listen(.{ .reuse_address = true }) catch |e|
            cannotMeasure("{s}: the recorder cannot listen on {s}: {s}", .{ case.name, fid.RECORDER_HOST, @errorName(e) }),
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .captured = undefined,
    };
    rec.captured = std.ArrayList(fid.Request).empty;
    defer rec.arena.deinit();
    defer rec.server.deinit();
    // The address the socket is actually bound to, from the kernel.
    var bound: std.net.Address = undefined;
    var bound_len: std.posix.socklen_t = @sizeOf(std.net.Address);
    std.posix.getsockname(rec.server.stream.handle, &bound.any, &bound_len) catch |e|
        cannotMeasure("{s}: cannot read the recorder's bound address: {s}", .{ case.name, @errorName(e) });
    if (!fid.isLoopback(bound))
        cannotMeasure("{s}: recorder is not loopback-only (bound to {f})", .{ case.name, bound });
    const port = bound.getPort();
    const thread = std.Thread.spawn(.{}, Recorder.loop, .{&rec}) catch |e|
        cannotMeasure("{s}: cannot start the recorder thread: {s}", .{ case.name, @errorName(e) });

    var env = try uvEnv(a, home);
    const url = try std.fmt.allocPrint(a, "http://{s}:{d}/legacy/", .{ fid.RECORDER_HOST, port });
    const wheel_path = try std.fs.path.join(a, &.{ dist, fid.WHEEL_NAME });
    const ran = run(a, &.{
        uv,
        "publish",
        "--no-config",
        "--trusted-publishing",
        "never",
        "--publish-url",
        url,
        "--username",
        fid.USERNAME,
        "--password",
        fid.PLACEHOLDER_PASSWORD,
        wheel_path,
    }, &env);
    rec.stop.store(true, .release);
    thread.join();
    const r = ran catch |e| cannotMeasure("{s}: uv did not run: {s}", .{ case.name, @errorName(e) });
    if (!r.ok) cannotMeasure("{s}: uv publish {s}: {s}", .{ case.name, r.why, tail(r.stderr) });
    if (rec.failure) |e| cannotMeasure("{s}: the recorder failed: {s}", .{ case.name, @errorName(e) });
    if (rec.captured.items.len != 1)
        cannotMeasure("{s}: expected ONE request at the recorder, got {d}", .{ case.name, rec.captured.items.len });
    const request = fid.renderRequest(a, rec.captured.items[0]) catch |e|
        cannotMeasure("{s}: {s}", .{ case.name, @errorName(e) });

    try out.append(a, .{ .name = try std.mem.concat(a, u8, &.{ case.name, ".whl" }), .data = wheel });
    try out.append(a, .{ .name = try std.mem.concat(a, u8, &.{ case.name, ".METADATA" }), .data = case.metadata });
    try out.append(a, .{ .name = try std.mem.concat(a, u8, &.{ case.name, ".request" }), .data = request });
}

fn uvVersion(a: Allocator, uv: []const u8, root: []const u8) []const u8 {
    var env = uvEnv(a, root) catch return "uv (version unknown)";
    const r = run(a, &.{ uv, "--version" }, &env) catch return "uv (version unknown)";
    return if (r.ok) std.mem.trim(u8, r.stdout, " \r\n") else "uv (version unknown)";
}

/// Every error not handled where it happens is a failure to measure (exit 3):
/// exit 1 is DIFFERENT only, and Zig would exit 1 for an error out of `main`.
pub fn main() void {
    runMain() catch |e| cannotMeasure("{s}", .{@errorName(e)});
}

fn runMain() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len < 2) usage("no mode");
    const mode = args[1];
    var uv: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var fixtures: ?[]const u8 = null;
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) usage("a flag without its value");
        const v = args[i + 1];
        if (std.mem.eql(u8, args[i], "--uv")) uv = v else if (std.mem.eql(u8, args[i], "--out")) out_path = v else if (std.mem.eql(u8, args[i], "--fixtures")) fixtures = v else usage("unknown flag");
    }
    const is_check = std.mem.eql(u8, mode, "check");
    if (!is_check and !std.mem.eql(u8, mode, "capture")) usage("the mode is capture or check");
    if (uv == null or out_path == null) usage("--uv and --out are required");
    if (is_check and fixtures == null) usage("check needs --fixtures");

    const root = scratch(a) catch |e| cannotMeasure("cannot make the scratch directory: {s}", .{@errorName(e)});
    const version = uvVersion(a, uv.?, root);
    var fresh = std.ArrayList(Fixture).empty;
    for (fid.CASES) |case| try captureCase(a, uv.?, root, case, &fresh);

    if (!is_check) {
        try std.fs.cwd().makePath(out_path.?);
        var dir = try std.fs.cwd().openDir(out_path.?, .{});
        defer dir.close();
        for (fresh.items) |f| try writeFile(dir, f.name, f.data);
        try stderr().print("uv_fidelity: wrote {d} fixtures from {s}\n", .{ fresh.items.len, version });
        return;
    }

    var report = std.ArrayList(u8).empty;
    var same = true;
    var committed_dir = try std.fs.cwd().openDir(fixtures.?, .{});
    defer committed_dir.close();
    for (fresh.items) |f| {
        const committed = committed_dir.readFileAlloc(a, f.name, 1 << 24) catch |e| switch (e) {
            // A fixture the capture writes but nobody committed is a difference.
            error.FileNotFound => {
                try report.writer(a).print("  {s}: not committed\n", .{f.name});
                same = false;
                continue;
            },
            // Any other read failure means nothing was compared.
            else => cannotMeasure("reading committed fixture {s}: {s}", .{ f.name, @errorName(e) }),
        };
        if (!try fid.compareFile(a, report.writer(a), f.name, committed, f.data)) same = false;
    }
    if (!same) {
        try stderr().print("uv_fidelity: FIDELITY DRIFT: {s} no longer sends what the committed fixtures " ++
            "(and so the Mojo client) send:\n{s}", .{ version, report.items });
        std.process.exit(EXIT_DIFFERENT);
    }
    const msg = try std.fmt.allocPrint(a, "uv fidelity fixtures reproduce under {s}: {d} files\n", .{ version, fresh.items.len });
    try writeFile(std.fs.cwd(), out_path.?, msg);
    try stderr().print("uv_fidelity: {s}", .{msg});
}
