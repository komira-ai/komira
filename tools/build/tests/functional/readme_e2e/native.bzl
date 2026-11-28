"""A mopm package of a real Mojo library and a real static archive, made by the pinned `mopm pack`."""

load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/toolchains:mojo_versions.bzl", "mojo_version")

def _impl(ctx):
    package = ctx.attrs.package
    namespace, name = package.split("/")
    channel = ctx.actions.declare_output("channel", dir = True)
    mojoc = ctx.attrs.lib[DefaultInfo].default_outputs[0]

    # mopm names the library by the archive's file name: `lib<id>.a` for `[native.<id>]`.
    archive = ctx.actions.copy_file("natives/lib{}.a".format(ctx.attrs.native_id), ctx.attrs.archive[DefaultInfo].default_outputs[0])
    cmd = cmd_args(
        ctx.attrs.mopm[RunInfo],
        "pack",
        "--compiler",
        ctx.attrs.mojo,
        "--mojoc",
        cmd_args("linux-64=", mojoc, delimiter = ""),
        "--manifest",
        ctx.attrs.manifest,
        "--native",
        cmd_args("{}=linux-64:".format(ctx.attrs.native_id), archive, delimiter = ""),
        "-o",
        channel.as_output(),
    )
    ctx.actions.run(cmd, category = "mopm_pack", identifier = package)
    conda = channel.project("linux-64/mojo-{}.{}-{}-mojo{}_0.conda".format(namespace, name, ctx.attrs.version, ctx.attrs.mojo))
    return [DefaultInfo(default_output = conda)]

_native_conda = rule(
    impl = _impl,
    doc = "`mojo-<namespace>.<name>-<version>-mojo<mojo>_0.conda`, as `mopm pack` writes it for a package that ships a static native library: `package` is the full name `<namespace>/<name>`, `lib` the Mojo package (`<name>.mojoc`), `archive` the static archive of `[native.<native_id>]` in `manifest`, packed as `lib<native_id>.a`.",
    attrs = {
        "archive": attrs.dep(),
        "lib": attrs.dep(),
        "manifest": attrs.source(),
        "mojo": attrs.string(doc = "The compiler the package is packed for (the macro: the target platform's, mojo_version())."),
        "mopm": attrs.exec_dep(providers = [RunInfo]),
        "native_id": attrs.string(),
        "package": attrs.string(),
        "version": attrs.string(),
    },
)

def native_conda(**kwargs):
    if "mojo" not in kwargs:
        kwargs["mojo"] = mojo_version()
    _native_conda(exec_compatible_with = LINUX_X86_64, **kwargs)
