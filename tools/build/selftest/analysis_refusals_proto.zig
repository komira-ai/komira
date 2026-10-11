//! analysis_refusals_proto: a `bundle_only` entry outside the proto_deps
//! closure is refused with its exact message (tools/build/mojo/proto.bzl).
//! Catches the membership check deleted.
const std = @import("std");
const lib = @import("lib/lib.zig");

const ROWS = [_]lib.Row{
    .{
        .name = "proto_bad_selection",
        .target = "tests//negative/proto:roster_bad_selection",
        .text = "`bundle_only` names `example/v1/persons.proto`, which is not a .proto of the proto_deps closure: example/v1/person.proto, komira/db/options.proto",
        .also = &.{ "tests//negative/proto:roster_bad_selection (" },
    },
};

fn body(c: *lib.Ctx) !void {
    try c.refusals(&ROWS);
}

pub fn main() u8 {
    return lib.main(body);
}
