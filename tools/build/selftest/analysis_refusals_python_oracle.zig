//! analysis_refusals_python_oracle: python_oracle's owner refusals
//! (tools/build/python/defs.bzl), each with its exact message: data, srcs,
//! wheel, src and python built outside third_party/. Catches the third_party
//! owner check dropped.
const std = @import("std");
const lib = @import("lib/lib.zig");

const ROWS = [_]lib.Row{
    .{
        .name = "python_oracle_komira_data",
        .target = "tests//negative/python_oracle:komira_data",
        .text = "tests//negative/python_oracle:komira_data: the oracle's data \"encoding.mojoc\" is built by komira//src/komira_encoding:komira_encoding, which is not under third_party/; an oracle reads checked-in files and third_party/ outputs only, so that its answer cannot come from komira (tools/build/python/README.md, Oracles)",
    },
    .{
        .name = "python_oracle_komira_srcs",
        .target = "tests//negative/python_oracle:komira_srcs",
        .text = "tests//negative/python_oracle:komira_srcs: the oracle's srcs entry \"hello\" is built by komira//tools/build/examples:hello, which is not under third_party/; an oracle reads checked-in files and third_party/ outputs only, so that its answer cannot come from komira (tools/build/python/README.md, Oracles)",
    },
    .{
        .name = "python_oracle_local_wheel",
        .target = "tests//negative/python_oracle:local_wheel_dep",
        .text = "tests//negative/python_oracle:local_wheel_dep: the oracle's wheel local is built by tests//negative/python_oracle:local_wheel, which is not under third_party/; an oracle reads checked-in files and third_party/ outputs only, so that its answer cannot come from komira (tools/build/python/README.md, Oracles)",
    },
    .{
        .name = "python_oracle_local_tzdata",
        .target = "tests//negative/python_oracle:local_tzdata",
        .text = "tests//negative/python_oracle:local_tzdata: the oracle's wheel local is built by tests//negative/python_oracle:local_wheel, which is not under third_party/; an oracle reads checked-in files and third_party/ outputs only, so that its answer cannot come from komira (tools/build/python/README.md, Oracles)",
    },
    .{
        .name = "python_oracle_komira_src",
        .target = "tests//negative/python_oracle:komira_src",
        .text = "tests//negative/python_oracle:komira_src: the oracle's src is built by komira//tools/build/examples:hello, which is not under third_party/; an oracle reads checked-in files and third_party/ outputs only, so that its answer cannot come from komira (tools/build/python/README.md, Oracles)",
    },
    .{
        .name = "python_oracle_local_python",
        .target = "tests//negative/python_oracle:local_python",
        .text = "tests//negative/python_oracle:local_python: the oracle's python is built by tests//negative/python_oracle:stand_in_python, which is not under third_party/; an oracle reads checked-in files and third_party/ outputs only, so that its answer cannot come from komira (tools/build/python/README.md, Oracles)",
    },
};

fn body(c: *lib.Ctx) !void {
    try c.refusals(&ROWS);
}

pub fn main() u8 {
    return lib.main(body);
}
