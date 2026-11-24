//! macos_link: the `link` mode of mojo_compile on macOS
//! (mojo_compile_macos.zig), parsed and laid out without touching the file
//! system or the host:
//!
//!   mojo_compile link --deployment-target=<v> --macos-host=<id>... -- <cc arguments...>
//!
//! It links C on a macOS worker with the host's C driver, `/usr/bin/cc`
//! (and so the host's ld), as the compile's own link does: the same host
//! identity check (`--macos-host`, compile_args.hostAccepted) keeps a result
//! from being filed under a host toolchain the action key does not name. A
//! komira library's own shared library on darwin-arm64 is linked this way
//! (tools/build/native/shared.bzl).
//!
//! The driver gets an environment built from nothing (`env`): PATH of the
//! system's /usr/bin and /bin, MACOSX_DEPLOYMENT_TARGET, and TMPDIR and HOME
//! in the action's private scratch directory. Its arguments are the ones
//! after `--`, unchanged. Every refusal is exit 2 of the wrapper, with the
//! message in `Diag.msg`.

const std = @import("std");
const compile_args = @import("compile_args.zig");

const Diag = compile_args.Diag;
const Error = compile_args.Error;

/// The C driver the link runs: the host's, as the compile's cc shim does.
pub const host_cc = "/usr/bin/cc";

/// PATH of the driver: the system's own directories only.
pub const path = "/usr/bin:/bin";

pub const Options = struct {
    /// MACOSX_DEPLOYMENT_TARGET of the link.
    deployment_target: []const u8,
    /// The host identities the link may run on, in the order given; never empty.
    macos_hosts: []const []const u8,
    /// Everything after `--`, unchanged.
    cc_args: []const []const u8,
    /// The value after the last `-o` in `cc_args`.
    output: []const u8,
};

fn refuse(d: *Diag, alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Error {
    d.msg = std.fmt.allocPrint(alloc, fmt, args) catch return error.OutOfMemory;
    return error.Refused;
}

fn value(a: []const u8, prefix: []const u8) ?[]const u8 {
    return if (std.mem.startsWith(u8, a, prefix)) a[prefix.len..] else null;
}

/// The options after `link`. Refused: an unknown option, no `--`, no
/// deployment target, no `--macos-host` (a link that may run on no host), an
/// empty one, the local sentinel beside a real identity, no C driver
/// arguments, and no `-o <output>` among them.
pub fn parse(alloc: std.mem.Allocator, args: []const []const u8, d: *Diag) Error!Options {
    var deployment: []const u8 = "";
    var hosts = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) break;
        if (value(a, "--deployment-target=")) |v| {
            deployment = v;
        } else if (value(a, "--macos-host=")) |v| {
            if (v.len == 0) return refuse(d, alloc, "REFUSING: an empty --macos-host", .{});
            try hosts.append(alloc, v);
        } else {
            return refuse(d, alloc, "link: expected -- before the C driver's arguments (got '{s}')", .{a});
        }
    }
    if (i >= args.len) return refuse(d, alloc, "link: expected -- before the C driver's arguments", .{});
    if (deployment.len == 0) {
        return refuse(d, alloc, "usage: mojo_compile link --deployment-target=<v> --macos-host=<id>... -- <cc arguments...>", .{});
    }
    if (hosts.items.len == 0) {
        return refuse(d, alloc, "REFUSING: no --macos-host: the link names no macOS host it may run on ([komira_re] darwin_macos_hosts)", .{});
    }
    if (hosts.items.len > 1) {
        for (hosts.items) |h| if (std.mem.eql(u8, h, compile_args.local_host)) {
            return refuse(d, alloc, "REFUSING: --macos-host={s} (a build on this machine) beside other hosts: a link that names host identities is not a local one", .{compile_args.local_host});
        };
    }
    const cc_args = args[i + 1 ..];
    const output = compile_args.findOutput(cc_args) orelse "";
    if (output.len == 0) return refuse(d, alloc, "link: no -o <output> in the C driver's arguments", .{});
    return .{
        .deployment_target = deployment,
        .macos_hosts = try hosts.toOwnedSlice(alloc),
        .cc_args = cc_args,
        .output = output,
    };
}

/// The driver's environment, `NAME=value` each, in this order: PATH,
/// MACOSX_DEPLOYMENT_TARGET, TMPDIR (`<scratch>/tmp`), HOME (`<scratch>/home`).
pub fn env(alloc: std.mem.Allocator, o: Options, scratch: []const u8) ![]const []const u8 {
    const out = try alloc.alloc([]const u8, 4);
    out[0] = try std.fmt.allocPrint(alloc, "PATH={s}", .{path});
    out[1] = try std.fmt.allocPrint(alloc, "MACOSX_DEPLOYMENT_TARGET={s}", .{o.deployment_target});
    out[2] = try std.fmt.allocPrint(alloc, "TMPDIR={s}/tmp", .{scratch});
    out[3] = try std.fmt.allocPrint(alloc, "HOME={s}/home", .{scratch});
    return out;
}

/// The driver's argv: `/usr/bin/cc`, then the arguments after `--`.
pub fn argv(alloc: std.mem.Allocator, o: Options) ![]const []const u8 {
    const out = try alloc.alloc([]const u8, o.cc_args.len + 1);
    out[0] = host_cc;
    @memcpy(out[1..], o.cc_args);
    return out;
}

// ---- tests ---------------------------------------------------------------------

const testing = std.testing;

const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    diag: Diag,
    result: Error!Options,

    fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

fn tryParse(args: []const []const u8) Parsed {
    var p = Parsed{ .arena = std.heap.ArenaAllocator.init(testing.allocator), .diag = .{}, .result = undefined };
    p.result = parse(p.arena.allocator(), args, &p.diag);
    return p;
}

fn expectRefused(args: []const []const u8, want: []const u8) !void {
    var p = tryParse(args);
    defer p.deinit();
    if (p.result) |_| {
        std.debug.print("accepted, want a refusal naming '{s}'\n", .{want});
        return error.TestUnexpectedResult;
    } else |e| {
        try testing.expectEqual(error.Refused, e);
        if (std.mem.indexOf(u8, p.diag.msg, want) == null) {
            std.debug.print("refusal '{s}' does not name '{s}'\n", .{ p.diag.msg, want });
            return error.TestUnexpectedResult;
        }
    }
}

const host_a = "27.0-0123456789abcdef";
const host_b = "27.0-fedcba9876543210";

// Catches: hosts not accumulated in order, the driver's arguments altered, or
// the output read from the first `-o` rather than the last.
test "link options: hosts accumulate in order; the driver's arguments pass unchanged; the output is the last -o" {
    var p = tryParse(&.{ "--deployment-target=11.0", "--macos-host=" ++ host_a, "--macos-host=" ++ host_b, "--", "-dynamiclib", "-o", "first", "a.o", "-o", "lib/x.dylib", "-Wl,-install_name,@rpath/x.dylib" });
    defer p.deinit();
    const o = try p.result;
    try testing.expectEqualStrings("11.0", o.deployment_target);
    try testing.expectEqual(@as(usize, 2), o.macos_hosts.len);
    try testing.expectEqualStrings(host_a, o.macos_hosts[0]);
    try testing.expectEqualStrings(host_b, o.macos_hosts[1]);
    try testing.expectEqualStrings("lib/x.dylib", o.output);
    const want = [_][]const u8{ "-dynamiclib", "-o", "first", "a.o", "-o", "lib/x.dylib", "-Wl,-install_name,@rpath/x.dylib" };
    try testing.expectEqual(want.len, o.cc_args.len);
    for (want, o.cc_args) |w, g| try testing.expectEqualStrings(w, g);
}

// Catches: a link that may run on any host (no --macos-host accepted), the
// local sentinel mixed with a farm's identities, or an empty identity.
test "link options: no host, an empty host, and the local sentinel beside a real identity are refused; the lone sentinel is accepted" {
    try expectRefused(&.{ "--deployment-target=11.0", "--", "-o", "o" }, "no --macos-host");
    try expectRefused(&.{ "--deployment-target=11.0", "--macos-host=", "--", "-o", "o" }, "an empty --macos-host");
    try expectRefused(&.{ "--deployment-target=11.0", "--macos-host=local", "--macos-host=" ++ host_a, "--", "-o", "o" }, "beside other hosts");
    try expectRefused(&.{ "--deployment-target=11.0", "--macos-host=" ++ host_a, "--macos-host=local", "--", "-o", "o" }, "beside other hosts");
    var p = tryParse(&.{ "--deployment-target=11.0", "--macos-host=local", "--", "-o", "o" });
    defer p.deinit();
    const o = try p.result;
    try testing.expectEqualStrings("local", o.macos_hosts[0]);
}

// Catches: a link with no deployment target (the driver would take the
// host's own OS as the minimum), an option the mode does not know taken as
// the driver's, a missing `--`, and a link with no output for the post-check.
test "link options: no deployment target, an unknown option, no --, and no -o are refused" {
    try expectRefused(&.{ "--macos-host=" ++ host_a, "--", "-o", "o" }, "usage: mojo_compile link");
    try expectRefused(&.{ "--deployment-target=", "--macos-host=" ++ host_a, "--", "-o", "o" }, "usage: mojo_compile link");
    try expectRefused(&.{ "--deployment-target=11.0", "--macos-host=" ++ host_a, "--compiler=tc", "--", "-o", "o" }, "got '--compiler=tc'");
    try expectRefused(&.{ "--deployment-target=11.0", "--macos-host=" ++ host_a }, "expected -- before");
    try expectRefused(&.{ "--deployment-target=11.0", "--macos-host=" ++ host_a, "--", "a.o" }, "no -o <output>");
    try expectRefused(&.{ "--deployment-target=11.0", "--macos-host=" ++ host_a, "--", "a.o", "-o" }, "no -o <output>");
    try expectRefused(&.{ "--deployment-target=11.0", "--macos-host=" ++ host_a, "--" }, "no -o <output>");
}

// Catches: an environment inherited from the worker (a PATH that finds
// another cc or ld), the deployment target not given to the driver, and
// temporary files written outside the action's scratch directory.
test "link environment and argv: exactly PATH, MACOSX_DEPLOYMENT_TARGET, TMPDIR and HOME; /usr/bin/cc then the arguments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const o = Options{ .deployment_target = "11.0", .macos_hosts = &.{host_a}, .cc_args = &.{ "-o", "x.dylib", "a.o" }, .output = "x.dylib" };
    const e = try env(a, o, "/s/komira");
    const want_env = [_][]const u8{ "PATH=/usr/bin:/bin", "MACOSX_DEPLOYMENT_TARGET=11.0", "TMPDIR=/s/komira/tmp", "HOME=/s/komira/home" };
    try testing.expectEqual(want_env.len, e.len);
    for (want_env, e) |w, g| try testing.expectEqualStrings(w, g);
    const v = try argv(a, o);
    const want_argv = [_][]const u8{ "/usr/bin/cc", "-o", "x.dylib", "a.o" };
    try testing.expectEqual(want_argv.len, v.len);
    for (want_argv, v) |w, g| try testing.expectEqualStrings(w, g);
}
