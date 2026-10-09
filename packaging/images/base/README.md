# The komira base image

`komira//packaging/images/base:komira_base` is the image a supervised job
runs FROM. The build writes it as files; nothing is pushed.

| path in the image | what | from |
|---|---|---|
| the base's layers | glibc, CA certificates (`/etc/ssl/certs/ca-certificates.crt`), tzdata, a nonroot user | distroless base-debian12, pinned by digest (`komira//tools/build/toolchains:distroless_base`) |
| `/bin/sh` | a shell | the pinned static busybox the build's actions use |
| `/komira/bin/supervisor` | the supervisor, the image's ENTRYPOINT | a `mojo_bundle` at `/komira/` |
| `/opt/kci/bin/kci` | kci | the `komira//bin/kci:kci` bundle at `/opt/kci/` |

The supervisor is a stand-in today ([`supervisor_stub.mojo`](supervisor_stub.mojo)):
it supervises nothing, prints that, and exits 2. The job supervisor's binary
replaces it by changing one line, `SUPERVISOR` in [`BUCK`](BUCK); the bundle
names it `supervisor` whatever its target is called.

A job's own image is built FROM this one. A runner that starts the supervisor
names `/komira/bin/supervisor` as the command itself: ENTRYPOINT is image
configuration, not a layer, so an image built FROM this one can replace it.

## Outputs

| target | what |
|---|---|
| `:komira_base` | the OCI image layout directory |
| `:komira_base[docker_archive]` | the same as one tar, for `docker load` |
| `:komira_base[digest]` | the image manifest digest |
| `:komira_base[layers]` | the digest of each layer of the manifest, one per line, in order: the base's, then the one this build adds. An image whose layers begin with these is built FROM this one. |
| `:komira_base[check]` | what the check below found |

## Checks

Each runs when the image is built: building `:komira_base` or any of its
sub-targets fails if one fails.

| check | where | catches |
|---|---|---|
| the config's Entrypoint is exactly `["/komira/bin/supervisor"]` | `oci_image_check` ([`komira_oci check`](../../../tools/build/package/oci/README.md)) | an image whose entrypoint was dropped or changed |
| `/komira/bin/supervisor`, `/bin/sh` and `/opt/kci/bin/kci` are regular files with mode 0755 in the image's filesystem (layers applied in order; a whiteout hides its path and everything under it, an opaque one its directory's children below; symlinks followed) | the same | a program missing, or packed without its exec bit |
| `/etc/ssl/certs/ca-certificates.crt` is a non-empty regular file there | the same | CA certificates removed or hidden by a later layer |
| `[layers]` is the manifest's layers, in order | the same | a layer list that does not describe the image (reordered, short) |
| the added layer changes the type of no base entry | the same | a directory over a base symlink, hiding what the link reaches |
| no path of the added tree is inside another (a file at `komira/bin/supervisor` would replace the supervisor) | `komira_oci tree` ([README](../../../tools/build/package/oci/README.md)), which lays out the tree; its welded unit tests hold the refusals to known paths | a file silently replacing a bundle's program |
| the base is pinned by digest: `oci_base_refusals` refuses a tag, a tagged reference, a short or upper-case digest, and accepts the pinned base | [`pin_cases.bzl`](pin_cases.bzl), at load time | a base named by tag, which could change under the same name |

Before any of these, `komira_oci layers` refuses an entrypoint that is not a
regular file with mode 0755 in the added layer, and `komira_oci image` a base
whose manifest does not hash to its pinned digest or does not name exactly
the downloaded blobs.
