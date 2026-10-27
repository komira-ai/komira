"""`conda_install_check`: a conda package installed into a clean prefix, and its
shared library loaded from there.

    conda_install_check(
        name = "libfoo_install",
        package = ":foo_conda",       # a conda_package (its default directory)
        lib = "libfoo.so",            # the file under lib/ to load
        symbols = ["foo_new"],        # each must resolve
        version_symbol = "foo_abi_version",
        min_version = 1000,
    )

Two actions, in two processes:

  1. `komira_pack conda-install` first refuses a package whose info/index.json
     `depends` lacks `mojo-compiler ==<pin>` (the runtime comes from the
     toolchain, so only this shows the package asks for it). It then writes the package's files into an empty
     directory, as an installer does, held to the package's own
     info/paths.json (hashes, sizes, links). Then the libraries the package's
     requirements install beside it are written to the same lib/: the Mojo
     runtime of its `mojo-compiler` requirement, taken from the toolchain
     (the platform row's `runtime_libs`, the loader's own record of what a
     built program loads). Nothing else is there: no `buck-out` path, no
     toolchain directory.
  2. `dlopen_probe` loads `<prefix>/lib/<lib>` with RTLD_NOW, resolves every
     symbol, calls the version symbol and reads /proc/self/maps: every mapped
     runtime library must come from the prefix. `LD_LIBRARY_PATH` is empty for
     the action and the probe refuses it set.

With `expect_red = "<text>"` the target is a negative case: it builds only
while `komira_pack conda-install` refuses the package with a reason containing
the text, and nothing is loaded. `depend_pin` then names a pin the package
does not hold (the check's own `--require-depend` is what must refuse it).

The output is the probe's marker (what it loaded). `[prefix]` is the install.
It checks a package on the farm; beta's `beta_validate` installs the published
files with a package manager and runs the same load again (docs/design/native_packaging.md,
"Built once, promoted unchanged", install check 4).
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoToolchainInfo")
load("@komira//tools/build/package:conda.bzl", "MOJO_COMPILER_VERSION")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/platforms:table.bzl", "row")

def _impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    package = ctx.attrs.package[DefaultInfo].default_outputs[0]
    runtime = row("linux-x86_64")["runtime_libs"]
    for r in ctx.attrs.require:
        if r not in runtime:
            fail("{}: require `{}` is not one of the platform row's runtime_libs {}".format(ctx.label, r, runtime))
    prefix = ctx.actions.declare_output("prefix", dir = True)
    ctx.actions.run(
        cmd_args(
            ctx.attrs._pack[RunInfo],
            "conda-install",
            "--dir",
            package,
            "--prefix",
            prefix.as_output(),
            "--require-depend",
            "mojo-compiler ==" + ctx.attrs.depend_pin,
            ["--expect-red", ctx.attrs.expect_red] if ctx.attrs.expect_red != None else [],
            [cmd_args("--runtime-lib", cmd_args(tc.compiler.project("lib/" + n), format = n + "={}")) for n in runtime],
        ),
        category = "conda_install",
    )
    if ctx.attrs.expect_red != None:
        # A negative case: the install is refused for the stated reason and
        # nothing is loaded.
        return [DefaultInfo(default_output = prefix)]
    marker = ctx.actions.declare_output(ctx.label.name + ".loaded")
    ctx.actions.run(
        cmd_args(
            ctx.attrs._probe[RunInfo],
            "--prefix",
            prefix,
            "--lib",
            ctx.attrs.lib,
            [cmd_args("--symbol", s) for s in ctx.attrs.symbols],
            ["--version-symbol", ctx.attrs.version_symbol, "--min-version", str(ctx.attrs.min_version)] if ctx.attrs.version_symbol else [],
            [cmd_args("--runtime", n) for n in runtime],
            [cmd_args("--require", n) for n in [ctx.attrs.lib] + ctx.attrs.require],
            "--out",
            marker.as_output(),
        ),
        env = {"LD_LIBRARY_PATH": ""},
        category = "dlopen_probe",
    )
    return [DefaultInfo(default_output = marker, sub_targets = {"prefix": [DefaultInfo(default_output = prefix)]})]

_conda_install_check = rule(
    impl = _impl,
    attrs = {
        # The `mojo-compiler` pin the package must depend on. Only a negative
        # case sets it (see `expect_red`): to a pin the package does not hold.
        "depend_pin": attrs.string(default = MOJO_COMPILER_VERSION),
        # A reason the install must be refused with: the target is a negative
        # case, built only while the check is red naming that defect.
        "expect_red": attrs.option(attrs.string(), default = None),
        "lib": attrs.string(),
        "min_version": attrs.int(default = 0),
        "package": attrs.dep(),
        # Runtime libraries (of the platform row's `runtime_libs`) that must be
        # mapped from the prefix, besides `lib` itself.
        "require": attrs.list(attrs.string(), default = ["libKGENCompilerRTShared.so"]),
        "symbols": attrs.list(attrs.string(), default = []),
        "toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
        "version_symbol": attrs.string(default = ""),
        "_pack": attrs.exec_dep(default = "komira//tools/build/package:komira_pack", providers = [RunInfo]),
        "_probe": attrs.exec_dep(default = "komira//tools/build/package/install_check:dlopen_probe", providers = [RunInfo]),
    },
)

def conda_install_check(**kwargs):
    _conda_install_check(exec_compatible_with = LINUX_X86_64, **kwargs)

conda_install_check = declares_docs(conda_install_check)
