"""The release set: every package a release of komira builds, as one tree.

    release_set(
        name = "release_set",
        packages = ["//src/komira_encoding:komira_encoding_conda", ...],
        artifacts = "artifacts.textproto",
        metapackage = "komira_all",
        ...
    )

The output is one directory (the platform's release directory, the layout the
retired release machine's BUILD step made): a subdirectory per package, named
for the package (the `_conda` target's name without the suffix), each exactly
what `<lib>_conda[release]` leaves (`<name>-<version>-<build>.conda`,
`manifest.json`, `metadata.json`); the metapackage's, which the packer's
`conda-meta` builds over every library's manifest; and, for a stamped build,
`release.json` (format kci.release_set major 2) and `set_hash.txt` (its set
hash), which //release/ci:release_json `write` produces as one more action of
the farm over the packages.

THE STAMP is the configuration's, never typed in a BUCK file: a release is
built with the three values //release/ci:release_json `stamp` derives from git
(`-c komira.package_stamp=<N> -c komira.package_commit=<C>
-c komira.package_timestamp_ms=<ms>`), the revision (`-c
komira.release_revision=<C>`, the full commit id, which is in the
metapackage's label and in release.json) and the run (`-c
komira.release_run_id=<id> -c komira.release_attempt=<n>`, release.json's
`produced_by`, which is in no package). A stamp given without the others
fails here. Without a stamp the packages are unstamped and so is the set: the
action still checks every package (name, platform, subdir, sha256, size,
metadata, the declared set) and writes a release.json under a dummy identity
that is not part of the output, so the pull request's check holds the real
packages to everything but the stamp.

THE SET IS HELD TO release/artifacts.textproto by a build action
(`release_json names`): the library names and their order, and the metapackage's
arguments (the packer's command, every library's manifest, the licence,
summary, home and label), must be the file's. A library added to one and not
the other, or a metapackage argument changed in one, is red.

Nothing here runs buck2: the packages are dependencies, and the metapackage
and the manifest are actions of the farm.
"""

load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

_EXTRA_FILE_PATH = "info/licenses/LICENSE"
_PLATFORM = "linux-x86_64"

# The identity of an unstamped set's release.json, which is never an output.
_UNSTAMPED_REVISION = "0" * 40

def _impl(ctx):
    if len(ctx.attrs.packages) != len(ctx.attrs.names):
        fail("{}: packages and names are one list (the macro writes both)".format(ctx.label))
    pack = ctx.attrs._pack[RunInfo]
    tool = ctx.attrs._release_json[RunInfo]
    stamped = ctx.attrs.stamped
    dirs = {}
    manifests = []
    for name, pkg in zip(ctx.attrs.names, ctx.attrs.packages):
        info = pkg[DefaultInfo]

        # A stamped build takes the package's `[release]` directory, which is
        # green only for a stamped package (its own release check); an
        # unstamped one takes the default output (the same files, unstamped).
        d = info.sub_targets["release"][DefaultInfo].default_outputs[0] if stamped else info.default_outputs[0]
        dirs[name] = d
        manifests.append(cmd_args("--member-manifest", cmd_args(d, format = "{}/manifest.json")))

    meta = ctx.actions.declare_output("meta/" + ctx.attrs.metapackage, dir = True)
    ctx.actions.run(
        cmd_args(
            pack,
            "conda-meta",
            "--name",
            ctx.attrs.metapackage,
            manifests,
            "--license",
            ctx.attrs.license,
            "--summary",
            ctx.attrs.summary,
            "--home",
            ctx.attrs.home,
            "--extra-file",
            cmd_args(ctx.attrs._license_file, format = _EXTRA_FILE_PATH + "={}"),
            "--label",
            ctx.attrs.label_prefix + (ctx.attrs.revision or "unstamped"),
            "--out-dir",
            meta.as_output(),
        ),
        category = "release_metapackage",
        identifier = ctx.attrs.metapackage,
    )
    dirs[ctx.attrs.metapackage] = meta

    checked = ctx.actions.declare_output("names.ok")
    ctx.actions.run(
        cmd_args(
            tool,
            "names",
            "--artifacts",
            ctx.attrs.artifacts,
            "--out",
            checked.as_output(),
            "--metapackage",
            ctx.attrs.metapackage,
            "--license",
            ctx.attrs.license,
            "--summary",
            ctx.attrs.summary,
            "--home",
            ctx.attrs.home,
            "--extra-file",
            _EXTRA_FILE_PATH + "=LICENSE",
            "--label-prefix",
            ctx.attrs.label_prefix,
            "--",
            ctx.attrs.names,
        ),
        category = "release_names",
    )

    members = ctx.actions.copied_dir("members", dirs)
    release_json = ctx.actions.declare_output("release.json")
    set_hash = ctx.actions.declare_output("set_hash.txt")
    ctx.actions.run(
        cmd_args(
            tool,
            "write",
            "--release-dir",
            members,
            "--artifacts",
            ctx.attrs.artifacts,
            "--revision",
            ctx.attrs.revision if stamped else _UNSTAMPED_REVISION,
            "--platform",
            _PLATFORM,
            "--run-id",
            ctx.attrs.run_id if stamped else "unstamped",
            "--attempt",
            ctx.attrs.attempt if stamped else "1",
            "--require-stamped",
            "true" if stamped else "false",
            "--out",
            release_json.as_output(),
            "--hash-file",
            set_hash.as_output(),
            hidden = [checked],
        ),
        category = "release_json",
    )

    if not stamped:
        return [DefaultInfo(default_output = members, other_outputs = [release_json, set_hash])]
    out = ctx.actions.copied_dir("release_set", dict(dirs, **{"release.json": release_json, "set_hash.txt": set_hash}))
    return [DefaultInfo(default_output = out)]

_release_set = rule(
    impl = _impl,
    attrs = {
        "artifacts": attrs.source(),
        "attempt": attrs.string(default = ""),
        "home": attrs.string(),
        "label_prefix": attrs.string(),
        "license": attrs.string(),
        "metapackage": attrs.string(),
        "names": attrs.list(attrs.string()),
        "packages": attrs.list(attrs.dep()),
        "revision": attrs.string(default = ""),
        "run_id": attrs.string(default = ""),
        "stamped": attrs.bool(),
        "summary": attrs.string(),
        "_license_file": attrs.source(default = "komira//:LICENSE"),
        "_pack": attrs.exec_dep(default = "komira//tools/build/package:komira_pack", providers = [RunInfo]),
        "_release_json": attrs.exec_dep(default = "komira//release/ci:release_json", providers = [RunInfo]),
    },
)

def release_set(name, packages, **kwargs):
    """See the module documentation. `packages` are `<name>_conda` targets, in
    the artifacts file's order."""
    names = []
    for p in packages:
        short = p.split(":")[-1]
        if not short.endswith("_conda"):
            fail("{}: {} is not a `_conda` target".format(name, p))
        names.append(short[:-len("_conda")])
    stamped = read_config("komira", "package_stamp", "0") != "0"
    revision = read_config("komira", "release_revision", "")
    run_id = read_config("komira", "release_run_id", "")
    attempt = read_config("komira", "release_attempt", "")
    if stamped and not (revision and run_id and attempt):
        fail("{}: a stamped build needs -c komira.release_revision=<the full commit id>, -c komira.release_run_id=<id> and -c komira.release_attempt=<n>".format(name))
    _release_set(
        name = name,
        packages = packages,
        names = names,
        stamped = stamped,
        revision = revision,
        run_id = run_id,
        attempt = attempt,
        exec_compatible_with = LINUX_X86_64,
        **kwargs
    )
