//! The top-level modules a Mojo source imports: the first dotted segment after `from` or
//! `import` at the start of a line. Lines inside a triple-quoted string (a docstring that shows an
//! import) and comment lines are not imports.
//!
//! A line it cannot read as an import (`from` followed by something that is not a module path)
//! outside a string is an error, not a skip: a missed import is a dependency the manifest lacks.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Error = error{ BadImport, OutOfMemory };

/// Where a bad import was found, for the refusal text.
pub const Bad = struct { line: usize = 0 };

fn countTriple(line: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i + 2 < line.len) {
        if ((line[i] == '"' and line[i + 1] == '"' and line[i + 2] == '"') or
            (line[i] == '\'' and line[i + 1] == '\'' and line[i + 2] == '\''))
        {
            n += 1;
            i += 3;
        } else i += 1;
    }
    return n;
}

/// Appends each top-level module name imported by `src` to `out` (duplicates kept; the caller
/// makes sets). Relative imports (`from . import x`) name no package and are skipped.
pub fn scan(a: Allocator, src: []const u8, out: *std.ArrayList([]const u8), bad: *Bad) Error!void {
    var in_string = false;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var lineno: usize = 0;
    while (lines.next()) |raw| {
        lineno += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        const was_in_string = in_string;
        if (countTriple(line) % 2 == 1) in_string = !in_string;
        if (was_in_string or line.len == 0 or line[0] == '#') continue;
        var rest: []const u8 = undefined;
        if (std.mem.startsWith(u8, line, "from ")) {
            rest = line[5..];
        } else if (std.mem.startsWith(u8, line, "import ")) {
            rest = line[7..];
        } else continue;
        rest = std.mem.trimLeft(u8, rest, " \t");
        if (rest.len > 0 and rest[0] == '.') continue;
        var end: usize = 0;
        while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_' or rest[end] == '.')) end += 1;
        const path = rest[0..end];
        const first = path[0..(std.mem.indexOfScalar(u8, path, '.') orelse path.len)];
        if (first.len == 0 or std.ascii.isDigit(first[0])) {
            bad.line = lineno;
            return error.BadImport;
        }
        try out.append(a, first);
    }
}
