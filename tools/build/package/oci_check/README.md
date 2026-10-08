# oci_check

`oci_check` reads an OCI image layout back. It is a Rust program with no
third-party crate: [`src/json.rs`](src/json.rs) reads JSON,
[`src/tar.rs`](src/tar.rs) reads tar (ustar, GNU long names, pax headers,
every header checksum verified), and [`src/image.rs`](src/image.rs) applies
the layers. A gzip layer is decompressed by the pinned busybox
(`busybox gzip -dc`); nothing else runs, and nothing uses the network.

| command | run by | what |
|---|---|---|
| `oci_check layers --layout <dir> --busybox <exe> --out <file>` | every `oci_image` ([`../defs.bzl`](../defs.bzl)), for its default output and `[layers]` | writes the manifest's layer digests, one per line, in order; refuses an image whose Entrypoint is not one absolute path naming a regular file with mode 0755 in the added (last) layer |
| `oci_check check --layout <dir> --busybox <exe> --layers <file> --entrypoint </path> [--exec <path>]... [--file <path>]... --out <file> [--expect-red <text>]` | `oci_image_check` ([`../oci_check.bzl`](../oci_check.bzl)) | red, naming each failure, unless the layer list is the manifest's layers in order; the Entrypoint is exactly `[<entrypoint>]`; the entrypoint and each `--exec` path is a regular file with mode 0755 and each `--file` path a regular file of one byte or more in the image's filesystem; and no entry of the added layer changes the type of a path below it |

## The image's filesystem

The layers are applied in order, as a container runtime applies them (OCI
image spec, "Applying changesets"):

- a later entry replaces an earlier one at the same path, and an entry that
  is not a directory also removes everything that was under that path;
- a hard link takes its target's type, mode and size;
- whiteouts apply to the layers below theirs, never to entries of their own
  layer, whatever their order in the archive: `<dir>/.wh.<name>` removes
  `<dir>/<name>` and everything under it, and `<dir>/.wh..wh..opq` (an
  opaque directory) removes every child of `<dir>` from the layers below;
- a path is resolved one part at a time, following each symbolic link
  (absolute targets from /, relative ones from the link's directory, `..`
  stopping at /), at most 40 links.

## Tests

[`BUCK`](BUCK) publishes the binary behind `:oci_check_unit`, the crate's
inline tests, so no image builds unless they pass. Besides the JSON and tar
readers' cases, they apply layers over a fixture base that holds
`etc/ssl/certs/ca-certificates.crt`: the control is green; a directory
whiteout `etc/.wh.ssl` and an opaque `etc/ssl/certs/.wh..wh..opq` each hide
the certificates; an opaque directory keeps what its own layer puts in it,
and a whiteout of `etc/ssl/cert` leaves `etc/ssl/certs` alone.

The same over real layers: `:control`, `:dir_whiteout` and `:opaque_whiteout`
are `oci_image_check`s of images on the pinned distroless base. The control
builds green; the other two add one whiteout and are built with
`expect_red`, so each builds only while the check is red naming
`file etc/ssl/certs/ca-certificates.crt: not in the image`.
