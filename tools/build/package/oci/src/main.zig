//! komira_oci: lays out an image's tree, writes the image, and reads an OCI
//! image layout back (README.md).
//!
//!   komira_oci tree --out <dir> [--bundle <path/>=<dir>]... [--file <path>=<src>]...
//!   komira_oci image --tree <dir> --entrypoint </path> --name <n> --version <v>
//!       --repo <r> --manifest <base manifest> --manifest-digest sha256:<hex>
//!       --config <base config> [--layer <base layer blob>]... --busybox <exe>
//!       --out <dir> --archive <file> --digest <file>
//!   komira_oci layers --layout <dir> --busybox <exe> --out <file>
//!   komira_oci check --layout <dir> --busybox <exe> --layers <file>
//!       --entrypoint </path> [--exec <path>]... [--file <path>]...
//!       --out <file> [--expect-red <text>]
//!
//! `tree` lays bundles and files at paths in <out> (tree.zig: refused unless
//! every path is plain and none is inside another; modes 0755/0644).
//!
//! `image` writes an OCI image layout of the base plus one layer, the tree
//! at /, with Entrypoint [<entrypoint>] (pack.zig), the same as one tar plus
//! Docker's manifest.json at <archive>, and the manifest digest at <digest>.
//!
//! `layers` writes the manifest's layer digests, one per line, in order, and
//! refuses an image whose Entrypoint is not one absolute path naming a
//! regular file with mode 0755 in the image's last layer.
//!
//! `check` is red, naming each failure, unless: the layer list is the
//! manifest's layers in order; the config's Entrypoint is exactly
//! [<entrypoint>]; <entrypoint> and each `--exec` path is a regular file
//! with mode 0755, and each `--file` path a regular file of one byte or
//! more, in the image's filesystem (image.zig: layers applied in order,
//! whiteouts and symbolic links followed); and no entry of the last layer
//! changes the type of a path of the layers below. It writes <out>, what it
//! found, when green. With `--expect-red <text>` the answer is inverted: it
//! writes <out> only when the check is red and a failure contains <text>.
//!
//! Gzip goes through the pinned busybox (`<busybox> gzip -dc` to read a
//! layer, `<busybox> gzip -c` to write one, its header's time then zeroed);
//! nothing else runs. The commands, and the exit code and stderr line of
//! each run (`cli.outcome`), are in cli.zig.

const std = @import("std");
const C = @import("common.zig");
const cli = @import("cli.zig");

pub fn main() void {
    const raw = std.process.argsAlloc(C.a()) catch C.oom();
    const argv = C.a().alloc([]const u8, raw.len) catch C.oom();
    for (raw, 0..) |arg, i| argv[i] = arg;
    const o = cli.outcome(argv);
    std.io.getStdErr().writeAll(o.stderr) catch {};
    std.process.exit(o.code);
}

// The unit tests, run by `zig test` on this file (BUCK: `:komira_oci_unit`).
test {
    _ = @import("sha256.zig");
    _ = @import("tar_test.zig");
    _ = @import("tar_fields_test.zig");
    _ = @import("json_test.zig");
    _ = @import("image_test.zig");
    _ = @import("tree_test.zig");
    _ = @import("pack_test.zig");
    _ = @import("cli_test.zig");
}
