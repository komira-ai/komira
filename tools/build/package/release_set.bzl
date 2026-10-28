"""The stamped release path, built by any build that includes a
conda_release_set_check target (`buck2 build //...`, and the per-change
check's unit that holds it): a release set's libraries packaged with a fixed
TEST stamp, their `[release]` manifests given to `komira_pack conda-meta`, and
the metapackage read back.

A release builds `<lib>_conda[release]` with the stamp kci derives from git
(`-c komira.package_stamp=<N> ...`) and then runs `komira_pack conda-meta` over
those manifests (release/artifacts.textproto). A build without that `-c` has no
stamped `[release]`, so neither step runs before a release does. This rule runs
both, with a stamp that no release carries:

    load("@komira//tools/build/package:release_set.bzl", "conda_release_set_check")

    conda_release_set_check(
        name = "release_set_check",
        metapackage = "komira_all",
        libs = ["//src/komira_encoding:komira_encoding"],
        release_set = "release_set.txt",
    )

For each library it declares `<name>_<lib>_conda` with
conda_package_test_stamped (conda.bzl: the same rule as `<lib>_conda`, with
build number `TEST_STAMP`, source commit `TEST_COMMIT` and commit time
`TEST_TIMESTAMP_MS` given instead of read from the configuration). A library
whose mojo_library declares `native` is given it through `native`, a dict
from the library's label in `libs` to that same `native` target, as the
mojo_library macro gives it to `<lib>_conda`: the package rule refuses a
library declaring `native` whose package is not given it (and one given
another library's), so a native library missing from the dict is red; a key
not in `libs` is refused here. Then, as build actions:

  * `komira_pack conda-meta --name <metapackage>` over each member's
    `[release]/manifest.json`. Its `--license`, `--summary` and `--home` are
    copied from release/artifacts.textproto's metapackage into this file and
    conda.bzl; the stamp check holds them equal to `release_set`, and
    src/kci_artifact's welded test holds `release_set` equal to the textproto.
    Its `--label` is this target's, not a release's;
  * a stamp check, naming what it fails on:
      - `release_set` names `metapackage` and, in order, the conda names of
        `libs` as its members, and the conda-meta arguments above;
      - every member's `[release]` directory and the metapackage's hold
        `<name>-<version>-TEST_BUILD.conda`, the manifest names that file and
        the version (the pinned compiler's);
      - the top level of each metadata.json (the metapackage's `members` rows
        removed first) carries `build` TEST_BUILD, `build_number` TEST_STAMP,
        `source_commit` TEST_COMMIT, `stamped` true and `timestamp_ms`
        TEST_TIMESTAMP_MS. TEST_BUILD is a literal (conda.bzl), not derived
        from TEST_COMMIT here;
      - the metapackage's metadata.json requires each member by name at that
        version and build string (conda-check checks the same requirements,
        but reports a missing one as a count, not by name);
  * a release order check: no member's metadata.json `depends` holds
    `"<name> ==<version> TEST_BUILD"` for a member `release_set` lists after
    it (a requirement at another version or build string is not one of this
    set's). The target's
    `order_tests` (release_order_test: this check over fixture
    metadata.json files) must pass first;
  * a README check: the README examples tool's `release-check`
    (tools/build/readme_examples, cli.zig) over each member's packaged
    README (its package's `[readme]`), refusing a member that packages no
    README or whose README holds no example (a ```mojo or ```mojo module
    fence, read as `generate --links refuse` reads it). kci's install
    validation (src/kci_validate, readme_installed.mojo) refuses both, but
    only after the release is published; the refusal names the member and
    quotes kci's words. The display of a member's README is
    `<package dir>/README.md`, as kci names it. The target's `readme_tests`
    (release_readme_test: this check over fixture READMEs) must pass first;
  * after the stamp check, `komira_pack conda-check --kind metapackage
    --require-stamped true` over the metapackage, with every member's manifest and the compiler pin: the
    `members` rows, the requirements, and that index, metadata and members
    agree.

The default output is the metapackage's directory (its `.conda`, manifest.json
and metadata.json), copied only after the four checks passed. Nothing is uploaded,
and no action uses the network.

A member's `[release]` exists only after its own `[release_check]` passed, so
that check runs too. What this does NOT cover: the macro conda_package's reading
of `-c komira.package_*` (these packages are given the test stamp); that a
member's requirement on another member is at the set's version and build string
(komira_pack writes it so; the order check reads only requirements that are);
and agreement across members beyond the stamp.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoInfo")
load(
    "@komira//tools/build/package:conda.bzl",
    "MOJO_COMPILER_VERSION",
    "PACKAGE_HOME",
    "PACKAGE_LICENSE",
    "TEST_BUILD",
    "TEST_COMMIT",
    "TEST_STAMP",
    "TEST_TIMESTAMP_MS",
    "conda_package_test_stamped",
)
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/rerun:rerun.bzl", "RERUN_ATTRS", "rerun_env", "rerun_info")

# Copied from release/artifacts.textproto's metapackage `--summary`; the stamp
# check holds it equal to release_set.txt's.
_SUMMARY = "Every komira library of one release."

# The stamp check (`pkg_act release-stamp-check`, tools/build/package/act/
# release.zig) compares the release set file with what this target was given,
# then every member's package and the metapackage with the test stamp.
#
# Release order (the module documentation): no member requires a member listed
# after it. A release builds the members in this order, each after the members
# it requires. `pkg_act release-order-check` reads the release set file's name
# (in the message only), the version, the build string, then `<name>
# <metadata.json>` per member in order. A requirement is `"<name> ==<V> <B>"`
# in metadata.json's `depends` (komira_pack). release_order_test runs the check
# over fixtures.

def _impl(ctx):
    if len(ctx.attrs.libs) != len(ctx.attrs.packages) or not ctx.attrs.libs:
        fail("{}: libs and packages are one list of members (the macro writes both), and not empty".format(ctx.label))
    pack = ctx.attrs._pack[RunInfo]
    tool = ctx.attrs._pkg_act[RunInfo]
    meta = ctx.attrs.metapackage
    members = []
    for lib, pkg in zip(ctx.attrs.libs, ctx.attrs.packages):
        name = lib[MojoInfo].conda_name
        if name == None:
            fail("{}: {} has no conda package".format(ctx.label, lib.label))
        members.append((name, pkg[DefaultInfo].sub_targets["release"][DefaultInfo].default_outputs[0]))
    manifests = [cmd_args("--member-manifest", cmd_args(d, format = "{}/manifest.json")) for _, d in members]

    raw = ctx.actions.declare_output("raw/" + meta, dir = True)
    ctx.actions.run(
        cmd_args(
            pack,
            "conda-meta",
            "--name",
            meta,
            manifests,
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
            "--out-dir",
            raw.as_output(),
        ),
        category = "conda_meta",
        identifier = meta,
    )

    stamp_ok = ctx.actions.declare_output(ctx.label.name + ".stamped")
    ctx.actions.run(
        cmd_args(
            tool,
            "release-stamp-check",
            "--out",
            stamp_ok.as_output(),
            "--version",
            MOJO_COMPILER_VERSION,
            "--build-number",
            TEST_STAMP,
            "--commit",
            TEST_COMMIT,
            "--timestamp-ms",
            TEST_TIMESTAMP_MS,
            "--build",
            TEST_BUILD,
            "--meta",
            meta,
            "--meta-dir",
            raw,
            "--set",
            ctx.attrs.release_set,
            "--license",
            PACKAGE_LICENSE,
            "--summary",
            _SUMMARY,
            "--home",
            PACKAGE_HOME,
            [cmd_args("--member", n, d) for n, d in members],
        ),
        category = "conda_release_stamp_check",
        identifier = meta,
    )

    in_order = ctx.actions.declare_output(ctx.label.name + ".in_order")
    ctx.actions.run(
        cmd_args(
            tool,
            "release-order-check",
            "--out",
            in_order.as_output(),
            "--set",
            ctx.attrs.release_set,
            "--version",
            MOJO_COMPILER_VERSION,
            "--build",
            TEST_BUILD,
            [cmd_args("--member", n, cmd_args(d, format = "{}/metadata.json")) for n, d in members],
        ),
        category = "conda_release_order_check",
        identifier = meta,
    )

    readmes_ok = ctx.actions.declare_output(ctx.label.name + ".readmes")
    readme_args = []
    for lib, pkg, (name, _) in zip(ctx.attrs.libs, ctx.attrs.packages, members):
        display = lib.label.package + "/README.md"
        readme = pkg[DefaultInfo].sub_targets.get("readme")
        if readme == None:
            readme_args.append(cmd_args("--no-readme", name, display))
        else:
            readme_args.append(cmd_args("--member", name, display, readme[DefaultInfo].default_outputs[0]))
    ctx.actions.run(
        cmd_args(ctx.attrs._readme_tool[RunInfo], "release-check", "--out", readmes_ok.as_output(), readme_args),
        category = "conda_release_readme_check",
        identifier = meta,
    )

    checked = ctx.actions.declare_output(ctx.label.name + ".checked")
    ctx.actions.run(
        cmd_args(
            pack,
            "conda-check",
            "--dir",
            raw,
            "--kind",
            "metapackage",
            "--name",
            meta,
            "--expect-subdir",
            "linux-64",
            "--mojo-pin",
            MOJO_COMPILER_VERSION,
            "--require-stamped",
            "true",
            manifests,
            "--out",
            checked.as_output(),
            # After the stamp check: a member left out is reported by name
            # (conda-check reports a count of requirements).
            hidden = [stamp_ok],
        ),
        category = "conda_check",
        identifier = meta,
    )

    out = ctx.actions.declare_output(meta, dir = True)
    ctx.actions.run(
        cmd_args(tool, "copy-dir", raw, out.as_output(), hidden = [stamp_ok, in_order, readmes_ok, checked] + [t[DefaultInfo].default_outputs[0] for t in ctx.attrs.order_tests + ctx.attrs.readme_tests]),
        category = "conda_release_set_join",
        identifier = meta,
    )
    return [DefaultInfo(default_output = out)]

_conda_release_set_check = rule(
    impl = _impl,
    attrs = {
        "libs": attrs.list(attrs.dep(providers = [MojoInfo])),
        "metapackage": attrs.string(),
        "order_tests": attrs.list(attrs.dep(), default = []),
        "packages": attrs.list(attrs.dep()),
        "readme_tests": attrs.list(attrs.dep(), default = []),
        "release_set": attrs.source(),
        "_license_file": attrs.source(default = "komira//:LICENSE"),
        "_pkg_act": attrs.exec_dep(default = "komira//tools/build/package:pkg_act", providers = [RunInfo]),
        "_pack": attrs.exec_dep(default = "komira//tools/build/package:komira_pack", providers = [RunInfo]),
        "_readme_tool": attrs.exec_dep(default = "komira//tools/build/readme_examples:tool", providers = [RunInfo]),
    },
)

def _release_set_check(name, metapackage, libs, release_set, native = {}, **kwargs):
    """See the module documentation."""
    for lib in native:
        if lib not in libs:
            fail("{}: `native` names {}, which is not in `libs`".format(name, lib))
    packages = []
    for lib in libs:
        pkg = "{}_{}_conda".format(name, lib.split(":")[-1])
        conda_package_test_stamped(
            name = pkg,
            lib = lib,
            native = native.get(lib),
            summary = "{} with the test stamp of {}; a build-time check only.".format(lib, name),
        )
        packages.append(":" + pkg)
    _conda_release_set_check(
        name = name,
        metapackage = metapackage,
        libs = libs,
        packages = packages,
        release_set = release_set,
        exec_compatible_with = LINUX_X86_64,
        **kwargs
    )

conda_release_set_check = declares_docs(_release_set_check)

def _release_order_test_impl(ctx):
    if len(ctx.attrs.members) != len(ctx.attrs.metadata_files) or not ctx.attrs.members:
        fail("{}: members and metadata_files are one list, and not empty".format(ctx.label))
    out = ctx.actions.declare_output(ctx.label.name + ".ok")
    ctx.actions.run(
        cmd_args(
            ctx.attrs._pkg_act[RunInfo],
            "release-order-test",
            "--out",
            out.as_output(),
            "--refuses",
            ctx.attrs.refuses,
            "--set",
            "release_set",
            "--version",
            ctx.attrs.version,
            "--build",
            ctx.attrs.build,
            [cmd_args("--member", n, m) for n, m in zip(ctx.attrs.members, ctx.attrs.metadata_files)],
        ),
        env = rerun_env(ctx),
        category = "release_order_test",
    )
    return [DefaultInfo(default_output = out), rerun_info(ctx)]

_release_order_test = rule(
    impl = _release_order_test_impl,
    doc = "The release order check run over fixture metadata.json files (`metadata_files`, one per name in `members`, in order) at `version` and `build`: red unless it refuses with one line of stderr containing `refuses`, or, when `refuses` is empty, passes with no stderr.",
    attrs = {
        "build": attrs.string(),
        "members": attrs.list(attrs.string()),
        "metadata_files": attrs.list(attrs.source()),
        "refuses": attrs.string(default = ""),
        "version": attrs.string(),
        "_pkg_act": attrs.exec_dep(default = "komira//tools/build/package:pkg_act", providers = [RunInfo]),
    } | RERUN_ATTRS,
)

def _release_order_test_macro(**kwargs):
    _release_order_test(exec_compatible_with = LINUX_X86_64, **kwargs)

release_order_test = declares_docs(_release_order_test_macro)

def _release_readme_test_impl(ctx):
    if not ctx.attrs.members:
        fail("{}: members is empty".format(ctx.label))
    for name in ctx.attrs.readmes:
        if name not in ctx.attrs.members:
            fail("{}: readmes names {}, which is not in members".format(ctx.label, name))
    args = []
    for name in ctx.attrs.members:
        display = "src/{}/README.md".format(name)
        if name in ctx.attrs.readmes:
            args.append(cmd_args("--member", name, display, ctx.attrs.readmes[name]))
        else:
            args.append(cmd_args("--no-readme", name, display))
    out = ctx.actions.declare_output(ctx.label.name + ".ok")
    ctx.actions.run(
        cmd_args(
            ctx.attrs._readme_tool[RunInfo],
            "release-check",
            "--out",
            out.as_output(),
            ["--expect-refusal", ctx.attrs.refuses] if ctx.attrs.refuses else [],
            args,
        ),
        env = rerun_env(ctx),
        category = "release_readme_test",
    )
    return [DefaultInfo(default_output = out), rerun_info(ctx)]

_release_readme_test = rule(
    impl = _release_readme_test_impl,
    doc = "The README check of conda_release_set_check (the README examples tool's `release-check`) over fixture READMEs: each name in `members`, in order, with its README `readmes[name]`, or as a member that packages no README when `readmes` does not name it; its display is `src/<name>/README.md`. Red unless the check refuses with a refusal containing `refuses`, or, when `refuses` is empty, passes.",
    attrs = {
        "members": attrs.list(attrs.string()),
        "readmes": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "refuses": attrs.string(default = ""),
        "_readme_tool": attrs.exec_dep(default = "komira//tools/build/readme_examples:tool", providers = [RunInfo]),
    } | RERUN_ATTRS,
)

def _release_readme_test_macro(**kwargs):
    _release_readme_test(exec_compatible_with = LINUX_X86_64, **kwargs)

release_readme_test = declares_docs(_release_readme_test_macro)
