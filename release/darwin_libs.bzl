"""The macOS arm64 build set of the release: the library of every mopm package that builds there.

    mopm_darwin_libs(name = "mopm_darwin_libs", packages = DARWIN_PACKAGES)

The set is ONE list. It is every package of //release/readme_e2e:packages.bzl (every `src/<name>`
with a `mopm.toml`, which //:readme_e2e_complete holds to the files of the checkout in both
directions) except the packages in DARWIN_EXCLUDED, so a package moved to mopm joins the macOS build
the day it joins the list the Linux release builds. Nothing is generated: there is no second list to
go stale.

What it builds: each package's `:lib` for `--target-platforms komira//tools/build/platforms:darwin-arm64`
(release.yml's job `release-macos`), so a library's welded tests run inside its build, on the macOS
workers of the farm. The output is one directory, `osx-arm64/<name>.mojoc`, the layout `mopm stage
--artifacts` reads for that platform. Nothing is staged or published from it.

DARWIN_EXCLUDED is the packages left out of that build: a package whose closure cannot build for
darwin-arm64, each with the reason. It is empty: the C a package owns (a `[native.<id>]` archive such as
libc_posix, log_holder, metrics_ea_flag, concurrency_pool_depth) is compiled for aarch64-macos by the
pinned zig, so every package of the list builds there and its welded tests run on the macOS workers.
What is not supported is a vendored third_party C or C++ library inside a `mojo_package`; a package
whose closure reaches one is added here with that reason, which is the answer of

    ./buck2 uquery 'rdeps(<every :lib of packages.bzl>, <the third_party archives>)'

so such a package is a red `release-macos` job (not a red release: the job reports and does not
block, release.yml says why) until it is added here.
"""

load("//release/readme_e2e:packages.bzl", README_E2E_PACKAGES = "PACKAGES")

# package -> why it cannot build for macOS (none today)
DARWIN_EXCLUDED = {}

def darwin_packages(packages = README_E2E_PACKAGES, excluded = DARWIN_EXCLUDED):
    """The packages of `packages` (a dict or a list of names) that are not in `excluded`, sorted. Refuses an excluded name that is no package, so a deleted package leaves the list."""
    names = sorted(packages)
    for name in excluded:
        if name not in names:
            fail("DARWIN_EXCLUDED names {}, which is not a package of release/readme_e2e/packages.bzl".format(name))
    return [n for n in names if n not in excluded]

DARWIN_PACKAGES = darwin_packages()

def _impl(ctx):
    tree = {}
    for name, lib in zip(ctx.attrs.names, ctx.attrs.libs):
        tree["osx-arm64/" + name + ".mojoc"] = lib[DefaultInfo].default_outputs[0]
    return [DefaultInfo(default_output = ctx.actions.copied_dir("mopm_darwin_libs", tree))]

_mopm_darwin_libs = rule(
    impl = _impl,
    attrs = {
        "libs": attrs.list(attrs.dep()),
        "names": attrs.list(attrs.string()),
    },
)

def mopm_darwin_libs(name, packages, **kwargs):
    """See the module documentation. `packages` are directory names under src/."""
    if not packages:
        fail("{}: no package".format(name))
    _mopm_darwin_libs(
        name = name,
        names = packages,
        libs = ["komira//src/{}:lib".format(p) for p in packages],
        **kwargs
    )
