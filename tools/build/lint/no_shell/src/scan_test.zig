//! Unit tests of the Starlark scan: what counts as a shell use, and what does
//! not (comments, other strings, a name inside a longer word).

const std = @import("std");
const scan = @import("scan.zig");
const t = std.testing;

fn n(c: scan.Counts, cat: scan.Category) usize {
    return c[@intFromEnum(cat)];
}

fn only(src: []const u8, cat: scan.Category, want: usize) !void {
    const c = scan.scan(src);
    try t.expectEqual(want, n(c, cat));
    try t.expectEqual(want, scan.total(c));
}

test "a shell's name or option word as an argument is a sh_argv site" {
    try only("cmd_args(bb, \"sh\", \"-euc\", s)", .sh_argv, 2);
    try only("['bash', 'dash', 'ash', 'zsh', 'ksh', 'mksh', \"-ec\"]", .sh_argv, 7);
}

test "a string that only holds a shell's name is not one" {
    try only("x = ['shell', 'sh_x', 'xsh', 'sh ', '-c', '-eu', 'bash.exe']", .sh_argv, 0);
}

test "busybox_sh as an identifier, a definition, an import and a string" {
    try only("load(\":t.bzl\", \"busybox_sh\")\ndef f():\n    return busybox_sh(bb, s)\n", .busybox_sh, 2);
    try only("def _busybox_sh(b, s):\n    return 1\nx = _busybox_sh(1, 2)\n", .busybox_sh, 2);
    try only("def busybox_shell(): pass\nx = my_busybox_sh_2\n", .busybox_sh, 0);
}

test "a shell path, or a #! line written into a script, is a shell_path site" {
    try only("p = \"/bin/sh\"\nq = '/bin/bash'\nr = \"/usr/bin/env sh\"\ns = '/usr/bin/env bash -e'", .shell_path, 4);
    try only("_L = \"\"\"#!/bin/sh\nexec \"$@\"\n\"\"\"\n", .shell_path, 1);
    try only("x = \"/bin/shx\"\n", .shell_path, 0);
}

test "a path ending in .sh is a sh_script site, with no space in it" {
    try only("export_file(name = \"run_check.sh\")\nx = 'tools/a/b.bash'", .sh_script, 2);
    try only("x = \"run it.sh\"\ny = \".sh\"\nz = \"a.shx\"\nw = \"a.sh \"", .sh_script, 0);
}

test "genrule and the sh_ rules are shell_rule sites; the same words in a string are not" {
    try only("genrule(name = \"x\", cmd = \"y\")\nsh_test(name = \"t\")\nsh_binary(name = \"b\")\nsh_library(name = \"l\")", .shell_rule, 4);
    try only("x = \"genrule\"\n# genrule(\ny = my_genrule\n", .shell_rule, 0);
}

test "comments are skipped, and a # inside a string is not a comment" {
    try only("# busybox_sh(\"sh\")\nx = 1  # \"sh\" busybox_sh\n", .sh_argv, 0);
    try only("x = \"a#b\"; y = \"sh\"\n", .sh_argv, 1);
}

test "a triple-quoted string is one literal: quotes and words inside it are not sites" {
    try only("s = \"\"\"echo \"sh\" busybox_sh\n'bash'\n\"\"\"\n", .sh_argv, 0);
    const c = scan.scan("s = \"\"\"echo \"sh\" busybox_sh\n\"\"\"\ny = \"sh\"\n");
    try t.expectEqual(@as(usize, 1), n(c, .sh_argv));
    try t.expectEqual(@as(usize, 0), n(c, .busybox_sh));
}

test "an escaped quote does not end a string" {
    try only("x = \"a\\\"sh\"\ny = \"sh\"\n", .sh_argv, 1);
    try only("x = 'it\\'s' + \"sh\"\n", .sh_argv, 1);
}

test "an unterminated string ends at its line" {
    try only("x = \"abc\ny = \"sh\"\n", .sh_argv, 1);
}

test "the scan of an empty or all-comment source is empty" {
    try only("", .sh_argv, 0);
    try only("# only\n# comments", .sh_argv, 0);
}

test "isBuildFile: BUCK, .bzl and .bxl files only" {
    try t.expect(scan.isBuildFile("BUCK"));
    try t.expect(scan.isBuildFile("a/b/BUCK"));
    try t.expect(scan.isBuildFile("a/defs.bzl"));
    try t.expect(scan.isBuildFile("a/checks.bxl"));
    try t.expect(!scan.isBuildFile("a/BUCK.md"));
    try t.expect(!scan.isBuildFile("a/notes.txt"));
    try t.expect(!scan.isBuildFile("a/MYBUCK"));
}

test "parseCategory names exactly the five categories" {
    for ([_][]const u8{ "busybox_sh", "sh_argv", "shell_path", "sh_script", "shell_rule" }) |c| {
        try t.expect(scan.parseCategory(c) != null);
    }
    try t.expect(scan.parseCategory("sh") == null);
    try t.expect(scan.parseCategory("") == null);
}
