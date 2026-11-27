"""The npm release set: every npm package of one release, as one directory.

    npm_packages(
        name = "npm_packages",
        main = "@komira-ai/komira",
        packages = {
            "@komira-ai/komira": "//node:package",
            "@komira-ai/komira-linux-x64-gnu": "//node:package_linux_x64",
        },
    )

`packages` maps each npm name to its `npm_tarball` target (tools/build/package/npm.bzl), and `main` names
the package that names the others in its optionalDependencies: exactly the set's platform packages, which
the set holds it to (`npm_smoke set --main-optional`, the names of its NpmTarballInfo), so a main package
never names a platform package that is not published with it. The output is one directory: each tarball
under the name `npm pack` gives it, and npm_set.json, which //release/ci:npm_smoke `set` writes from the
tarballs (release/ci/npm_smoke/set.zig): each package's name, version, file, SHA-256 and the sha512
`integrity` npm reports, the platform packages first and the main package last, the order npm.yml publishes
them in. The sub-target `[npm_set.json]` is the record alone.

THE STAMP is the configuration's, as for every npm_tarball: built with `-c komira.package_stamp=<N>
-c komira.package_commit=<C> -c komira.package_timestamp_ms=<ms>` (what //release/ci:release_json `stamp`
derives from git) the set takes each package's `[release]` tarball, which exists only when the package is
stamped, and the tool refuses a set that is not; built without (the pull request's check) it takes each
default tarball, at 0.0.0, and the set is checked all the same (one version, npm pack's file names, the
main package among the packages) without the stamp.

`npm_packages_macos` is the same set with one more platform package, `macos_arm64` (`macos_arm64_name`
its npm name), configured for darwin-arm64 by a transition, as `--target-platforms
komira//tools/build/platforms:darwin-arm64` configures it, so its actions are the ones the macOS install test
built: the set npm.yml publishes when that test passed. Its main package is one that names the macOS
package too. Building it needs the macOS execution platform registered (farm-connect's macOS inputs).

`npm_names_json` writes, at analysis, the names of a set in npm_set.json's shape
(`{"packages": [{"name": ...}, ...]}`), so the check of release/npm_names.txt reads the names of a set it
cannot build (the macOS one, in a pull request) from the list that declares it.

It is not the conda release set: no member of //release:release_set and no entry of
release/artifacts.textproto, which hold `_conda` targets only (`release_json names` checks that). The names
are listed in release/npm_names.txt, which //release:npm_names_cases holds equal to the set.
"""

load("@komira//tools/build/package:npm.bzl", "NpmTarballInfo")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

def _set(ctx, packages):
    tool = ctx.attrs._npm_smoke[RunInfo]
    stamped = ctx.attrs.stamped
    main = packages[ctx.attrs.main]
    files = {}
    args = []
    for name, pkg in sorted(packages.items()):
        info = pkg[DefaultInfo]
        tgz = info.sub_targets["release"][DefaultInfo].default_outputs[0] if stamped else info.default_outputs[0]
        if tgz.basename in files:
            fail("{}: two packages are the file {}".format(ctx.label, tgz.basename))
        files[tgz.basename] = tgz
        args.append(cmd_args("--package", cmd_args(tgz, format = name + "={}")))
    record = ctx.actions.declare_output("npm_set.json")
    ctx.actions.run(
        cmd_args(
            tool,
            "set",
            "--main",
            ctx.attrs.main,
            "--main-optional",
            ",".join(main[NpmTarballInfo].optional_dependencies),
            "--require-stamped",
            "true" if stamped else "false",
            "--out",
            record.as_output(),
            args,
        ),
        category = "npm_set",
    )
    out = ctx.actions.copied_dir("npm_packages", dict(files, **{"npm_set.json": record}))
    return [DefaultInfo(
        default_output = out,
        sub_targets = {"npm_set.json": [DefaultInfo(default_output = record)]},
    )]

def _impl(ctx):
    return _set(ctx, ctx.attrs.packages)

def _macos_impl(ctx):
    return _set(ctx, dict(ctx.attrs.packages, **{ctx.attrs.macos_arm64_name: ctx.attrs.macos_arm64}))

_ATTRS = {
    "main": attrs.string(),
    "packages": attrs.dict(attrs.string(), attrs.dep(providers = [NpmTarballInfo])),
    "stamped": attrs.bool(),
    "_npm_smoke": attrs.exec_dep(default = "komira//release/ci:npm_smoke", providers = [RunInfo]),
}

_npm_packages = rule(impl = _impl, attrs = _ATTRS)

def _darwin_arm64_impl(platform, refs):
    # the platform `--target-platforms komira//tools/build/platforms:darwin-arm64` names, unchanged, as
    # mopm_artifacts.bzl's transition: the macOS package is configured as npm.yml's macOS job configures its
    # install test, so its actions are the same actions (and the same cache entries); `platform` is not read
    _ = platform
    return refs.darwin_arm64[PlatformInfo]

_DARWIN_ARM64 = transition(impl = _darwin_arm64_impl, refs = {"darwin_arm64": "komira//tools/build/platforms:darwin-arm64"})

_npm_packages_macos = rule(impl = _macos_impl, attrs = _ATTRS | {
    "macos_arm64": attrs.transition_dep(cfg = _DARWIN_ARM64, providers = [NpmTarballInfo]),
    "macos_arm64_name": attrs.string(),
})

def _stamped():
    # The tarballs' own reading of the stamp (wheel.bzl, wheel_version): "" and "0" are unstamped.
    return read_config("komira", "package_stamp", "0") not in ("", "0")

def npm_packages(name, main, packages, **kwargs):
    """See the module documentation."""
    if main not in packages:
        fail("{}: the main package {} is not one of packages".format(name, main))
    _npm_packages(
        name = name,
        main = main,
        packages = packages,
        stamped = _stamped(),
        exec_compatible_with = LINUX_X86_64,
        **kwargs
    )

def npm_packages_macos(name, main, packages, macos_arm64_name, macos_arm64, **kwargs):
    """See the module documentation."""
    if main not in packages:
        fail("{}: the main package {} is not one of packages".format(name, main))
    _npm_packages_macos(
        name = name,
        main = main,
        packages = packages,
        macos_arm64_name = macos_arm64_name,
        macos_arm64 = macos_arm64,
        stamped = _stamped(),
        exec_compatible_with = LINUX_X86_64,
        **kwargs
    )

def _names_impl(ctx):
    out = ctx.actions.write_json(ctx.label.name + ".json", {"packages": [{"name": n} for n in ctx.attrs.names]})
    return [DefaultInfo(default_output = out)]

npm_names_json = rule(impl = _names_impl, attrs = {"names": attrs.list(attrs.string())})
