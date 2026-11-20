//! analysis_refusals_python_proto: python_proto's refusals
//! (tools/build/python/defs.bzl), each with its exact message: an empty srcs,
//! a file that is not a .proto, two files with one name, and an import_prefix
//! with a `..` or an empty segment. Catches each check dropped.
const std = @import("std");
const lib = @import("lib/lib.zig");

const ROWS = [_]lib.Row{
    .{
        .name = "python_proto_empty_srcs",
        .target = "tests//negative/python_proto:empty_srcs",
        .text = "tests//negative/python_proto:empty_srcs: srcs is empty",
    },
    .{
        .name = "python_proto_not_a_proto",
        .target = "tests//negative/python_proto:not_a_proto",
        .text = "tests//negative/python_proto:not_a_proto: src a.txt is not a .proto file",
    },
    .{
        .name = "python_proto_duplicate_name",
        .target = "tests//negative/python_proto:duplicate_name",
        .text = "tests//negative/python_proto:duplicate_name: two srcs are named a.proto",
    },
    .{
        .name = "python_proto_prefix_dot_dot",
        .target = "tests//negative/python_proto:prefix_dot_dot",
        .text = "tests//negative/python_proto:prefix_dot_dot: import_prefix \"komira/../plan\" holds an empty, `.` or `..` segment",
    },
    .{
        .name = "python_proto_prefix_empty_segment",
        .target = "tests//negative/python_proto:prefix_empty_segment",
        .text = "tests//negative/python_proto:prefix_empty_segment: import_prefix \"komira/\" holds an empty, `.` or `..` segment",
    },
};

fn body(c: *lib.Ctx) !void {
    try c.refusals(&ROWS);
}

pub fn main() u8 {
    return lib.main(body);
}
