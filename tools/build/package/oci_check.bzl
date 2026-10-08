"""`oci_image_check`: an image read back, welded to the target that publishes it.

    oci_image_check(name, image, entrypoint, executables = [], files = [])

runs [oci_check.sh](oci_check.sh) over the OCI layout of `image` (an
`oci_image`) in a build action, and is that image with the check's output
added to its default output and to each sub-target (`[digest]`,
`[docker_archive]`, `[layers]`), so building any of them runs the check: an
image that fails it cannot be built through this target. Red unless the
config's Entrypoint is exactly `[entrypoint]`; `entrypoint` and each of
`executables` (paths relative to /) is a regular file with mode 0755 in the
image's filesystem (layers applied in order, whiteouts and symbolic links
followed); each of `files` is a regular file of one byte or more there; the
`[layers]` file holds the manifest's layer digests in order; and the added
layer changes the type of no base entry. `[check]` is the check's output.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load(":defs.bzl", "OciImageInfo")

def _impl(ctx):
    img = ctx.attrs.image[OciImageInfo]
    if not ctx.attrs.entrypoint.startswith("/"):
        fail("{}: entrypoint `{}` is not an absolute path".format(ctx.label, ctx.attrs.entrypoint))
    checks = []
    for kind, paths in [("exec", ctx.attrs.executables), ("file", ctx.attrs.files)]:
        for p in paths:
            if p.startswith("/") or not p:
                fail("{}: `{}` must be a path relative to /".format(ctx.label, p))
            checks.extend([kind, p])
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    # Copied under buck-out: a source's path differs between a standalone
    # checkout and a repository that mounts komira as a cell, and so would the
    # action's digest.
    script = ctx.actions.copy_file(ctx.label.name + ".oci_check.sh", ctx.attrs._script)
    out = ctx.actions.declare_output(ctx.label.name + ".oci_check")
    ctx.actions.run(
        cmd_args(bb, "sh", script, bb, out.as_output(), img.layout, img.layers, ctx.attrs.entrypoint, checks),
        category = "oci_check",
    )
    d = ctx.attrs.image[DefaultInfo]
    subs = {
        k: [DefaultInfo(default_outputs = v[DefaultInfo].default_outputs, other_outputs = [out])]
        for k, v in d.sub_targets.items()
    }
    subs["check"] = [DefaultInfo(default_output = out)]
    return [
        DefaultInfo(default_outputs = d.default_outputs, other_outputs = [out], sub_targets = subs),
        img,
    ]

_oci_image_check = rule(
    impl = _impl,
    attrs = {
        "entrypoint": attrs.string(),
        "executables": attrs.list(attrs.string(), default = []),
        "files": attrs.list(attrs.string(), default = []),
        "image": attrs.dep(providers = [OciImageInfo]),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        "_script": attrs.source(default = "komira//tools/build/package:oci_check.sh"),
    },
)

def oci_image_check(**kwargs):
    _oci_image_check(exec_compatible_with = LINUX_X86_64, **kwargs)

oci_image_check = declares_docs(oci_image_check)
