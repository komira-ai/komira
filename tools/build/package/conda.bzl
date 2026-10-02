"""A Mojo library as a conda package (a `.conda`), for linux-64.

`load("@komira//tools/build/package:conda.bzl", "conda_package")`

    conda_package(
        name = "komira_json",            # the published name: the library's import name
        lib = "//src/komira_json:komira_json",
        summary = "One line for the channel page.",
    )

Everything about the package is derived, so nothing can disagree with the
library:

  * the name is the library's import name (the `.mojoc` basename), and must be
    in the approved list `packaging/conda/names.tsv` and carry the published
    prefix; the target's own name must be it;
  * the run requirements are the platform guard, the exact Mojo compiler pin,
    and each DIRECT dependency of the library at the same version (every
    package is lockstep, so the solver's closure is the build's); a dependency
    that is not itself approved is refused;
  * the subdir comes from the TARGET platform's constraints (a select), never an
    attribute: a package cannot say `osx-arm64` over a linux `.mojoc`;
  * the payload is the library's gated `.mojoc`, so the package cannot exist
    until the library's own welded tests pass; a library with no tests, or one
    that links native code, or one that opens a shared library by name at run
    time, is refused;
  * the version is `<prefix>.<N>`: the prefix is the one line of
    `packaging/conda/VERSION_PREFIX`; N is `-c komira.package_stamp=<N>` (0, the
    default, is an unstamped build that the release check refuses).
    `tools/build/package/release_version.sh` prints N and the timestamp.

Sub-targets (what a publisher reads):

    [default] [file]  <name>.conda
    [digest]          one line, `sha256:<hex>` of that file
    [manifest]        JSON, sorted keys: schema, artifact_type, name, version,
                      subdir, build, build_number, file_name (the channel's
                      file name), sha256, size, payload_path, payload_sha256,
                      depends, mojo_pin, stamped, label, approved_names_sha256
    [check]           the marker of `komira_pack conda-check`: the three above
                      are copies made after it passed
    [release_check]   the same check, also refusing an unstamped version

The bytes are reproducible: the sha256 is the package's identity. Nothing is
uploaded. Design and the reasons for each choice: packaging/conda/README.md.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoInfo")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

# Every published name starts with this (the upload seam compares it exactly).
PUBLISHED_NAME_PREFIX = "komira_"

# The Mojo compiler every package pins, exactly. tools/build/tests/functional/conda.sh
# requires it equal the version of the pinned compiler package in
# tools/build/toolchains/BUCK, so there is one statement of it.
MOJO_COMPILER_PIN = "1.0.0"

_LICENSE = "Apache-2.0"
_HOME = "https://github.com/komira-ai/komira"

def _subdir(ctx):
    # Set by the macro from the TARGET platform's constraints (a select), so no
    # BUCK file states it.
    if ctx.attrs.subdir == "linux-64":
        return "linux-64"
    fail("{}: the target platform is not linux x86_64. A `.mojoc` cannot be cross-compiled, so a package for another subdir is built by a build for that platform; only linux-64 is written so far".format(ctx.label))

def _conda_package_impl(ctx):
    lib = ctx.attrs.lib
    info = lib[MojoInfo]
    name = ctx.label.name
    if info.import_name != name:
        fail("{}: the published name is the library's import name `{}`; name this target `{}`".format(ctx.label, info.import_name, info.import_name))
    if info.c_link != None:
        fail("{}: {} links native code. A `.mojoc` holds none, so a consumer would fail at its own link; no conda package for it until native code is supported".format(ctx.label, lib.label))
    tests = lib[DefaultInfo].sub_targets.get("tests")
    if tests == None or not tests[DefaultInfo].default_outputs:
        fail("{}: {} has no tests, so its package would not be gated by any; declare test_srcs on the library".format(ctx.label, lib.label))
    payload = lib[DefaultInfo].default_outputs[0]
    sources = lib[DefaultInfo].sub_targets["src"][DefaultInfo].default_outputs[0]
    subdir = _subdir(ctx)

    pack = ctx.attrs._pack[RunInfo]
    names = ctx.attrs.names
    prefix = PUBLISHED_NAME_PREFIX
    stem = "raw/" + name
    raw = ctx.actions.declare_output(stem + ".conda")
    raw_manifest = ctx.actions.declare_output(stem + ".manifest.json")
    raw_digest = ctx.actions.declare_output(stem + ".digest")
    ctx.actions.run(
        cmd_args(
            pack,
            "conda",
            "--name",
            name,
            "--name-prefix",
            prefix,
            "--names",
            names,
            "--version-prefix",
            ctx.attrs._version_prefix,
            "--stamp",
            ctx.attrs.stamp,
            "--timestamp-ms",
            ctx.attrs.timestamp_ms,
            "--subdir",
            subdir,
            "--mojo-pin",
            MOJO_COMPILER_PIN,
            "--license",
            _LICENSE,
            "--summary",
            ctx.attrs.summary,
            "--home",
            _HOME,
            "--payload",
            payload,
            "--sources",
            sources,
            "--extra-file",
            cmd_args(ctx.attrs._license_file, format = "info/licenses/LICENSE={}"),
            "--label",
            str(ctx.label.raw_target()),
            [cmd_args("--dep", d) for d in info.direct],
            "--out",
            raw.as_output(),
            "--conda-manifest",
            raw_manifest.as_output(),
            "--digest",
            raw_digest.as_output(),
        ),
        category = "conda_pack",
        identifier = name,
    )

    def check(marker_name, extra):
        marker = ctx.actions.declare_output(marker_name)
        ctx.actions.run(
            cmd_args(
                pack,
                "conda-check",
                "--package",
                raw,
                "--conda-manifest",
                raw_manifest,
                "--payload",
                payload,
                "--expect-subdir",
                subdir,
                "--names",
                names,
                "--name-prefix",
                prefix,
                "--mojo-pin",
                MOJO_COMPILER_PIN,
                extra,
                "--out",
                marker.as_output(),
            ),
            category = "conda_check",
            identifier = marker_name,
        )
        return marker

    checked = check(name + ".checked", [])
    release_checked = check(name + ".release_checked", ["--require-stamped", "true"])

    # The published files are copies made after the check passed, so none of
    # them exists unless it did (the gate join of mojo_library, one level up).
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(name + ".conda")
    out_manifest = ctx.actions.declare_output(name + ".manifest.json")
    out_digest = ctx.actions.declare_output(name + ".digest")
    ctx.actions.run(
        cmd_args(
            bb,
            "sh",
            "-euc",
            '"$1" cp "$2" "$3"; "$1" cp "$4" "$5"; "$1" cp "$6" "$7"',
            "sh",
            bb,
            raw,
            out.as_output(),
            raw_manifest,
            out_manifest.as_output(),
            raw_digest,
            out_digest.as_output(),
            hidden = [checked],
        ),
        category = "conda_join",
        identifier = name,
    )
    return [DefaultInfo(
        default_output = out,
        sub_targets = {
            "check": [DefaultInfo(default_output = checked)],
            "digest": [DefaultInfo(default_output = out_digest)],
            "file": [DefaultInfo(default_output = out)],
            "manifest": [DefaultInfo(default_output = out_manifest)],
            "release_check": [DefaultInfo(default_output = release_checked)],
        },
    )]

_conda_package = rule(
    impl = _conda_package_impl,
    attrs = {
        "lib": attrs.dep(providers = [MojoInfo]),
        # The approved names. Only a test of the refusals names another list.
        "names": attrs.source(default = "komira//packaging/conda:names.tsv"),
        "stamp": attrs.string(),
        "subdir": attrs.string(),
        "summary": attrs.string(),
        "timestamp_ms": attrs.string(),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        "_license_file": attrs.source(default = "komira//:LICENSE"),
        "_pack": attrs.exec_dep(default = "komira//tools/build/package:komira_pack", providers = [RunInfo]),
        "_version_prefix": attrs.source(default = "komira//packaging/conda:VERSION_PREFIX"),
    },
)

def conda_package(**kwargs):
    """The `.conda` of a Mojo library; see the module documentation.

    N and the commit timestamp come from the configuration
    (`-c komira.package_stamp=57 -c komira.package_timestamp_ms=...`): they are
    read here, in the macro, so they key only the packages and never a
    compile.
    """
    _conda_package(
        stamp = read_config("komira", "package_stamp", "0"),
        subdir = select({
            "komira//tools/build/platforms:is_linux_x86_64": "linux-64",
            "DEFAULT": "unsupported",
        }),
        timestamp_ms = read_config("komira", "package_timestamp_ms", "0"),
        exec_compatible_with = LINUX_X86_64,
        **kwargs
    )

conda_package = declares_docs(conda_package)
