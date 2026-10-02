"""A RELEASE SET of conda packages, generated from the approved list.

`load("@komira//tools/build/package:conda_set.bzl", "conda_release")`

    load(":names.bzl", "APPROVED")        # generated from names.tsv

    conda_release(entries = APPROVED)

One call instantiates, for every name in the approved list:

  * a `conda_package` named for it (conda.bzl): so adding a row to
    `packaging/conda/names.tsv` adds the package, and no BUCK file states a
    package by hand;
  * `metapackage`: a package with no file whose run requirements are EVERY
    approved library at exactly this version. Installing it installs the whole
    release set. It is a package of its own name (`packaging/conda/METAPACKAGE`),
    and a registry that receives it LAST makes it the switch for users;
  * `release_set`: one directory, `<name>.conda` for every package and
    `release_set.json`, written only after the whole set is verified
    (`komira_pack conda-set`): every approved name present, versions, subdir and
    source commit one value across the set, every requirement an approved
    library at the set's version or an allowed external (the platform guard, the
    compiler at its pin), the metapackage pinning exactly the libraries.

Sub-targets, THE OUTPUT CONTRACT: an uploader of a set reads `release_set` and
nothing else.

    release_set              the directory
    release_set[manifest]    release_set.json (inside the directory): schema,
                             artifact_type `conda-release-set`, version, subdir,
                             source_commit, approved_names_sha256, mojo_pin,
                             metapackage, member_count, upload_order (channel
                             file names, members by name, the metapackage LAST)
                             and `artifacts`, in that order: role, name, version,
                             subdir, file_name (the channel's), path (inside the
                             directory), sha256, size, depends, source_commit
    metapackage[release]     as a library package's: stamped builds only

An unstamped build has no `release_set`: its members have no `[release]`.
Nothing is uploaded; what a publish step must do with the set is specified in
packaging/conda/README.md.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/package:conda.bzl", "MOJO_COMPILER_PIN", "PACKAGE_HOME", "PACKAGE_LICENSE", "PUBLISHED_NAME_PREFIX", "conda_package")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

# What a library package may require besides another library of the set: the
# platform guard and the compiler (at its exact pin, checked by the tool).
EXTERNAL_REQUIREMENTS = ["__linux", "mojo-compiler"]

_SUMMARY = "The metapackage of a komira release: it installs every komira library at one version, and holds no file."

def _copy_all(ctx, bb, pairs, category, identifier, hidden):
    # The published files are copies made after the check passed, so none of
    # them exists unless it did.
    ctx.actions.run(
        cmd_args(
            bb,
            "sh",
            "-euc",
            '"$1" cp "$2" "$3"; "$1" cp "$4" "$5"; "$1" cp "$6" "$7"',
            "sh",
            bb,
            [[src, dst.as_output()] for src, dst in pairs],
            hidden = hidden,
        ),
        category = category,
        identifier = identifier,
    )

def _conda_metapackage_impl(ctx):
    pack = ctx.attrs._pack[RunInfo]
    name = ctx.label.name
    prefix = PUBLISHED_NAME_PREFIX
    stem = "raw/" + name
    raw = ctx.actions.declare_output(stem + ".conda")
    raw_manifest = ctx.actions.declare_output(stem + ".manifest.json")
    raw_digest = ctx.actions.declare_output(stem + ".digest")
    if ctx.attrs.names_custom and ctx.label.cell != "tests":
        fail("{}: names = ... states a list other than the approved one (packaging/conda/names.tsv). Only the tests cell does that, for its fixtures".format(ctx.label))

    # The members are inputs: the metapackage cannot exist unless each library
    # package was built and checked.
    member_checks = [m[DefaultInfo].sub_targets["check"][DefaultInfo].default_outputs for m in ctx.attrs.members]
    release_checks = [m[DefaultInfo].sub_targets["release_check"][DefaultInfo].default_outputs for m in ctx.attrs.members]
    lint = ctx.attrs.names_lint[DefaultInfo].default_outputs if ctx.attrs.names_lint else []
    ctx.actions.run(
        cmd_args(
            pack,
            "conda-meta",
            "--names",
            ctx.attrs.names,
            "--name-prefix",
            prefix,
            "--meta-name-file",
            ctx.attrs._meta_name,
            "--version-prefix",
            ctx.attrs._version_prefix,
            "--stamp",
            ctx.attrs.stamp,
            "--timestamp-ms",
            ctx.attrs.timestamp_ms,
            ["--commit", ctx.attrs.commit] if ctx.attrs.commit else [],
            "--subdir",
            ctx.attrs.subdir,
            "--license",
            PACKAGE_LICENSE,
            "--summary",
            _SUMMARY,
            "--home",
            PACKAGE_HOME,
            "--extra-file",
            cmd_args(ctx.attrs._license_file, format = "info/licenses/LICENSE={}"),
            "--label",
            str(ctx.label.raw_target()),
            "--out",
            raw.as_output(),
            "--conda-manifest",
            raw_manifest.as_output(),
            "--digest",
            raw_digest.as_output(),
            hidden = member_checks,
        ),
        category = "conda_meta",
        identifier = name,
    )

    def check(marker_name, extra, hidden):
        marker = ctx.actions.declare_output(marker_name)
        ctx.actions.run(
            cmd_args(
                pack,
                "conda-meta-check",
                "--package",
                raw,
                "--conda-manifest",
                raw_manifest,
                "--names",
                ctx.attrs.names,
                "--name-prefix",
                prefix,
                "--meta-name-file",
                ctx.attrs._meta_name,
                "--expect-subdir",
                ctx.attrs.subdir,
                extra,
                "--out",
                marker.as_output(),
                hidden = lint + hidden,
            ),
            category = "conda_meta_check",
            identifier = marker_name,
        )
        return marker

    checked = check("metapackage.checked", [], member_checks)
    release_checked = check("metapackage.release_checked", ["--require-stamped", "true"], release_checks)

    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output("metapackage.conda")
    out_manifest = ctx.actions.declare_output("metapackage.manifest.json")
    out_digest = ctx.actions.declare_output("metapackage.digest")
    _copy_all(ctx, bb, [(raw, out), (raw_manifest, out_manifest), (raw_digest, out_digest)], "conda_meta_join", name, [checked])
    rel = ctx.actions.declare_output("release/metapackage.conda")
    rel_manifest = ctx.actions.declare_output("release/metapackage.manifest.json")
    rel_digest = ctx.actions.declare_output("release/metapackage.digest")
    _copy_all(ctx, bb, [(raw, rel), (raw_manifest, rel_manifest), (raw_digest, rel_digest)], "conda_meta_release_join", name, [release_checked])
    return [DefaultInfo(
        default_output = out,
        sub_targets = {
            "check": [DefaultInfo(default_output = checked)],
            "digest": [DefaultInfo(default_output = out_digest)],
            "file": [DefaultInfo(default_output = out)],
            "manifest": [DefaultInfo(default_output = out_manifest)],
            "release": [DefaultInfo(
                default_output = rel,
                sub_targets = {
                    "digest": [DefaultInfo(default_output = rel_digest)],
                    "file": [DefaultInfo(default_output = rel)],
                    "manifest": [DefaultInfo(default_output = rel_manifest)],
                },
            )],
            "release_check": [DefaultInfo(default_output = release_checked)],
        },
    )]

_conda_metapackage = rule(
    impl = _conda_metapackage_impl,
    attrs = {
        "commit": attrs.string(default = ""),
        "members": attrs.list(attrs.dep()),
        "names": attrs.source(default = "komira//packaging/conda:names.tsv"),
        "names_custom": attrs.bool(default = False),
        "names_lint": attrs.option(attrs.dep(), default = None),
        "stamp": attrs.string(),
        "subdir": attrs.string(),
        "timestamp_ms": attrs.string(),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        "_license_file": attrs.source(default = "komira//:LICENSE"),
        "_meta_name": attrs.source(default = "komira//packaging/conda:METAPACKAGE"),
        "_pack": attrs.exec_dep(default = "komira//tools/build/package:komira_pack", providers = [RunInfo]),
        "_version_prefix": attrs.source(default = "komira//packaging/conda:VERSION_PREFIX"),
    },
)

def _release_part(dep, which):
    return dep[DefaultInfo].sub_targets["release"][DefaultInfo].sub_targets[which][DefaultInfo].default_outputs[0]

def _conda_release_set_impl(ctx):
    pack = ctx.attrs._pack[RunInfo]
    if ctx.attrs.names_custom and ctx.label.cell != "tests":
        fail("{}: names = ... states a list other than the approved one (packaging/conda/names.tsv). Only the tests cell does that, for its fixtures".format(ctx.label))
    out = ctx.actions.declare_output("set", dir = True)
    pairs = [cmd_args(_release_part(m, "manifest"), _release_part(m, "file"), delimiter = "=") for m in ctx.attrs.members]
    meta = ctx.attrs.meta
    # Naming the release parts makes the set depend on every package's release
    # check: nothing here exists for an unstamped or unchecked package.
    ctx.actions.run(
        cmd_args(
            pack,
            "conda-set",
            "--names",
            ctx.attrs.names,
            "--name-prefix",
            PUBLISHED_NAME_PREFIX,
            "--meta-name-file",
            ctx.attrs._meta_name,
            "--mojo-pin",
            MOJO_COMPILER_PIN,
            [["--external", e] for e in EXTERNAL_REQUIREMENTS],
            [["--member", p] for p in pairs],
            "--meta",
            cmd_args(_release_part(meta, "manifest"), _release_part(meta, "file"), delimiter = "="),
            "--out-dir",
            out.as_output(),
        ),
        category = "conda_set",
        identifier = ctx.label.name,
    )
    return [DefaultInfo(
        default_output = out,
        sub_targets = {"manifest": [DefaultInfo(default_output = out.project("release_set.json"))]},
    )]

_conda_release_set = rule(
    impl = _conda_release_set_impl,
    attrs = {
        "members": attrs.list(attrs.dep()),
        "meta": attrs.dep(),
        "names": attrs.source(default = "komira//packaging/conda:names.tsv"),
        "names_custom": attrs.bool(default = False),
        "_meta_name": attrs.source(default = "komira//packaging/conda:METAPACKAGE"),
        "_pack": attrs.exec_dep(default = "komira//tools/build/package:komira_pack", providers = [RunInfo]),
    },
)

def conda_release(entries, names = None, cell = "komira"):
    """Every package of the approved list, the metapackage and the release set.

    Args:
      entries: name -> library label (`//src/<name>:<name>`), the generated
        `APPROVED` of names.bzl. Each becomes a `conda_package` named for it.
      names: another approved list. Only the tests cell may state one.
      cell: the cell the labels in `entries` are relative to.

    A package's summary is derived from its name; the channel page text is not
    part of the approval.
    """
    if not entries:
        fail("conda_release: entries is empty, so it would publish nothing")
    custom = names != None
    for name, label in entries.items():
        extra = {"names": names} if custom else {}
        conda_package(
            name = name,
            lib = cell + label,
            summary = "The `{}` Mojo library of komira, as a conda package.".format(name),
            **extra
        )
    members = [":" + n for n in entries.keys()]
    common = {"names_custom": custom}
    if custom:
        common["names"] = names
    else:
        common["names_lint"] = "komira//packaging/conda:names_lint"
    _conda_metapackage(
        name = "metapackage",
        commit = read_config("komira", "package_commit", ""),
        members = members,
        stamp = read_config("komira", "package_stamp", "0"),
        subdir = select({
            "komira//tools/build/platforms:is_linux_x86_64": "linux-64",
            "DEFAULT": "unsupported",
        }),
        timestamp_ms = read_config("komira", "package_timestamp_ms", "0"),
        exec_compatible_with = LINUX_X86_64,
        **common
    )
    _conda_release_set(
        name = "release_set",
        members = members,
        meta = ":metapackage",
        names_custom = custom,
        exec_compatible_with = LINUX_X86_64,
        **({"names": names} if custom else {})
    )

conda_release = declares_docs(conda_release)
