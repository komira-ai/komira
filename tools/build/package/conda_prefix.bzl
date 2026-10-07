"""A conda environment made from this build's packages, for a build action to
run programs in (README.md, "Conda packages").

    conda_prefix(
        name = "crypto_env",
        root = "komira_crypto",
        packages = [
            "//src/komira_crypto:komira_crypto_conda",
            "//src/komira_encoding:komira_encoding_conda",
            "//tools/build/native:komira_native_conda",
        ],
    )

The output is a directory laid out as `conda install <root>` lays out an
environment: `komira_pack conda-install` follows `root`'s run requirements
through `packages` (the pool a solver would pick from) and extracts what they
reach, each package's files and symbolic links at their paths. Only what the
requirements reach is installed, so a package that fails to require what it
needs is missing from the prefix, as it would be from a user's environment;
a requirement no package in the pool meets at exactly its version and build
fails the action. The Mojo compiler (`mojo-compiler ==V`) and the virtual
packages are the environment's: the programs run with the toolchain's.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

def _conda_prefix_impl(ctx):
    out = ctx.actions.declare_output("prefix", dir = True)
    dirs = [p[DefaultInfo].default_outputs[0] for p in ctx.attrs.packages]
    ctx.actions.run(
        cmd_args(
            ctx.attrs._pack[RunInfo],
            "conda-install",
            "--prefix",
            out.as_output(),
            "--root",
            ctx.attrs.root,
            [cmd_args("--package-dir", d) for d in dirs],
        ),
        category = "conda_install",
    )
    return [DefaultInfo(default_output = out)]

_conda_prefix = rule(
    impl = _conda_prefix_impl,
    attrs = {
        "packages": attrs.list(attrs.dep(), doc = "Package targets (conda_package, conda_native_package): their default directories are the pool."),
        "root": attrs.string(doc = "The conda name installed, with what its run requirements reach."),
        "_pack": attrs.exec_dep(default = "komira//tools/build/package:komira_pack", providers = [RunInfo]),
    },
)

def conda_prefix(**kwargs):
    """See the module documentation."""
    _conda_prefix(exec_compatible_with = LINUX_X86_64, **kwargs)

conda_prefix = declares_docs(conda_prefix)
