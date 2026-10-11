//! analysis_refusals_gcp_client: mojo_gcp_client's analysis refusals
//! (tools/build/mojo/proto.bzl), each with its exact message: no roots or
//! methods, joined items, no runtime deps, a whole-closure bundle, a label in
//! `protos`, an unknown protocol, and the module_names refusals. Catches the
//! roots-or-methods check deleted.
const std = @import("std");
const lib = @import("lib/lib.zig");

const ROWS = [_]lib.Row{
    .{
        .name = "gcp_client_unscoped",
        .target = "tests//negative/mojo_gcp_client:unscoped",
        .text = "neither `roots` nor `methods` is set. A mojo_gcp_client generates the closure of the messages and methods it names, never a whole API",
        .also = &.{ "tests//negative/mojo_gcp_client:unscoped_gen (" },
    },
    .{
        .name = "gcp_client_joined_items",
        .target = "tests//negative/mojo_gcp_client:joined_items",
        .text = "`methods` item `ShopService.GetItem+ShopService.DeleteItem` is not a proto name (`Name`, `pkg.Name` or `.pkg.Name`); items are separate list entries, never joined with `+` or `,`",
        .also = &.{ "tests//negative/mojo_gcp_client:joined_items_gen (" },
    },
    .{
        .name = "gcp_client_no_runtime",
        .target = "tests//negative/mojo_gcp_client:no_runtime",
        .text = "`deps` is empty. The generated code imports its runtime (komira_proto_codec, komira_wkt, ...); name it, as komira// labels. No runtime is added by default.",
        .also = &.{ "tests//negative/mojo_gcp_client:no_runtime_gen (" },
    },
    .{
        .name = "gcp_client_whole_closure",
        .target = "tests//negative/mojo_gcp_client:whole_closure",
        .text = "`bundle_proto_deps = True` with an empty `bundle_only`. List the files of the proto_deps closure the scope reaches; the whole closure is never bundled",
        .also = &.{ "tests//negative/mojo_gcp_client:whole_closure_gen (" },
    },
    .{
        .name = "gcp_client_label_in_protos",
        .target = "tests//negative/mojo_gcp_client:label_in_protos",
        .text = "`protos` entry `//functional/mojo_gcp_client:shop_deps` is not a source path of a `.proto` file. `protos` takes source paths only, never a label (not even one to a generated .proto): the library's `<stem>.mojo` file names are derived from these paths",
        .also = &.{ "tests//negative/mojo_gcp_client:label_in_protos_gen (" },
    },
    .{
        .name = "gcp_client_unknown_protocol",
        .target = "tests//negative/mojo_gcp_client:unknown_protocol",
        .text = "`protocol` `connect` is not one of \"rest\", \"grpc\"",
        .also = &.{ "tests//negative/mojo_gcp_client:unknown_protocol_gen (" },
    },
    .{
        .name = "gcp_client_module_names_stray",
        .target = "tests//negative/mojo_gcp_client:module_names_stray",
        .text = "`module_names` names `example/shop/v1/audit.proto`, which this target does not generate",
        .also = &.{ "tests//negative/mojo_gcp_client:module_names_stray_gen (" },
    },
    .{
        .name = "gcp_client_module_names_not_a_module",
        .target = "tests//negative/mojo_gcp_client:module_names_not_a_module",
        .text = "`module_names` gives `example/shop/v1/item.proto` the module `item.v1`, which is not a Mojo module name the generated package can hold",
        .also = &.{ "tests//negative/mojo_gcp_client:module_names_not_a_module_gen (" },
    },
    .{
        .name = "gcp_client_module_names_keyword",
        .target = "tests//negative/mojo_gcp_client:module_names_keyword",
        .text = "`module_names` gives `example/shop/v1/item.proto` the module `import`, which is not a Mojo module name the generated package can hold",
        .also = &.{ "tests//negative/mojo_gcp_client:module_names_keyword_gen (" },
    },
    .{
        .name = "gcp_client_module_names_unrenamed",
        .target = "tests//negative/mojo_gcp_client:module_names_unrenamed_stem",
        .text = "`example/neg/v1/thing.min.proto` would be generated as module `thing.min`, which is not a Mojo module name: give it one in `module_names`",
        .also = &.{ "tests//negative/mojo_gcp_client:module_names_unrenamed_stem_gen (" },
    },
};

fn body(c: *lib.Ctx) !void {
    try c.refusals(&ROWS);
}

pub fn main() u8 {
    return lib.main(body);
}
