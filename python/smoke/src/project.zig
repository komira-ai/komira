//! pypi_smoke: what an index says about a whole project, read from its JSON API (`<json base><name>/json`),
//! whose `releases` object maps each version to the list of its files (`filename`, `size`, `digests.sha256`,
//! `url`). `storage` reads only the sizes, `promote` the names, sizes, digests and URLs; each reads the fields
//! it needs and no more, so the type of a file is the caller's.
const std = @import("std");
const common = @import("common.zig");
const rbf = @import("release_beta_fetch");

const Allocator = common.Allocator;
const Error = common.Error;
const refuse = common.refuse;

/// The most a project's JSON may be.
pub const max_json_bytes: usize = 64 << 20;

pub const Digests = struct { sha256: []const u8 };

/// A file of a release with everything `promote` compares.
pub const Listed = struct {
    filename: []const u8,
    size: u64,
    digests: Digests,
    url: []const u8,
};

/// A file of a release of which only the size is read.
pub const Sized = struct { size: u64 };

/// A file of a release of which only the name is read.
pub const Named = struct { filename: []const u8 };

pub fn Releases(comptime File: type) type {
    return std.json.ArrayHashMap([]const File);
}

pub fn url(a: Allocator, idx: common.Index, project: []const u8) Error![]u8 {
    return std.fmt.allocPrint(a, "{s}{s}/json", .{ idx.json_base, project });
}

/// The releases of `project` on `idx`, in the order the index lists them; null when the index has no such
/// project (HTTP 404). Any other answer that is not the JSON of a project is refused naming the URL.
pub fn fetch(comptime File: type, a: Allocator, why: *[]const u8, fetcher: rbf.Fetcher, idx: common.Index, project: []const u8) Error!?Releases(File) {
    const at = try url(a, idx, project);
    switch (fetcher.get(a, at, max_json_bytes)) {
        .body => |body| {
            const Doc = struct { releases: Releases(File) };
            const doc = std.json.parseFromSliceLeaky(Doc, a, body, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return refuse(a, why, "GET {s}: the answer is not the JSON of a project ({s})", .{ at, @errorName(e) }),
            };
            return doc.releases;
        },
        .status => |s| {
            if (s == 404) return null;
            return refuse(a, why, "GET {s}: HTTP {d}", .{ at, s });
        },
        .too_large => return refuse(a, why, "GET {s}: the answer is longer than {d} bytes", .{ at, max_json_bytes }),
        .bad_url => return refuse(a, why, "{s} is not a URL this tool fetches", .{at}),
        .transport => |e| return refuse(a, why, "GET {s}: {s}", .{ at, @errorName(e) }),
    }
}
