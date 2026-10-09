//! komira_pack: the package formats made from a bundle, byte for byte
//! reproducible.
//!
//! usage:
//!   komira_pack tar --bundle <dir> --prefix <top>/ --out <file.tar.gz>
//!   komira_pack conda ...           (a `.conda` conda package; see below)
//!   komira_pack conda-meta ...      (the metapackage: pins the members whose manifests it is given, no file)
//!   komira_pack conda-check ...     (reads a package directory back and refuses what is wrong; both kinds)
//!   komira_pack conda-index --out-dir <dir> --package-manifest <m.json>...
//!                                   (a local channel: the packages and each subdir's repodata.json)
//!   komira_pack oci --bundle <dir> --name <n> --version <v> --repo <r>
//!       --manifest <base manifest> --manifest-digest sha256:<hex>
//!       --config <base config>
//!       [--layer <base layer blob>]...
//!       --out <layout dir> --archive <file.tar> --digest <file>
//!
//! `tar` writes the bundle under <top>/ as a gzip-compressed ustar archive.
//! `oci` writes an OCI image layout: the base image's layers, then one layer
//! holding the bundle at /opt/<name>/, with the entrypoint
//! /opt/<name>/bin/<name>. `--archive` is the same layout as one tar plus a
//! Docker `manifest.json`, which `docker load` reads; `--digest` holds the
//! image manifest digest.
//!
//! `conda` writes one Mojo package as a conda v2 package (`.conda`) for linux-64:
//! a zip of three stored members (`metadata.json`, `pkg-*.tar.zst` holding
//! `lib/mojo/<name>.mojoc` and any `--doc-file` under `share/doc/<name>/`,
//! `info-*.tar.zst` holding `info/`). Every flag is
//! documented at cmdConda (conda.zig). Its zstd streams are made of raw blocks: valid zstd
//! with no compression, so no encoder version can change the bytes. A `.mojoc`
//! is compressed already, and the rest is a few hundred bytes.
//!
//! What makes the bytes reproducible:
//!   * entries sorted bytewise by path, directories written explicitly;
//!   * mtime 0, uid/gid 0, empty user and group names;
//!   * mode 0755 for directories and for files with any exec bit, else 0644;
//!   * gzip: header mtime 0, OS 255 (unknown), zig's deflate at its default
//!     level;
//!   * JSON: object keys in sorted order, no whitespace; every timestamp
//!     1970-01-01T00:00:00Z.
//! A symbolic link, a file of 8 GiB or more, or a special file is refused.
//!
//! The base image is only read from the files named on the command line
//! (downloaded and hash-checked by the build before this runs). The tool
//! refuses unless the base manifest names exactly those blobs, in order, with
//! matching digests and sizes; base layers are copied, never decompressed.
//!
//! This is a static executable: it runs with no shell, no PATH and no
//! network. Exit status 2 on any malformed or unexpected input.
//!
//! This file is the command dispatch. The rest, by section:
//!   common.zig       the tar writer, gzip, hashing and files, sorted JSON,
//!                    the command line;
//!   tar_oci.zig      `tar` and `oci`;
//!   conda.zig        the conda package format, names and requirements, `conda`;
//!   conda_meta.zig   `conda-meta`;
//!   conda_check.zig  `conda-check`;
//!   conda_index.zig  `conda-index`.

const std = @import("std");
const pack_common = @import("common.zig");
const pack_tar_oci = @import("tar_oci.zig");
const pack_conda = @import("conda.zig");
const pack_conda_meta = @import("conda_meta.zig");
const pack_conda_check = @import("conda_check.zig");
const pack_conda_index = @import("conda_index.zig");
const fail = pack_common.fail;
const parseArgs = pack_common.parseArgs;
const cmdOci = pack_tar_oci.cmdOci;
const cmdTar = pack_tar_oci.cmdTar;
const cmdConda = pack_conda.cmdConda;
const cmdCondaMeta = pack_conda_meta.cmdCondaMeta;
const cmdCondaCheck = pack_conda_check.cmdCondaCheck;
const cmdCondaIndex = pack_conda_index.cmdCondaIndex;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const argv = try std.process.argsAlloc(alloc);
    if (argv.len < 2) fail("usage: komira_pack tar|oci|conda|conda-meta|conda-check|conda-index --flag value ...", .{});
    const a = try parseArgs(alloc, argv);
    if (std.mem.eql(u8, argv[1], "tar")) {
        try cmdTar(alloc, a);
    } else if (std.mem.eql(u8, argv[1], "oci")) {
        try cmdOci(alloc, a);
    } else if (std.mem.eql(u8, argv[1], "conda")) {
        try cmdConda(alloc, a);
    } else if (std.mem.eql(u8, argv[1], "conda-meta")) {
        try cmdCondaMeta(alloc, a);
    } else if (std.mem.eql(u8, argv[1], "conda-check")) {
        try cmdCondaCheck(alloc, a);
    } else if (std.mem.eql(u8, argv[1], "conda-index")) {
        try cmdCondaIndex(alloc, a);
    } else fail("unknown command {s}", .{argv[1]});
}
