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
the package that names the others in its optionalDependencies. The output is one directory: each tarball
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

It is not the conda release set: no member of //release:release_set and no entry of
release/artifacts.textproto, which hold `_conda` targets only (`release_json names` checks that). The names
are listed in release/npm_names.txt, which //release:npm_names_cases holds equal to the set.
"""

load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

def _impl(ctx):
    tool = ctx.attrs._npm_smoke[RunInfo]
    stamped = ctx.attrs.stamped
    files = {}
    args = []
    for name, pkg in sorted(ctx.attrs.packages.items()):
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

_npm_packages = rule(
    impl = _impl,
    attrs = {
        "main": attrs.string(),
        "packages": attrs.dict(attrs.string(), attrs.dep()),
        "stamped": attrs.bool(),
        "_npm_smoke": attrs.exec_dep(default = "komira//release/ci:npm_smoke", providers = [RunInfo]),
    },
)

def npm_packages(name, main, packages, **kwargs):
    """See the module documentation."""
    if main not in packages:
        fail("{}: the main package {} is not one of packages".format(name, main))
    _npm_packages(
        name = name,
        main = main,
        packages = packages,
        # The tarballs' own reading of the stamp (wheel.bzl, wheel_version): "" and "0" are unstamped.
        stamped = read_config("komira", "package_stamp", "0") not in ("", "0"),
        exec_compatible_with = LINUX_X86_64,
        **kwargs
    )
