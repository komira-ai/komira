//! What of a build file runs a shell: a scanner for the Starlark of BUCK, .bzl
//! and .bxl files. It tokenizes only as far as it must: comments (`#` to the
//! end of the line) are skipped, string literals are read whole (single,
//! double, triple quoted; a backslash escapes the next byte), and identifiers
//! are words. Nothing is evaluated, so a shell started through a computed
//! name is not seen: the lint is a guard against the spelling of a shell, and
//! the rules' own review holds the rest.
//!
//! Five categories are counted, each once per occurrence:
//!   - `busybox_sh`: the identifier or the string `busybox_sh` / `_busybox_sh`
//!     (the helper that runs a script under the busybox shell, and its import);
//!   - `sh_argv`: a string that is exactly a shell's name (`sh`, `bash`,
//!     `dash`, `ash`, `zsh`, `ksh`, `mksh`) or a shell's option word (`-euc`,
//!     `-ec`): the argv of a shell;
//!   - `shell_path`: a string that holds `/bin/sh`, `/bin/bash`,
//!     `/usr/bin/env sh` or `/usr/bin/env bash` (a shell by path, or a `#!`
//!     line written into a script);
//!   - `sh_script`: a string that is one path ending in `.sh` or `.bash` (a
//!     shell script the rules name);
//!   - `shell_rule`: the identifier `genrule`, `sh_binary`, `sh_test` or
//!     `sh_library` (rules whose body is a shell command).

const std = @import("std");

pub const Category = enum { busybox_sh, sh_argv, shell_path, sh_script, shell_rule };

pub const category_count = @typeInfo(Category).Enum.fields.len;

pub const Counts = [category_count]usize;

pub fn parseCategory(name: []const u8) ?Category {
    return std.meta.stringToEnum(Category, name);
}

pub fn total(c: Counts) usize {
    var n: usize = 0;
    for (c) |x| n += x;
    return n;
}

const shell_names = [_][]const u8{ "sh", "bash", "dash", "ash", "zsh", "ksh", "mksh" };
const shell_options = [_][]const u8{ "-euc", "-ec" };
const shell_paths = [_][]const u8{ "/bin/sh", "/bin/bash", "/usr/bin/env sh", "/usr/bin/env bash" };
const rule_names = [_][]const u8{ "genrule", "sh_binary", "sh_test", "sh_library" };

fn eqlAny(s: []const u8, set: []const []const u8) bool {
    for (set) |x| {
        if (std.mem.eql(u8, s, x)) return true;
    }
    return false;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Counts the category of one string literal's content (the bytes between the
/// quotes, escapes not decoded).
pub fn literal(counts: *Counts, content: []const u8) void {
    if (std.mem.eql(u8, content, "busybox_sh") or std.mem.eql(u8, content, "_busybox_sh")) {
        counts[@intFromEnum(Category.busybox_sh)] += 1;
    } else if (eqlAny(content, &shell_options)) {
        counts[@intFromEnum(Category.sh_argv)] += 1;
    } else if (holdsAny(content, &shell_paths)) {
        counts[@intFromEnum(Category.shell_path)] += 1;
    } else if (isScriptPath(content)) {
        counts[@intFromEnum(Category.sh_script)] += 1;
    }
}

/// Whether `s` holds one of `set` as a whole word: not followed by a letter,
/// digit or underscore (`/bin/sh` is a shell, `/bin/shx` is not).
fn holdsAny(s: []const u8, set: []const []const u8) bool {
    for (set) |x| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, s, from, x)) |at| {
            const after = at + x.len;
            if (after >= s.len or !isIdentChar(s[after])) return true;
            from = at + 1;
        }
    }
    return false;
}

fn isScriptPath(s: []const u8) bool {
    if (!(std.mem.endsWith(u8, s, ".sh") or std.mem.endsWith(u8, s, ".bash"))) return false;
    if (s.len <= 3) return false;
    for (s) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') return false;
    }
    return true;
}

/// The shell uses of the Starlark source `src`.
pub fn scan(src: []const u8) Counts {
    var counts = [_]usize{0} ** category_count;
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '#') {
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            const triple = i + 2 < src.len and src[i + 1] == c and src[i + 2] == c;
            const start = i + (if (triple) @as(usize, 3) else @as(usize, 1));
            var j = start;
            var end = src.len;
            var next = src.len;
            while (j < src.len) {
                const d = src[j];
                if (d == '\\') {
                    j += 2;
                    continue;
                }
                if (triple) {
                    if (d == c and j + 2 < src.len and src[j + 1] == c and src[j + 2] == c) {
                        end = j;
                        next = j + 3;
                        break;
                    }
                } else if (d == c) {
                    end = j;
                    next = j + 1;
                    break;
                } else if (d == '\n') {
                    // An unterminated literal: Starlark refuses it, the scan moves on.
                    end = j;
                    next = j;
                    break;
                }
                j += 1;
            }
            if (end < start) end = start;
            literal(&counts, src[start..end]);
            i = next;
            continue;
        }
        if (isIdentStart(c)) {
            var j = i + 1;
            while (j < src.len and isIdentChar(src[j])) j += 1;
            const word = src[i..j];
            if (std.mem.eql(u8, word, "busybox_sh") or std.mem.eql(u8, word, "_busybox_sh")) {
                counts[@intFromEnum(Category.busybox_sh)] += 1;
            } else if (eqlAny(word, &rule_names)) {
                counts[@intFromEnum(Category.shell_rule)] += 1;
            }
            i = j;
            continue;
        }
        i += 1;
    }
    return counts;
}

/// Whether `path` names a file the scan reads: a BUCK file, a `.bzl` or `.bxl`.
pub fn isBuildFile(path: []const u8) bool {
    const base = std.fs.path.basenamePosix(path);
    return std.mem.eql(u8, base, "BUCK") or std.mem.eql(u8, base, "BUCK.v2") or
        std.mem.endsWith(u8, base, ".bzl") or std.mem.endsWith(u8, base, ".bxl");
}
