"""The macOS arm64 build set of the release: the library of every mopm package that builds there.

    mopm_darwin_libs(name = "mopm_darwin_libs", packages = DARWIN_PACKAGES)

The set is ONE list. It is every package of //release/readme_e2e:packages.bzl (every `src/<name>`
with a `mopm.toml`, which //:readme_e2e_complete holds to the files of the checkout in both
directions) except the packages in DARWIN_EXCLUDED, so a package moved to mopm joins the macOS build
the day it joins the list the Linux release builds. Nothing is generated: there is no second list to
go stale.

What it builds: each package's `:lib` for `--target-platforms komira//tools/build/platforms:darwin-arm64`
(release-macos.yml's job `release-macos`), so a library's welded tests run inside its build, on the macOS
workers of the farm, and each declared native's archive for the same platform (the `natives` of
//release:mopm_artifacts, the archive the package's tests linked). The output is one directory,
`osx-arm64/<namespace>/<name>.mojoc` and `osx-arm64/<namespace>/<name>.native/lib<id>.a`, the layout
`mopm stage --artifacts` reads for that platform (mopm_artifacts.bzl's `mojoc_path` and `native_path`), and
its tree as `MopmTreeInfo`: //release:mopm_release_artifacts (mopm_artifacts.bzl) configures it for
darwin-arm64 and merges it with the linux-64 tree into the directory release.yml's `mopm-stage` stages and
publishes. Its sub-target `[layout]` lists the paths (//release:artifacts_layout_cases).

DARWIN_EXCLUDED is the packages left out of that build: a package whose closure cannot build for
darwin-arm64, each with the reason. It is empty: the C a package owns (a `[native.<id>]` archive such as
libc_posix, log_holder, metrics_ea_flag, concurrency_pool_depth) is compiled for aarch64-macos by the
pinned zig, so every package of the list builds there and its welded tests run on the macOS workers.
What is not supported is a vendored third_party C or C++ library inside a `mojo_package`; a package
whose closure reaches one is added here with that reason, which is the answer of

    ./buck2 uquery 'rdeps(<every :lib of packages.bzl>, <the third_party archives>)'

so such a package fails the macOS part of the pull request check that reaches it (pr.yml builds the
`:lib` of each package of this list the change reaches, tools/build/ci/darwin.bzl), and the
`release-macos` job, until it is added here. A package whose closure says so at configuration or
analysis (a target or toolchain incompatible with darwin-arm64) fails in the pull request that adds it
too: pr.yml configures and analyses this whole set for darwin-arm64 (release/darwin_analysis.bxl),
building nothing.
"""

load("//release/readme_e2e:packages.bzl", README_E2E_PACKAGES = "PACKAGES")
load(":mopm_artifacts.bzl", "MopmTreeInfo", "check_natives", "mojoc_path", "native_path")

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

# The macOS Python harness tests: release-macos.yml's step `build the macOS Python harness tests`
# builds exactly these, after the set, for darwin-arm64 (//:release_macos_cases holds the step's
# args to this list), and pr.yml's analysis of the set analyses them too (release/darwin_analysis.bxl),
# so a target of their closure that cannot run on a macOS worker fails in its pull request. The
# last is every common-task example on the macOS arm64 wheel (python/docs/tasks/BUCK).
DARWIN_PYTHON_HARNESS = [
    "komira//tools/build/examples/python_binding:hello",
    "komira//tools/build/examples/python_binding:refuses_missing_lib",
    "komira//tools/build/examples/python_binding:refuses_wrong_add",
    "komira//tools/build/examples/python_binding:refuses_wrong_sum",
    "komira//python/docs/tasks:examples_macos_arm64",
]

# The macOS npm targets: .github/workflows/npm.yml's macOS job (build-macos-arm64) builds the platform
# package and runs its install test, for darwin-arm64, then builds the npm set with the macOS package
# (DARWIN_NPM_SET, for Linux: its transition configures the macOS package inside it), and pr.yml's
# analysis of the macOS set analyses them too (release/darwin_analysis.bxl), so a target of their closure that cannot run on a macOS worker fails in
# its pull request.
DARWIN_NPM = [
    "komira//node:package_macos_arm64",
    "komira//node:install_test_macos_arm64",
]

DARWIN_NPM_SET = "komira//release:npm_packages_macos_arm64"

def _impl(ctx):
    tree = {}
    for name, lib in zip(ctx.attrs.names, ctx.attrs.libs):
        tree[mojoc_path("osx-arm64", name)] = lib[DefaultInfo].default_outputs[0]
    for package, archives in ctx.attrs.natives.items():
        for native_id, archive in archives.items():
            tree[native_path("osx-arm64", package, native_id)] = archive[DefaultInfo].default_outputs[0]
    # The paths, written at analysis: a Linux check reads them without building for macOS.
    layout = ctx.actions.write_json("mopm_darwin_libs.layout.json", sorted(tree.keys()))
    return [
        DefaultInfo(
            default_output = ctx.actions.copied_dir("mopm_darwin_libs", tree),
            sub_targets = {"layout": [DefaultInfo(default_output = layout)]},
        ),
        MopmTreeInfo(subdir = "osx-arm64", tree = tree),
    ]

_mopm_darwin_libs = rule(
    impl = _impl,
    attrs = {
        "libs": attrs.list(attrs.dep()),
        "names": attrs.list(attrs.string()),
        "natives": attrs.dict(attrs.string(), attrs.dict(attrs.string(), attrs.dep()), default = {}),
    },
)

def mopm_darwin_libs(name, packages, natives = {}, **kwargs):
    """See the module documentation. `packages` are directory names under src/; `natives` is the release's
    `{package: {id: archive target}}` (the one //release:mopm_artifacts takes), of which the packages of
    `packages` are kept, so a package left out of the macOS build takes its archives with it."""
    if not packages:
        fail("{}: no package".format(name))
    kept = {p: archives for p, archives in natives.items() if p in packages}
    check_natives(name, packages, kept)
    _mopm_darwin_libs(
        name = name,
        names = packages,
        libs = ["komira//src/{}:lib".format(p) for p in packages],
        natives = kept,
        **kwargs
    )
