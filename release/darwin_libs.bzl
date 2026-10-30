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

DARWIN_EXCLUDED is the packages whose closure holds native code (an `//src/<name>:native_*` archive,
reached through `deps`): a C or C++ dependency cannot build for darwin-arm64 yet (DEVELOPMENT.md, "macOS
workers"). Each entry names the native target that puts it there; a package leaves the list when its native
code builds for macOS. The list is the answer of

    ./buck2 uquery 'rdeps(<every :lib of packages.bzl>, <every native_* archive of mopm_artifacts>)'

so a package that comes to depend on native code is a red `release-macos` job (not a red release: the
job reports and does not block, release.yml says why) until it is added here.
"""

load("//release/readme_e2e:packages.bzl", README_E2E_PACKAGES = "PACKAGES")

# package -> the native archive of its closure that cannot build for macOS yet
DARWIN_EXCLUDED = {
    "kci_reconciler": "//src/komira_libc:native_komira_libc_posix",
    "komira_async_api": "//src/komira_async_api:native_komira_concurrency_pool_depth",
    "komira_buffer": "//src/komira_libc:native_komira_libc_posix",
    "komira_bump_arena": "//src/komira_libc:native_komira_libc_posix",
    "komira_dynamic_filter": "//src/komira_libc:native_komira_libc_posix",
    "komira_libc": "//src/komira_libc:native_komira_libc_posix",
    "komira_log": "//src/komira_log:native_komira_log_holder",
    "komira_mail_message": "//src/komira_libc:native_komira_libc_posix",
    "komira_metrics": "//src/komira_metrics:native_komira_metrics_ea_flag",
}

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
