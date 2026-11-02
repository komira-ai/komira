//! The case of snappy's committed snappy-stubs-public.h, //third_party/snappy:stubs_cases: a `zig_test` run
//! as a build action. The subjects (the zig_test's `data`, under KOMIRA_TEST_WORK) are the committed header,
//! snappy's own snappy-stubs-public.h.in out of the pinned archive, and the header `:src` generates from that
//! template with its `substitutions` (`:src[snappy-stubs-public.h]`, the file the older rules compile with).
//!
//! Why a test: the `native_library` of this package takes the header as a file of the package (it cannot
//! stage a header another rule generates), so it is committed. It must be byte for byte what `:src` writes,
//! so that both rules compile snappy against the same header. Reading the generated file, not the BUCK text,
//! means only the substitutions `:src` applies count: a value changed in `:src` while the old one survives in
//! a comment or another target still changes the generated header, and fails here.
//!
//! What `verify` refuses (each has a case below, on in-memory text):
//!  - a committed header that differs from the generated one (edited by hand, a substitution value changed
//!    in `:src`, a pin moved to a release with another template): `error.Drift`;
//!  - a generated header that still holds a `${...}` placeholder (a placeholder of the template that `:src`
//!    has no substitution for, or one the template gained): `error.UnsubstitutedPlaceholder`;
//!  - a generated header that is not the template with its placeholders replaced (a line of the template
//!    without a placeholder is missing or changed): `error.NotFromTemplate`.

const std = @import("std");
const t = std.testing;

const VerifyError = error{ Drift, UnsubstitutedPlaceholder, NotFromTemplate };

fn readData(ar: std.mem.Allocator, name: []const u8) ![]const u8 {
    const w = try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
    return std.fs.cwd().readFileAlloc(ar, try std.fs.path.join(ar, &.{ w, name }), 1 << 20);
}

/// The committed header against the template and the header generated from it.
fn verify(template: []const u8, generated: []const u8, committed: []const u8) VerifyError!void {
    if (std.mem.indexOf(u8, generated, "${") != null) return error.UnsubstitutedPlaceholder;
    var tl = std.mem.splitScalar(u8, template, '\n');
    var gl = std.mem.splitScalar(u8, generated, '\n');
    while (tl.next()) |tline| {
        const gline = gl.next() orelse return error.NotFromTemplate;
        if (std.mem.indexOf(u8, tline, "${") == null and !std.mem.eql(u8, tline, gline)) return error.NotFromTemplate;
    }
    if (gl.next() != null) return error.NotFromTemplate;
    if (!std.mem.eql(u8, generated, committed)) return error.Drift;
}

test "the committed snappy-stubs-public.h is the header :src generates from the pinned template" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try verify(
        try readData(ar, "snappy-stubs-public.h.in"),
        try readData(ar, "generated/snappy-stubs-public.h"),
        try readData(ar, "snappy-stubs-public.h"),
    );
}

const tmpl = "#define SNAPPY_MAJOR ${PROJECT_VERSION_MAJOR}\n#define SNAPPY_MINOR ${PROJECT_VERSION_MINOR}\n#include <cstddef>\n";
const gen = "#define SNAPPY_MAJOR 1\n#define SNAPPY_MINOR 2\n#include <cstddef>\n";

test "the generated header itself is accepted" {
    try verify(tmpl, gen, gen);
}

test "a header edited by hand is drift" {
    try t.expectError(error.Drift, verify(tmpl, gen, "#define SNAPPY_MAJOR 1\n#define SNAPPY_MINOR 3\n#include <cstddef>\n"));
}

test "a substitution value changed in :src is drift, whatever the BUCK file's comments still say" {
    // :src now writes 3 for the minor version; the committed header still has the 2 a comment may keep.
    try t.expectError(error.Drift, verify(tmpl, "#define SNAPPY_MAJOR 1\n#define SNAPPY_MINOR 3\n#include <cstddef>\n", gen));
}

test "a template that moved with the pin is drift against the old committed header" {
    const moved = "#define SNAPPY_MAJOR ${PROJECT_VERSION_MAJOR}\n#define SNAPPY_MINOR ${PROJECT_VERSION_MINOR}\n#include <cstdint>\n";
    try t.expectError(error.Drift, verify(moved, "#define SNAPPY_MAJOR 1\n#define SNAPPY_MINOR 2\n#include <cstdint>\n", gen));
}

test "a placeholder with no substitution is refused" {
    const with_new = tmpl ++ "#define SNAPPY_PATCH ${PROJECT_VERSION_PATCH}\n";
    const left = gen ++ "#define SNAPPY_PATCH ${PROJECT_VERSION_PATCH}\n";
    try t.expectError(error.UnsubstitutedPlaceholder, verify(with_new, left, left));
}

test "a generated header that is not the template is refused" {
    // A line without a placeholder changed, a line missing, a line added.
    try t.expectError(error.NotFromTemplate, verify(tmpl, "#define SNAPPY_MAJOR 1\n#define SNAPPY_MINOR 2\n#include <cstdint>\n", gen));
    try t.expectError(error.NotFromTemplate, verify(tmpl, "#define SNAPPY_MAJOR 1\n#define SNAPPY_MINOR 2\n", gen));
    try t.expectError(error.NotFromTemplate, verify(tmpl, gen ++ "#define EXTRA 1\n", gen));
}
