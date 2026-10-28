//! analysis_refusals_aws_client: mojo_aws_client's analysis refusals
//! (tools/build/cloud/aws.bzl), each with its exact message: no operations,
//! joined operation names, no runtime deps, a duplicate operation, overrides
//! and hand_srcs without each other, a hand_srcs entry that is a label, not a
//! .mojo, or clashes with a generated file, an unreadable service id, and
//! test_data for the generated environment scan. Catches the
//! duplicate-operation check deleted.
const std = @import("std");
const lib = @import("lib/lib.zig");

const ROWS = [_]lib.Row{
    .{
        .name = "aws_client_no_operations",
        .target = "tests//negative/mojo_aws_client:no_operations",
        .text = "`operations` is empty. A mojo_aws_client generates the operations it names, never a whole service: list the botocore operations the client calls",
        .also = &.{ "tests//negative/mojo_aws_client:no_operations_gen (" },
    },
    .{
        .name = "aws_client_joined_operations",
        .target = "tests//negative/mojo_aws_client:joined_operations",
        .text = "`operations` entry `GetLogEvents,FilterLogEvents` is not a botocore operation name (`GetLogEvents`); entries are separate list items, never joined with `,`",
        .also = &.{ "tests//negative/mojo_aws_client:joined_operations_gen (" },
    },
    .{
        .name = "aws_client_no_runtime",
        .target = "tests//negative/mojo_aws_client:no_runtime",
        .text = "`deps` is empty. The generated code imports its runtime (komira_aws_core; komira_json for a JSON protocol, komira_xml for restXml, awsQuery and ec2Query; and in client mode komira_http_core, komira_http_client and komira_retry); name it, as komira// labels. No runtime is added by default.",
        .also = &.{ "tests//negative/mojo_aws_client:no_runtime_gen (" },
    },
    .{
        .name = "aws_client_duplicate_operation",
        .target = "tests//negative/mojo_aws_client:duplicate_operation",
        .text = "`operations` names `GetLogEvents` twice",
        .also = &.{ "tests//negative/mojo_aws_client:duplicate_operation_gen (" },
    },
    .{
        .name = "aws_client_overrides_without_hand_srcs",
        .target = "tests//negative/mojo_aws_client:overrides_without_hand_srcs",
        .text = "`overrides` is set and `hand_srcs` is empty: the manifest names hand-written owners, and they are its `hand_srcs`",
        .also = &.{ "tests//negative/mojo_aws_client:overrides_without_hand_srcs_gen (" },
    },
    .{
        .name = "aws_client_hand_srcs_without_overrides",
        .target = "tests//negative/mojo_aws_client:hand_srcs_without_overrides",
        .text = "`hand_srcs` is set and `overrides` is not: hand-written modules of a mojo_aws_client own the operations its overrides manifest names",
        .also = &.{ "tests//negative/mojo_aws_client:hand_srcs_without_overrides_gen (" },
    },
    .{
        .name = "aws_client_hand_src_is_label",
        .target = "tests//negative/mojo_aws_client:hand_src_is_label",
        .text = "`hand_srcs` entry `:hand_owner_label` is not a source path of a `.mojo` file. `hand_srcs` takes source paths only, never a label: the library's file names are derived from these paths",
        .also = &.{ "tests//negative/mojo_aws_client:hand_src_is_label_gen (" },
    },
    .{
        .name = "aws_client_hand_src_not_mojo",
        .target = "tests//negative/mojo_aws_client:hand_src_not_mojo",
        .text = "`hand_srcs` entry `hand/notes.txt` is not a source path of a `.mojo` file. `hand_srcs` takes source paths only, never a label: the library's file names are derived from these paths",
        .also = &.{ "tests//negative/mojo_aws_client:hand_src_not_mojo_gen (" },
    },
    .{
        .name = "aws_client_hand_src_clashes",
        .target = "tests//negative/mojo_aws_client:hand_src_clashes",
        .text = "`hand_srcs` entry `hand/_layout_probe.mojo` has the name of a generated or another hand-written file, `_layout_probe.mojo`",
        .also = &.{ "tests//negative/mojo_aws_client:hand_src_clashes_gen (" },
    },
    .{
        .name = "aws_client_service_unreadable",
        .target = "tests//negative/mojo_aws_client:service_unreadable",
        .text = "the botocore service id cannot be read from the model path `not_botocore_layout.json` (botocore's layout is `<service>/<api version>/service-2.json`); set `service`",
        .also = &.{ "tests//negative/mojo_aws_client:service_unreadable_gen (" },
    },
    .{
        .name = "aws_client_env_scan_data_given",
        .target = "tests//negative/mojo_aws_client:env_scan_data_given",
        .text = "`test_data` has an entry for `_generated_tests/_no_env_reads.mojo`, the generated environment scan; its data is the package, staged by the rule",
        .also = &.{ "tests//negative/mojo_aws_client:env_scan_data_given_gen (" },
    },
};

fn body(c: *lib.Ctx) !void {
    try c.refusals(&ROWS);
}

pub fn main() u8 {
    return lib.main(body);
}
