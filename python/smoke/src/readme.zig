//! pypi_smoke: the README's "What works" block is the quickstart. `readmeShowsExample` holds a README to
//! python/examples/quickstart.py: it must contain a line that is exactly "```python", then lines whose
//! concatenation (each with its line feed) is the example's text byte for byte, then a line that is exactly
//! "```". A README with CRLF line ends, a trailing space or another line in the block is not equal.
const std = @import("std");

const Allocator = std.mem.Allocator;

const head = "python/README.md shows no ```python block equal to python/examples/quickstart.py: ";

fn lines(a: Allocator, text: []const u8) ![]const []const u8 {
    var list = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try list.append(a, line);
    return list.items;
}

/// null when the README holds the example as a ```python block; else the refusal, naming the first line where the
/// block that agrees with the example for the most lines differs from it.
pub fn readmeShowsExample(a: Allocator, readme_text: []const u8, example_text: []const u8) !?[]const u8 {
    if (example_text.len == 0 or example_text[example_text.len - 1] != '\n')
        return try std.fmt.allocPrint(a, "{s}the example does not end with a line feed", .{head});
    const want = try lines(a, example_text[0 .. example_text.len - 1]);
    // A README that ends with a line feed has no empty last line.
    const all = try lines(a, if (std.mem.endsWith(u8, readme_text, "\n")) readme_text[0 .. readme_text.len - 1] else readme_text);
    var best: ?usize = null; // the number of lines the closest block agrees on
    var best_have: []const u8 = "";
    var best_want: []const u8 = "";
    var best_line: usize = 0;
    var i: usize = 0;
    while (i < all.len) : (i += 1) {
        if (!std.mem.eql(u8, all[i], "```python")) continue;
        var j = i + 1;
        while (j < all.len and !std.mem.eql(u8, all[j], "```")) j += 1;
        const body = all[i + 1 .. j];
        const closed = j < all.len;
        var k: usize = 0;
        while (k < body.len and k < want.len and std.mem.eql(u8, body[k], want[k])) k += 1;
        if (closed and body.len == want.len and k == want.len) return null;
        if (best == null or k > best.?) {
            best = k;
            best_line = k + 1;
            best_have = if (k < body.len) body[k] else if (closed) "(the block ends)" else "(the README ends)";
            best_want = if (k < want.len) want[k] else "(the example ends)";
        }
    }
    if (best == null) return try std.fmt.allocPrint(a, "{s}the README has no line that is exactly ```python", .{head});
    return try std.fmt.allocPrint(a, "{s}line {d} of the closest block reads '{s}', the example's reads '{s}'", .{ head, best_line, best_have, best_want });
}
