//! The top-level modules a Mojo source imports: the first dotted segment after `from` or
//! `import` at the start of a line, for every module of an `import a, b` list. Lines inside a triple-quoted string (a docstring that shows an
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
        var is_import = false;
        if (std.mem.startsWith(u8, line, "from ")) {
            rest = line[5..];
        } else if (std.mem.startsWith(u8, line, "import ")) {
            rest = line[7..];
            is_import = true;
        } else continue;
        rest = std.mem.trimLeft(u8, rest, " \t");
        if (rest.len > 0 and rest[0] == '.') continue;
        // `from m import a, b` names one module (the commas list names inside it); `import m, n`
        // names every module of the list.
        var parts = std.mem.splitScalar(u8, rest, ',');
        var first_part = true;
        while (parts.next()) |part_raw| {
            if (!first_part and !is_import) break;
            first_part = false;
            const part = std.mem.trimLeft(u8, part_raw, " \t");
            if (part.len > 0 and part[0] == '.') continue;
            var end: usize = 0;
            while (end < part.len and (std.ascii.isAlphanumeric(part[end]) or part[end] == '_' or part[end] == '.')) end += 1;
            const path = part[0..end];
            const first = path[0..(std.mem.indexOfScalar(u8, path, '.') orelse path.len)];
            if (first.len == 0 or std.ascii.isDigit(first[0])) {
                bad.line = lineno;
                return error.BadImport;
            }
            try out.append(a, first);
        }
    }
}

/// The line (1-based) of the first use of a runtime-loaded library (`DLHandle`, `OwnedDLHandle`)
/// in code: not in a comment line or a triple-quoted string. Null when there is none.
pub fn findDlopen(src: []const u8) ?usize {
    var in_string = false;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var lineno: usize = 0;
    while (lines.next()) |raw| {
        lineno += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        const was_in_string = in_string;
        if (countTriple(line) % 2 == 1) in_string = !in_string;
        if (was_in_string or line.len == 0 or line[0] == '#') continue;
        const code = line[0..(std.mem.indexOfScalar(u8, line, '#') orelse line.len)];
        if (std.mem.indexOf(u8, code, "DLHandle") != null) return lineno;
    }
    return null;
}
