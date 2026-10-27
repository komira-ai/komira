//! cc_shim: the `cc` that `mojo build` links through (mojo_compile.zig runs
//! it when its argv[0] is one of `shim_names`).
//!
//! The wrapper writes `<scratch>/cc/shim.cfg` and names it in KOMIRA_CC_SHIM:
//! one line each for the zig executable (absolute), the zig target and the
//! run path, then one line per link-tail argument, in order. The shim drops
//! every run path the compiler asks for (it would name the action's
//! sandbox), rewrites the compiler's `-Xlinker` pairs into what zig's driver
//! takes, and runs
//!
//!   <zig> cc -target <target> -Wl,--strip-debug -Wl,--enable-new-dtags
//!       -Wl,-rpath,<runpath> <rewritten arguments> <link-tail lines>
//!
//! byte for byte: coverage's cov_zig recognises the link by that shape, and
//! `cov_branch link` (cov_branch_link.zig) reproduces it (test 47, link_line.sh).
//!
//! On macOS (mojo_compile_macos.zig) the first line of shim.cfg is the host's C
//! driver, `/usr/bin/cc`, and the shim runs `execLineMacos`.

const std = @import("std");

pub const shim_names = [_][]const u8{ "cc", "c++", "gcc", "g++", "clang", "clang++" };

pub fn isShimName(name: []const u8) bool {
    for (shim_names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

pub const Config = struct {
    zig: []const u8,
    target: []const u8,
    runpath: []const u8,
    tail: []const []const u8,
};

pub const ConfigError = error{ BadConfig, OutOfMemory };

/// The text of shim.cfg. A value holding a newline cannot be written.
pub fn renderConfig(alloc: std.mem.Allocator, c: Config) ConfigError![]const u8 {
    var out = std.ArrayList(u8).empty;
    const head = [_][]const u8{ c.zig, c.target, c.runpath };
    for (head) |v| try line(alloc, &out, v);
    for (c.tail) |v| try line(alloc, &out, v);
    return out.toOwnedSlice(alloc);
}

fn line(alloc: std.mem.Allocator, out: *std.ArrayList(u8), v: []const u8) ConfigError!void {
    if (std.mem.indexOfScalar(u8, v, '\n') != null) return error.BadConfig;
    try out.appendSlice(alloc, v);
    try out.append(alloc, '\n');
}

/// shim.cfg read back: at least three lines, every line ended by a newline.
pub fn parseConfig(alloc: std.mem.Allocator, text: []const u8) ConfigError!Config {
    if (text.len == 0 or text[text.len - 1] != '\n') return error.BadConfig;
    var lines = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text[0 .. text.len - 1], '\n');
    while (it.next()) |l| try lines.append(alloc, l);
    if (lines.items.len < 3) return error.BadConfig;
    return .{
        .zig = lines.items[0],
        .target = lines.items[1],
        .runpath = lines.items[2],
        .tail = lines.items[3..],
    };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn starts(a: []const u8, p: []const u8) bool {
    return std.mem.startsWith(u8, a, p);
}

/// The compiler's link arguments as zig's driver gets them (Linux).
///
///   -Xlinker -L<d> / -Xlinker -l<x>      -L<d> / -l<x>
///   -Xlinker --<opt>                     -Wl,--<opt>
///   -Xlinker -rpath|--rpath|-R, + value  dropped, with the next value (bare or a -Xlinker pair)
///   -Xlinker -rpath=* / --rpath=*        dropped
///   -Xlinker -<opt>                      passed; the next -Xlinker pair passes verbatim (that
///                                        expectation survives other arguments)
///   -Xlinker <value>                     <value>
///   -rpath|--rpath <p>, -Wl,-rpath <p>, -Wl,--rpath <p>                  dropped, both
///   -Wl,-rpath,* -Wl,-rpath=* -Wl,--rpath,* -Wl,--rpath=* -Wl,-R,*       dropped
///   -Wl,-L* / -Wl,-l*                    without the -Wl,
///   a trailing -Xlinker                  passed (unless a run path value was expected)
pub fn rewriteLinux(alloc: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var expect_val = false;
    var drop_val = false;
    var i: usize = 0;
    while (i < args.len) {
        const a = args[i];
        i += 1;
        if (eql(a, "-Xlinker") and i < args.len) {
            const b = args[i];
            i += 1;
            if (drop_val) {
                drop_val = false;
                continue;
            }
            if (expect_val) {
                expect_val = false;
                try out.appendSlice(alloc, &.{ a, b });
                continue;
            }
            if (eql(b, "-rpath") or eql(b, "--rpath") or eql(b, "-R")) {
                drop_val = true;
            } else if (starts(b, "-rpath=") or starts(b, "--rpath=")) {
                // dropped
            } else if (starts(b, "-L") or starts(b, "-l")) {
                try out.append(alloc, b);
            } else if (starts(b, "--")) {
                try out.append(alloc, try std.fmt.allocPrint(alloc, "-Wl,{s}", .{b}));
            } else if (starts(b, "-")) {
                expect_val = true;
                try out.appendSlice(alloc, &.{ a, b });
            } else {
                try out.append(alloc, b);
            }
            continue;
        }
        if (drop_val) {
            drop_val = false;
            continue;
        }
        if (eql(a, "-rpath") or eql(a, "--rpath")) {
            drop_val = true;
            continue;
        }
        if (starts(a, "-Wl,-rpath,") or starts(a, "-Wl,-rpath=") or starts(a, "-Wl,--rpath,") or
            starts(a, "-Wl,--rpath=") or starts(a, "-Wl,-R,"))
        {
            continue;
        }
        if (eql(a, "-Wl,-rpath") or eql(a, "-Wl,--rpath")) {
            drop_val = true;
            continue;
        }
        if (starts(a, "-Wl,-L") or starts(a, "-Wl,-l")) {
            try out.append(alloc, a["-Wl,".len..]);
            continue;
        }
        try out.append(alloc, a);
    }
    return out.toOwnedSlice(alloc);
}

/// The argv the shim executes (Linux): argv[0] is the absolute zig path.
pub fn execLineLinux(alloc: std.mem.Allocator, c: Config, args: []const []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    try out.appendSlice(alloc, &.{
        c.zig,
        "cc",
        "-target",
        c.target,
        "-Wl,--strip-debug",
        "-Wl,--enable-new-dtags",
        try std.fmt.allocPrint(alloc, "-Wl,-rpath,{s}", .{c.runpath}),
    });
    try out.appendSlice(alloc, try rewriteLinux(alloc, args));
    try out.appendSlice(alloc, c.tail);
    return out.toOwnedSlice(alloc);
}

/// The compiler's link arguments as the host's cc gets them (macOS):
///
///   -Xlinker -rpath -Xlinker <p>         dropped, all four
///   -Xlinker -rpath (no -Xlinker pair after it)   dropped, the two
///   -Xlinker <x>                         passed, the pair
///   -Wl,-rpath,*                         dropped
///   -rpath <p>                           dropped, both
///   a trailing -Xlinker                  passed
pub fn rewriteMacos(alloc: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < args.len) {
        const a = args[i];
        i += 1;
        if (eql(a, "-Xlinker") and i < args.len) {
            if (eql(args[i], "-rpath")) {
                i += 1;
                if (args.len - i >= 2 and eql(args[i], "-Xlinker")) i += 2;
                continue;
            }
            try out.appendSlice(alloc, &.{ a, args[i] });
            i += 1;
            continue;
        }
        if (starts(a, "-Wl,-rpath,")) continue;
        if (eql(a, "-rpath")) {
            if (i < args.len) i += 1;
            continue;
        }
        try out.append(alloc, a);
    }
    return out.toOwnedSlice(alloc);
}

/// The argv the shim executes (macOS). shim.cfg's first line is the C driver
/// (`/usr/bin/cc`, the host's, which links with the host's ld) and its second
/// the deployment target, which reaches the link as MACOSX_DEPLOYMENT_TARGET,
/// not as an argument:
///
///   <driver> -Wl,-S -Wl,-rpath,<runpath> <rewritten arguments> <link-tail lines>
///
/// `-Wl,-S` keeps debug-map entries (naming object files inside the sandbox)
/// out of the output.
pub fn execLineMacos(alloc: std.mem.Allocator, c: Config, args: []const []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    try out.appendSlice(alloc, &.{
        c.zig,
        "-Wl,-S",
        try std.fmt.allocPrint(alloc, "-Wl,-rpath,{s}", .{c.runpath}),
    });
    try out.appendSlice(alloc, try rewriteMacos(alloc, args));
    try out.appendSlice(alloc, c.tail);
    return out.toOwnedSlice(alloc);
}

// ---- tests -------------------------------------------------------------------

const testing = std.testing;

fn expectRewrite(in: []const []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try rewriteLinux(arena.allocator(), in);
    if (got.len != want.len) {
        std.debug.print("rewrite gave {d} arguments, want {d}:\n", .{ got.len, want.len });
        for (got) |g| std.debug.print("  got  {s}\n", .{g});
        for (want) |w| std.debug.print("  want {s}\n", .{w});
        return error.TestUnexpectedResult;
    }
    for (got, want) |g, w| try testing.expectEqualStrings(w, g);
}

// One test per row of the rewrite table (design item 15). Each catches the
// row's arguments reaching zig in the wrong form: a run path naming the
// sandbox, or a linker flag zig's driver rejects.
test "shim: -Xlinker -L<d> and -Xlinker -l<x> become plain driver flags" {
    try expectRewrite(&.{ "-Xlinker", "-L/d", "-Xlinker", "-lfoo", "a.o" }, &.{ "-L/d", "-lfoo", "a.o" });
}

test "shim: -Xlinker --<opt> becomes -Wl,--<opt>" {
    try expectRewrite(&.{ "-Xlinker", "--gc-sections", "-Xlinker", "--" }, &.{ "-Wl,--gc-sections", "-Wl,--" });
}

test "shim: -Xlinker -rpath|--rpath|-R drops the pair and the next value, bare or as a pair" {
    try expectRewrite(&.{ "-Xlinker", "-rpath", "-Xlinker", "/p", "a.o" }, &.{"a.o"});
    try expectRewrite(&.{ "-Xlinker", "--rpath", "/bare", "a.o" }, &.{"a.o"});
    try expectRewrite(&.{ "-Xlinker", "-R", "-Xlinker", "/r", "b.o" }, &.{"b.o"});
}

test "shim: -Xlinker -rpath=* and --rpath=* are dropped" {
    try expectRewrite(&.{ "-Xlinker", "-rpath=/x", "-Xlinker", "--rpath=/y", "a.o" }, &.{"a.o"});
}

test "shim: -Xlinker -<opt> passes and its value pair passes verbatim, across other arguments" {
    try expectRewrite(&.{ "-Xlinker", "-soname", "-Xlinker", "libx.so" }, &.{ "-Xlinker", "-soname", "-Xlinker", "libx.so" });
    // The expectation survives a non -Xlinker argument and ends at the next
    // pair, whatever it holds (here a run path, passed verbatim).
    try expectRewrite(&.{ "-Xlinker", "-z", "keep.o", "-Xlinker", "-rpath" }, &.{ "-Xlinker", "-z", "keep.o", "-Xlinker", "-rpath" });
}

test "shim: a -Xlinker <value> not after an option loses its -Xlinker" {
    try expectRewrite(&.{ "-Xlinker", "bare.o" }, &.{"bare.o"});
}

test "shim: -rpath|--rpath <p> and -Wl,-rpath|-Wl,--rpath <p> drop both" {
    try expectRewrite(&.{ "-rpath", "/p1", "--rpath", "/p2", "-Wl,-rpath", "/p3", "-Wl,--rpath", "/p4", "a.o" }, &.{"a.o"});
}

// Mutant planted: keep `-Wl,-rpath=`.
test "shim: -Wl,-rpath,* -Wl,-rpath=* -Wl,--rpath,* -Wl,--rpath=* -Wl,-R,* are dropped" {
    try expectRewrite(&.{ "-Wl,-rpath,/a", "-Wl,-rpath=/b", "-Wl,--rpath,/c", "-Wl,--rpath=/d", "-Wl,-R,/e", "a.o" }, &.{"a.o"});
}

test "shim: -Wl,-L* and -Wl,-l* lose the -Wl," {
    try expectRewrite(&.{ "-Wl,-L/f", "-Wl,-lg", "-Wl,--as-needed" }, &.{ "-L/f", "-lg", "-Wl,--as-needed" });
}

test "shim: a trailing -Xlinker passes through" {
    try expectRewrite(&.{ "a.o", "-Xlinker" }, &.{ "a.o", "-Xlinker" });
    // ...unless a run path value was expected: then it is that value.
    try expectRewrite(&.{ "-rpath", "-Xlinker" }, &.{});
}

// Catches any change to the link line cov_zig and cov_branch_link.zig read.
// Mutant planted: drop -Wl,--enable-new-dtags.
test "shim: the exact exec line, link tail last in order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const c = Config{ .zig = "/z/zig", .target = "x86_64-linux-gnu.2.34", .runpath = "$ORIGIN/lib", .tail = &.{ "libb.a", "-lc++" } };
    const got = try execLineLinux(arena.allocator(), c, &.{ "-Xlinker", "-rpath", "-Xlinker", "/sandbox/lib", "main.o", "-o", "out" });
    const want = [_][]const u8{ "/z/zig", "cc", "-target", "x86_64-linux-gnu.2.34", "-Wl,--strip-debug", "-Wl,--enable-new-dtags", "-Wl,-rpath,$ORIGIN/lib", "main.o", "-o", "out", "libb.a", "-lc++" };
    try testing.expectEqual(want.len, got.len);
    for (got, want) |g, w| try testing.expectEqualStrings(w, g);
}

test "shim: the six names" {
    for ([_][]const u8{ "cc", "c++", "gcc", "g++", "clang", "clang++" }) |n| try testing.expect(isShimName(n));
    try testing.expect(!isShimName("mojo_compile"));
    try testing.expect(!isShimName("ld"));
}

test "shim.cfg: round trip; a newline in a value and a short file are refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = Config{ .zig = "/z/zig", .target = "t", .runpath = "$ORIGIN/lib", .tail = &.{ "x.a", "", "-lm" } };
    const text = try renderConfig(a, c);
    try testing.expectEqualStrings("/z/zig\nt\n$ORIGIN/lib\nx.a\n\n-lm\n", text);
    const back = try parseConfig(a, text);
    try testing.expectEqualStrings("/z/zig", back.zig);
    try testing.expectEqualStrings("t", back.target);
    try testing.expectEqualStrings("$ORIGIN/lib", back.runpath);
    try testing.expectEqual(@as(usize, 3), back.tail.len);
    try testing.expectEqualStrings("", back.tail[1]);
    try testing.expectEqualStrings("-lm", back.tail[2]);
    try testing.expectError(error.BadConfig, renderConfig(a, .{ .zig = "/z\n", .target = "t", .runpath = "r", .tail = &.{} }));
    try testing.expectError(error.BadConfig, parseConfig(a, "/z/zig\nt\n"));
    try testing.expectError(error.BadConfig, parseConfig(a, "/z/zig\nt\nr"));
    try testing.expectError(error.BadConfig, parseConfig(a, ""));
    const no_tail = try parseConfig(a, "/z/zig\nt\nr\n");
    try testing.expectEqual(@as(usize, 0), no_tail.tail.len);
}

// ---- macOS -------------------------------------------------------------------

fn expectRewriteMacos(in: []const []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try rewriteMacos(arena.allocator(), in);
    if (got.len != want.len) {
        std.debug.print("macOS rewrite gave {d} arguments, want {d}:\n", .{ got.len, want.len });
        for (got) |g| std.debug.print("  got  {s}\n", .{g});
        for (want) |w| std.debug.print("  want {s}\n", .{w});
        return error.TestUnexpectedResult;
    }
    for (got, want) |g, w| try testing.expectEqualStrings(w, g);
}

// Each catches a run path naming the action's sandbox reaching the host's
// linker (design item 18). Mutant planted: keep `-Wl,-rpath,`.
test "macOS shim: the three run path forms drop; another -Xlinker pair passes" {
    try expectRewriteMacos(&.{ "-Xlinker", "-rpath", "-Xlinker", "/sandbox/lib", "x.o" }, &.{"x.o"});
    try expectRewriteMacos(&.{ "-Wl,-rpath,/sandbox/q", "x.o" }, &.{"x.o"});
    try expectRewriteMacos(&.{ "-rpath", "/sandbox/z", "x.o" }, &.{"x.o"});
    try expectRewriteMacos(&.{ "-Xlinker", "-install_name", "-Xlinker", "@rpath/x.dylib" }, &.{ "-Xlinker", "-install_name", "-Xlinker", "@rpath/x.dylib" });
    try expectRewriteMacos(&.{ "-Xlinker", "-L/l", "-lm" }, &.{ "-Xlinker", "-L/l", "-lm" });
}

// The shell's edges, kept: an -Xlinker -rpath with no pair after it drops
// the two; a trailing -Xlinker and a trailing -rpath.
test "macOS shim: incomplete forms at the end of the line" {
    try expectRewriteMacos(&.{ "x.o", "-Xlinker", "-rpath" }, &.{"x.o"});
    try expectRewriteMacos(&.{ "x.o", "-Xlinker", "-rpath", "-Xlinker" }, &.{ "x.o", "-Xlinker" });
    try expectRewriteMacos(&.{ "x.o", "-Xlinker" }, &.{ "x.o", "-Xlinker" });
    try expectRewriteMacos(&.{ "x.o", "-rpath" }, &.{"x.o"});
}

// The line the retired darwin/cc shell shim gave for the same input
// (functional/darwin/check.sh's golden), byte for byte.
test "macOS shim: the exact exec line, link tail last in order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = Config{ .zig = "/usr/bin/cc", .target = "11.0", .runpath = "@loader_path/lib", .tail = &.{} };
    const got = try execLineMacos(a, c, &.{ "-o", "out", "-Xlinker", "-rpath", "-Xlinker", "/sandbox/lib", "x.o", "-Xlinker", "-L/l", "-Wl,-rpath,/q", "-rpath", "/z", "-lm" });
    const want = [_][]const u8{ "/usr/bin/cc", "-Wl,-S", "-Wl,-rpath,@loader_path/lib", "-o", "out", "x.o", "-Xlinker", "-L/l", "-lm" };
    try testing.expectEqual(want.len, got.len);
    for (got, want) |g, w| try testing.expectEqualStrings(w, g);
    const c2 = Config{ .zig = "/usr/bin/cc", .target = "11.0", .runpath = "@loader_path/../..", .tail = &.{ "libc.a", "-lc++" } };
    const got2 = try execLineMacos(a, c2, &.{ "-o", "out", "x.o" });
    const want2 = [_][]const u8{ "/usr/bin/cc", "-Wl,-S", "-Wl,-rpath,@loader_path/../..", "-o", "out", "x.o", "libc.a", "-lc++" };
    try testing.expectEqual(want2.len, got2.len);
    for (got2, want2) |g, w| try testing.expectEqualStrings(w, g);
}
