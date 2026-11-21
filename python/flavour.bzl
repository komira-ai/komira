"""The two flavours of the wheel `komira` (python/BUCK;
docs/design/python_package.md, "The two flavours"): `komira_wheel`,
`runtime_record` and what each flavour holds.

The flavours are one package built from the same sources, with the same
name, version, tag and Python files. They differ only in where the Mojo
runtime libraries libkomira needs come from:

    bundled   the wheel carries them, unmodified, in `komira/_lib/lib/` beside
              komira's own native owners (`//src/so:libkomira[dist]` copied
              whole), with the licence texts of the package they come from;
              it requires no other distribution, and its License-Expression
              is `Apache-2.0 AND LicenseRef-Modular-Proprietary`.
    external  the wheel carries none of them and no other file of Modular's:
              libkomira and its owners picked from the same directory, and
              the record of the runtime's build ids (`runtime_record`) at
              `komira/_lib/mojo_runtime.tsv`. It requires Modular's
              `mojo-compiler` at the pinned compiler's version, which installs
              the runtime in `<site-packages>/modular/lib/`; its
              License-Expression is `Apache-2.0` and its licence files are
              LICENSE and NOTICE.

The loader (komira/_runtime.py) uses the runtime inside the package when it
is there and finds Modular's installed one otherwise. The wheel's description
starts with a paragraph that names its flavour (`PREFACE`).

`komira_wheel(name, flavour, platform, dist_files, record, stamp, **kwargs)` is
`wheel_file` with the attributes of `flavour` added to `kwargs`: `dist_files`
is the `picked_files` target of the `[dist]` directory (libkomira, its owners
and the runtime, by file name) and `record` the `runtime_record` target. With
`stamp` (a build number) it is `wheel_file_at_stamp` instead, for the wheels of
an upgrade test. Another flavour fails analysis.

`runtime_record(name, libraries, requirement)` writes `<name>.tsv`, the
record of the libraries' GNU build ids and the requirement that installs them
(`komira_wheel runtime-record`, tools/build/package/wheel/record.zig).
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/package:wheel.bzl", "wheel_file", "wheel_file_at_stamp")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/platforms:table.bzl", "asset")

FLAVOURS = ["bundled", "external"]

# The Mojo runtime libraries, as libkomira's NEEDED entries and their own name
# them: libkomira needs the first, which needs the other two (the order of
# komira/_runtime.py's RUNTIME_LIBRARIES, and of the record).
RUNTIME = [
    "libKGENCompilerRTShared.so",
    "libAsyncRTRuntimeGlobals.so",
    "libMSupportGlobals.so",
]

# The native owners of //src/so:libkomira (src/so/BUCK, NATIVE_OWNERS; their
# file names are the table of src/so/README.md). The external wheel picks
# them one by one: one left out fails the wheel rule's `needed` check.
OWNERS = [
    "libkomira_async_api_native.so.1",
    "libkomira_async_rt_native.so.1",
    "libkomira_compression_native.so.1",
    "libkomira_fs_native.so.1",
    "libkomira_libc_native.so.1",
    "libkomira_metrics_native.so.1",
    "libkomira_parquet_codec_native.so.1",
    "libkomira_scan_source_native.so.1",
]

# libkomira, its owners and the Mojo runtime, as the wheel lays them out.
DIST = "komira//src/so:libkomira[dist]"

# Where the external wheel carries the record of the runtime it loads.
RECORD_PATH = "komira/_lib/mojo_runtime.tsv"

# komira's own licence files, and the licence texts of the pinned Mojo
# compiler package the bundled runtime libraries come from, unmodified
# (third_party/modular/BUCK).
OWN_LICENSE_FILES = {
    "LICENSE": "komira//:LICENSE",
    "NOTICE": "komira//:NOTICE",
}

MODULAR_LICENSE_FILES = {
    "MODULAR_LICENSE": "komira//third_party/modular:mojo_compiler_licenses[info/licenses/LICENSE]",
    "MODULAR_THIRD_PARTY_NOTICES": "komira//third_party/modular:mojo_compiler_licenses[info/licenses/Third-Party-Notices]",
}

# komira's own files are Apache-2.0; the bundled Mojo runtime libraries are
# Modular's, under the licence their package declares
# (`LicenseRef-Modular-Proprietary`, the Modular Community License Terms in
# MODULAR_LICENSE).
LICENSE_EXPRESSIONS = {
    "bundled": "Apache-2.0 AND LicenseRef-Modular-Proprietary",
    "external": "Apache-2.0",
}

def mojo_version(platform):
    """The Mojo of the toolchain on `platform`: the version of its conda pin
    (`mojo_compiler_<version>_<subdir>.conda`)."""
    return asset(platform, "mojo_compiler")["name"].split("_")[2]

def requirement(platform):
    """The external wheel's one requirement: Modular's package at the
    version of the compiler that built libkomira."""
    return "mojo-compiler==" + mojo_version(platform)

# The first paragraph of each flavour's description.
PREFACE = {
    "bundled": "> This wheel is the **bundled** flavour of komira: it carries the Mojo runtime libraries libkomira needs, Modular's files under Modular's licence, and requires no other package (see \"The two flavours\" below).",
    "external": "> This wheel is the **external** flavour of komira: it carries no file of Modular's, and requires Modular's `mojo-compiler` package, which installs the Mojo runtime libkomira loads (see \"The two flavours\" below).",
}

def flavour_attrs(flavour, platform, dist_files, record):
    """The `wheel_file` attributes `flavour` sets: the native files and which
    of them are executable, the requirement, the licence files and
    expression, the runtime sonames another package provides, and the
    description's preface."""
    if flavour == "bundled":
        native = {"komira/_lib": DIST}
        return {
            "executable": sorted(native.keys()),
            "files": native,
            "license_expression": LICENSE_EXPRESSIONS[flavour],
            "license_files": OWN_LICENSE_FILES | MODULAR_LICENSE_FILES,
            "readme_preface": PREFACE[flavour],
        }
    if flavour == "external":
        libs = {"komira/_lib/libkomira.so": dist_files + "[libkomira.so]"} | {
            "komira/_lib/lib/" + o: dist_files + "[" + o + "]"
            for o in OWNERS
        }
        return {
            "executable": sorted(libs.keys()),
            "external_needed": sorted(RUNTIME),
            "files": libs | {RECORD_PATH: record},
            "license_expression": LICENSE_EXPRESSIONS[flavour],
            "license_files": OWN_LICENSE_FILES,
            "readme_preface": PREFACE[flavour],
            "requires_dist": [requirement(platform)],
        }
    fail("flavour `{}` is not one of {}".format(flavour, ", ".join(FLAVOURS)))

def _komira_wheel_macro(name, flavour, platform, dist_files, record, files = {}, stamp = None, **kwargs):
    attrs = flavour_attrs(flavour, platform, dist_files, record)
    native = attrs.pop("files")
    if stamp != None:
        kwargs["stamp"] = stamp
    (wheel_file if stamp == None else wheel_file_at_stamp)(
        name = name,
        platform = platform,
        files = files | native,
        **(kwargs | attrs)
    )

def _runtime_record_impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name + ".tsv")
    cmd = cmd_args(ctx.attrs._wheel[RunInfo], "runtime-record", "--requirement", ctx.attrs.requirement)
    for lib in ctx.attrs.libraries:
        cmd.add("--library", lib)
    cmd.add("--out", out.as_output())
    ctx.actions.run(cmd, category = "runtime_record")
    return [DefaultInfo(default_output = out)]

_runtime_record = rule(
    impl = _runtime_record_impl,
    doc = "The record of `libraries`' GNU build ids and the `requirement` that installs them, `<name>.tsv` (`komira_wheel runtime-record`): what the external wheel's loader holds Modular's installed runtime to.",
    attrs = {
        "libraries": attrs.list(attrs.source()),
        "requirement": attrs.string(),
        "_wheel": attrs.exec_dep(default = "komira//tools/build/package:komira_wheel", providers = [RunInfo]),
    },
)

def _runtime_record_macro(**kwargs):
    _runtime_record(exec_compatible_with = LINUX_X86_64, **kwargs)

komira_wheel = declares_docs(_komira_wheel_macro)
runtime_record = declares_docs(_runtime_record_macro)
