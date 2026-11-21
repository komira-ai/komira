//! The cases of cli.zig: each mode's flags, the exit code and output of a
//! command that cannot run, and the archive reading on the two committed
//! archives (testdata/README.md): one System V archive of x86_64 ELF objects
//! and one BSD archive of arm64 Mach-O objects, built from the same C.

const std = @import("std");
const P = @import("prefix.zig");
const M = @import("cli.zig");

const eqs = std.testing.expectEqualStrings;
const expect = std.testing.expect;

fn expectFail(r: anytype, want: []const u8) !void {
    if (r) |_| {
        std.debug.print("want the refusal: {s}\n", .{want});
        return error.TestUnexpectedResult;
    } else |_| try eqs(want, P.msg);
}

const header_ok = [_][]const u8{ "prefix_tool", "header", "--archive", "l.a", "--header", "h", "--symbols", "s", "--style", "strip", "--prefix", "k_", "--min", "5" };
const check_ok = [_][]const u8{ "prefix_tool", "check", "--archive", "./no-such-archive.a", "--result", "r", "--prefix", "k_", "--min", "5" };

fn with(base: []const []const u8, more: []const []const u8) []const []const u8 {
    return std.mem.concat(P.a(), []const u8, &.{ base, more }) catch unreachable;
}

test "args: header and check, repeated flags kept in order" {
    const h = try M.Args.parse(with(&header_ok, &.{ "--extra", "b", "--strip", "s_", "--extra", "a" }));
    try eqs("header", h.mode);
    try eqs("s_", h.get("--strip"));
    try expect(h.list("--extra").len == 2);
    try eqs("b", h.list("--extra")[0]);
    try eqs("a", h.list("--extra")[1]);
    try expect((try h.min()) == 5);
    const c = try M.Args.parse(with(&check_ok, &.{ "--names", "n1", "--allow", "_Z*", "--names", "n2" }));
    try eqs("n2", c.list("--names")[1]);
    try eqs("_Z*", c.list("--allow")[0]);
    try expect(c.list("--extra").len == 0);
}

test "args: refusals" {
    try expectFail(M.Args.parse(&.{"prefix_tool"}), "prefix_tool: no mode");
    try expectFail(M.Args.parse(&.{ "prefix_tool", "nm" }), "prefix_tool: unknown mode nm");
    try expectFail(M.Args.parse(header_ok[0 .. header_ok.len - 2]), "prefix_tool header: --min is required");
    try expectFail(M.Args.parse(with(&header_ok, &.{"--extra"})), "prefix_tool: --extra needs a value");
    try expectFail(M.Args.parse(with(&header_ok, &.{ "--prefix", "j_" })), "prefix_tool: --prefix given twice");
    // Each mode takes only its own flags.
    try expectFail(M.Args.parse(with(&header_ok, &.{ "--allow", "x" })), "prefix_tool header: unknown flag --allow");
    try expectFail(M.Args.parse(with(&check_ok, &.{ "--extra", "x" })), "prefix_tool check: unknown flag --extra");
    try expectFail(M.Args.parse(with(&check_ok, &.{ "--strip", "x" })), "prefix_tool check: unknown flag --strip");
    const m = try M.Args.parse(with(header_ok[0 .. header_ok.len - 2], &.{ "--min", "-1" }));
    try expectFail(m.min(), "prefix_tool: --min -1 is not a number");
}

test "outcome: bad arguments exit 2 with the usage; a refusal exits 1" {
    const o = M.outcome(&.{ "prefix_tool", "nm" }, "/w");
    try expect(o.code == 2);
    try eqs("prefix_tool: unknown mode nm\n" ++ M.usage, o.stderr);
    const s = M.outcome(with(header_ok[0 .. header_ok.len - 6], &.{ "--style", "nope", "--prefix", "k_", "--min", "1" }), "/w");
    try expect(s.code == 1);
    try eqs("prefix_tool: unknown style nope\n", s.stderr);
    // An archive that cannot be read fails the command, before anything is written.
    const e = M.outcome(&check_ok, "/w");
    try expect(e.code == 1);
    try eqs("prefix_tool: cannot read ./no-such-archive.a: FileNotFound\n", e.stderr);
}

test "outcome: messages name the archive by its absolute path" {
    try eqs("/w/buck-out/l.a", M.shown("/w", "buck-out/l.a"));
    try eqs("/abs/l.a", M.shown("/w", "/abs/l.a"));
}

const elf_archive = @embedFile("testdata/elf_x86_64.a");
const macho_archive = @embedFile("testdata/macho_arm64.a");

// What fixture_one.c and fixture_second_member.c define with external
// linkage: a common symbol, data, a hidden function, a weak definition, two
// functions. `fx_local` (static) is in neither format's list.
const fixture_defined = [_][]const u8{ "fx_common_data", "fx_data", "fx_global", "fx_hidden", "fx_second", "fx_weak_def" };

test "archive: an ELF and a Mach-O archive of the same C give the same names" {
    for ([_][]const u8{ elf_archive, macho_archive }) |bytes| {
        const syms = try M.archiveSymbols(bytes, "/w/l.a");
        const names = P.sortedUnique(P.definedNames(syms));
        try expect(names.len == fixture_defined.len);
        for (fixture_defined, names) |w, g| try eqs(w, g);
        const t = P.symtabOf(syms);
        // fx_global is defined by the first member and referenced by the second.
        try expect(t.und.len == 3);
        try eqs("fx_global", t.und[0]);
        try eqs("fx_undefined", t.und[1]);
        try eqs("fx_weak_hook", t.und[2]);
        try expect(t.weak_und.len == 1);
        try eqs("fx_weak_hook", t.weak_und[0]);
    }
}

test "archive: the Mach-O names lose the one leading _ Mach-O gives a C name" {
    // The BSD symbol table of the Mach-O archive names `_fx_data`; the header
    // must rename `fx_data`, the name the C sources use.
    try expect(std.mem.indexOf(u8, macho_archive, "__.SYMDEF") != null);
    try expect(std.mem.indexOf(u8, macho_archive, "_fx_data\x00") != null);
    const names = P.definedNames(try M.archiveSymbols(macho_archive, "/w/l.a"));
    for (names) |n| try expect(!std.mem.startsWith(u8, n, "_"));
}

test "archive: the header of either archive is the same, byte for byte" {
    var headers: [2][]const u8 = undefined;
    for ([_][]const u8{ elf_archive, macho_archive }, 0..) |bytes, i| {
        const names = try P.symbols(P.definedNames(try M.archiveSymbols(bytes, "/w/l.a")), &.{}, "/w/l.a", 6);
        headers[i] = try P.header(.strip, "komira_fx_", "fx_", names);
    }
    try eqs(
        \\/* Generated by komira//tools/build/native (prefix_header.sh): 6 names,
        \\   each renamed to start with komira_fx_. */
        \\#ifndef KOMIRA_PREFIX_KOMIRA_FX_H
        \\#define KOMIRA_PREFIX_KOMIRA_FX_H
        \\#define fx_common_data komira_fx_common_data
        \\#define fx_data komira_fx_data
        \\#define fx_global komira_fx_global
        \\#define fx_hidden komira_fx_hidden
        \\#define fx_second komira_fx_second
        \\#define fx_weak_def komira_fx_weak_def
        \\#endif
        \\
    , headers[0]);
    try eqs(headers[0], headers[1]);
}

test "archive: the check reads either archive: red on the unprefixed names, green when allowed" {
    for ([_][]const u8{ elf_archive, macho_archive }) |bytes| {
        const syms = try M.archiveSymbols(bytes, "/w/l.a");
        const red = try P.check(syms, &.{"fx_undefined\n"}, "/w/l.a", "komira_", 0, &.{});
        try expect(red.red);
        try eqs("archive_check RED: 6 defined symbols without the prefix komira_ in /w/l.a:\n" ++
            "  fx_common_data\n  fx_data\n  fx_global\n  fx_hidden\n  fx_second\n  fx_weak_def\n" ++
            "archive_check RED: 1 weak undefined symbols without the prefix komira_ in /w/l.a:\n  fx_weak_hook\n" ++
            "archive_check RED: 1 undefined references to the library's own unprefixed names in /w/l.a:\n  fx_undefined\n", red.stderr);
        const green = try P.check(syms, &.{}, "/w/l.a", "fx_", 6, &.{});
        try expect(!green.red);
        try eqs("archive_check GREEN: 6 defined symbols start with fx_, 6 defined in all (the rest allowed); 1 weak undefined, each prefixed or allowed; no undefined reference among 0 unprefixed names (allowed without the prefix: -)\n", green.stdout);
    }
}

test "archive: what cannot be read is refused by name, never skipped" {
    try expectFail(M.archiveSymbols("not an archive", "/w/l.a"), "prefix_tool: /w/l.a: not an ar archive");
    try expectFail(M.archiveSymbols("!<arch>\n", "/w/l.a"), "prefix_tool: /w/l.a: an archive with no members");
    try expectFail(M.archiveSymbols("!<thin>\n", "/w/l.a"), "prefix_tool: /w/l.a: a thin archive (its members are not in it)");
    // Cut inside a member: its header says more bytes than the file holds.
    try expectFail(M.archiveSymbols(macho_archive[0 .. macho_archive.len - 1], "/w/l.a"), "prefix_tool: /w/l.a: a member lies outside the archive");
    try expectFail(M.archiveSymbols(elf_archive[0 .. elf_archive.len - 1], "/w/l.a"), "prefix_tool: /w/l.a: a member lies outside the archive");
}
