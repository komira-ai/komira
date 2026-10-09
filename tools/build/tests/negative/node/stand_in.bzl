"""A stand-in npm package for the analysis-time refusals of test 54.

It provides NpmPackageInfo (loaded from komira, so the provider is the one the
rules require) over a checked-in file, at the name and version a fixture
gives it. Nothing reads the file: analysis refuses each fixture first.
"""

load("@komira//tools/build/node:defs.bzl", "NpmPackageInfo")

def _impl(ctx):
    return [
        DefaultInfo(),
        NpmPackageInfo(
            name = ctx.attrs.package,
            version = ctx.attrs.version,
            closure = {ctx.attrs.package: (ctx.attrs.version, ctx.attrs.dir)},
        ),
    ]

stand_in_npm = rule(
    impl = _impl,
    attrs = {
        "dir": attrs.source(),
        "package": attrs.string(),
        "version": attrs.string(),
    },
)
