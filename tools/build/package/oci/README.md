# komira_oci

`komira_oci` lays out the tree an image adds, writes that image, and reads an
OCI image layout back. It is a Zig program, as every build tool under
`tools/build` is (komira#956), built with the pinned zig and using only Zig's
standard library:
[`src/json.zig`](src/json.zig) reads and writes JSON,
[`src/tar.zig`](src/tar.zig) reads tar (ustar, GNU long names, pax headers,
every header checksum verified) and writes it (ustar, a path over 100 bytes
in a pax header, a size past eleven octal digits in base-256),
[`src/sha256.zig`](src/sha256.zig) computes digests,
[`src/tree.zig`](src/tree.zig) lays out a tree, [`src/pack.zig`](src/pack.zig)
assembles an image, [`src/image.zig`](src/image.zig) applies an image's
layers, and [`src/cli.zig`](src/cli.zig) holds the commands
([`src/main.zig`](src/main.zig) runs them; [`src/common.zig`](src/common.zig)
is what they share). Gzip goes through the pinned busybox (`busybox gzip
-dc` to read a layer, `busybox gzip -c` to write one, with the header's time
then zeroed); nothing else runs, and nothing uses the network.

| command | run by | what |
|---|---|---|
| `komira_oci tree --out <dir> [--bundle <path/>=<dir>]... [--file <path>=<src>]...` | every `oci_tree` ([`../defs.bzl`](../defs.bzl)) | lays each bundle and file at its path; refused, naming each reason, unless every path is plain (no empty, `.` or `..` part), a bundle's ends in /, and no path is inside another (a file at `app/bin/x` beside a bundle at `app/` would replace the bundle's program). Modes are 0755 for directories and files with an exec bit, else 0644 |
| `komira_oci image --tree <dir> --entrypoint </path> --name <n> --version <v> --repo <r> --manifest <m> --manifest-digest <d> --config <c> [--layer <blob>]... --busybox <exe> --out <dir> --archive <file> --digest <file>` | `oci_image(tree = ...)` | an OCI image layout of the pinned base plus one layer, the tree at /, with Entrypoint `[<entrypoint>]`; refused unless the base manifest hashes to its pin and names exactly the given config and layers. `--archive` is the layout as one tar plus a Docker `manifest.json`; `--digest` the manifest digest |
| `komira_oci layers --layout <dir> --busybox <exe> --out <file>` | every `oci_image`, for its default output and `[layers]` | writes the manifest's layer digests, one per line, in order; refuses an image whose Entrypoint is not one absolute path naming a regular file with mode 0755 in the added (last) layer |
| `komira_oci check --layout <dir> --busybox <exe> --layers <file> --entrypoint </path> [--exec <path>]... [--file <path>]... --out <file> [--expect-red <text>]` | `oci_image_check` ([`../oci_check.bzl`](../oci_check.bzl)) | red, naming each failure, unless the layer list is the manifest's layers in order; the Entrypoint is exactly `[<entrypoint>]` (one element, spelled the same); the entrypoint and every `--exec` path is a regular file with mode 0755 and every `--file` path a regular file of one byte or more in the image's filesystem; and no entry of the added layer changes the type of a path below it |

An image's bytes depend only on the tree and the base: tar entries are
sorted, mtime, uid and gid are 0, JSON keys are sorted, and every timestamp
is 1970-01-01T00:00:00Z. A bundle image (`oci_image(bundle = ...)`) is
written by `komira_pack oci` instead ([`../README.md`](../README.md)).

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

[`BUCK`](BUCK) publishes the binary behind `:komira_oci_unit`, a `zig_test`
([`../../mojo/toolchain.bzl`](../../mojo/toolchain.bzl)): `zig test` of
`src/main.zig`, whose test block imports every `src/*_test.zig`, run as a
build action with the busybox applets as its PATH and a TMPDIR of its own,
so no tree or image builds unless they pass. They cover:

- the tree refusals: a file inside a bundle, a bundle inside a bundle, a
  file inside a file, a bundle at a file's path, a path given twice, and
  paths that are not plain are refused; the base image's tree and names
  that only share a prefix are accepted. `tree.lay` takes a `Plan`, which
  `tree.plan` returns only when nothing is refused;
- the writers: SHA-256 known answers (FIPS 180-4, the padding boundary);
  tar written, read back and identical for the same items, and every
  header byte equal to a header laid out from the ustar field table; every
  field read at its width (names, links and prefixes at 99, 100 and the
  whole field), every type flag, and a pax size kept off the long-name,
  long-link, global and second pax headers; JSON written
  compact with sorted keys and read back; the config (Entrypoint, no Cmd,
  label, diff_id, history), a base that is not exactly the pinned blobs
  refused, and repository names normalized; the manifest, index.json, the
  layout's files and the archive's paths and modes spelled out in full;
- the check: the Entrypoint must be exactly the one named (another program,
  another spelling of the same path, two elements, none are red); every
  `--exec` and `--file` item is read, not only the first;
- every refusal by itself: each site that returns an error has a case that
  hits it and asserts its exact message, so deleting one refusal, weakening
  its comparison, or skipping the last item of its loop is red. That covers
  each field of the base manifest and its descriptors (the base re-pinned, so
  only the edited field can be refused), the base config, the layout
  (`index.json`, digests, the manifest), `layers`, `check` with and without
  `--expect-red`, the arguments, gzip's header, the tar and JSON readers, and
  laying a tree. Layouts and trees are written under the test run's own
  TMPDIR; busybox's `true` and `false` applets stand in for a failing gzip;
- layers over a fixture base holding `etc/ssl/certs/ca-certificates.crt`:
  the control is green; a directory whiteout `etc/.wh.ssl` and an opaque
  `etc/ssl/certs/.wh..wh..opq` each hide the certificates; an opaque
  directory keeps what its own layer puts in it; a whiteout of
  `etc/ssl/cert` in a layer that adds nothing back leaves `etc/ssl/certs`,
  the certificate and `etc/ssl/cert.pem` in place.

The same over real images of the pinned distroless base, as
`oci_image_check`s. `:control` and `:two_programs` build green. Each other
case has one defect and is built with `expect_red`, so it builds only while
the check is red naming it:

| case | defect | named |
|---|---|---|
| `:dir_whiteout` | the added layer holds `etc/.wh.ssl` | `file etc/ssl/certs/ca-certificates.crt: not in the image` |
| `:opaque_whiteout` | the added layer holds `etc/ssl/certs/.wh..wh..opq` | the same |
| `:wrong_entrypoint` | the check names `/bin/other`, a 0755 file of the image, but the config's Entrypoint is `["/bin/sh"]` | `the config's Entrypoint is not ["/bin/other"]` |
| `:second_exec` | `executables = ["bin/sh", "etc/os-release"]`; the second is not mode 0755 | `exec etc/os-release: ` |
| `:second_file` | `files = [<the certificate>, "etc/nope"]`; the second is not in the image | `file etc/nope: not in the image` |
