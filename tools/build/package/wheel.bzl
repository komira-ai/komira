"""The Python package's wheel (`komira_wheel`, pack/komira_wheel.zig).

`wheel_package` writes one wheel of an import package: its files (`srcs`), the
library it loads with the native owners beside it (`native`, a
`mojo_shared_lib`'s `[runnable]` directory, copied to `<import_name>/_lib/`),
the licence files the pyproject's `license-files` names, and METADATA made from
the pyproject's `[project]` (docs/design/python_package.md, decision 7).

What the rule fixes, so no BUCK file states it:

    VERSION   `<compiler version>.post<N>` (packaging/conda/README.md, "Wheels:
              versioning"): MOJO_COMPILER_VERSION of conda.bzl and the build
              number N of `-c komira.package_stamp=<N>` (0, the default, is an
              unstamped development output). The source commit of the stamp is
              `-c komira.package_commit=<sha>`; a release requires both.
    TAG       `py3-none-manylinux_<glibc floor>_x86_64`: the package loads its
              library with ctypes (no CPython ABI), and the floor is the platform
              table's, the one every shared library is held to
              (native/shared.bzl `linux_glibc_floor`).
    RUNTIME   the Mojo runtime is not in the wheel: every library of the
              platform row's `runtime_libs` is left out of the native directory,
              the check refuses a wheel that carries one, and METADATA requires
              `mojo-compiler==<compiler version>`, Modular's package that holds
              them (NOTICE, last section).

Sub-targets:

    [default]        the directory: the wheel, METADATA and manifest.json (the
                     release's PYTHON artifact manifest), copied only after
                     [check] passed. A development output: an unstamped one is
                     version `<compiler version>.post0`.
    [whl], [manifest], [metadata]
                     its three files.
    [check]          the marker of `komira_wheel check`: the directory read back
                     (pack/wheel_check.zig), and the wheel equal byte for byte to
                     [twin].
    [twin]           the same wheel built again by a second action, from the
                     same inputs staged at other paths.
    [release]        the directory, copied only after [release_check] passed;
                     `[release][whl]`, `[release][manifest]`,
                     `[release][metadata]`. An uploader reads this and nothing
                     else.
    [release_check]  [check] with `--require-stamped true`: a positive stamp
                     with a source commit of 40 lowercase hex digits.
"""

load("@komira//tools/build/bench_salt:bench_salt.bzl", "salted")
load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/native:shared.bzl", "linux_glibc_floor")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/platforms:table.bzl", "row")
load(":conda.bzl", "MOJO_COMPILER_VERSION", "TEST_COMMIT", "TEST_STAMP")

def wheel_tag(platform):
    """The tag of a wheel built for `platform`, a release platform's name."""
    if platform == "linux-x86_64":
        return "py3-none-manylinux_{}_x86_64".format(linux_glibc_floor().replace(".", "_"))

    # komira-limit:mojo-toolchain-x86-64 (libkomira is linked for linux-x86_64 only)
    fail("no wheel is built for the target platform `{}`: libkomira is linked for linux-x86_64 only".format(platform))

def wheel_version(stamp):
    """The version a wheel stamped with build number `stamp` carries."""
    return "{}.post{}".format(MOJO_COMPILER_VERSION, stamp)

def _flags(ctx, pyproject, readme, licenses, tag):
    return [
        "--name",
        ctx.attrs.distribution,
        "--pyproject",
        pyproject,
        "--readme",
        cmd_args(readme, format = ctx.attrs.readme.basename + "={}"),
        "--version-base",
        MOJO_COMPILER_VERSION,
        "--stamp",
        ctx.attrs.stamp,
        "--tag",
        tag,
        "--platform",
        ctx.attrs.platform,
        "--runtime-requires",
        "mojo-compiler=={}".format(MOJO_COMPILER_VERSION),
        "--import-name",
        ctx.attrs.import_name,
        "--native-lib",
        ctx.attrs.native_lib,
        [["--native-drop", n] for n in row("linux-x86_64")["runtime_libs"]],
        [cmd_args("--license-file", cmd_args(f, format = name + "={}")) for name, f in licenses],
    ]

def _wheel_package_impl(ctx):
    tag = wheel_tag(ctx.attrs.platform)
    tool = ctx.attrs._wheel[RunInfo]
    native = ctx.attrs.native[DefaultInfo].default_outputs
    if len(native) != 1:
        fail("{}: native {} has {} outputs, not one directory (a mojo_shared_lib's [runnable])".format(ctx.label, ctx.attrs.native.label, len(native)))
    native = native[0]
    licenses = sorted(ctx.attrs.license_files.items())
    name = "{}-{}-{}.whl".format(ctx.attrs.distribution.replace("-", "_"), wheel_version(ctx.attrs.stamp), tag)

    def build(where):
        # The inputs of one build, staged under `where`: the twin's are staged
        # at another depth, so a wheel that recorded a path would differ.
        pkg = ctx.actions.copied_dir(where + "/pkg", ctx.attrs.srcs)
        staged = ctx.actions.copied_dir(where + "/in", {
            "native": native,
            "pyproject.toml": ctx.attrs.pyproject,
            "readme": ctx.attrs.readme,
        } | {"licenses/" + n: f for n, f in licenses})
        out = ctx.actions.declare_output(where + "/out", dir = True)
        ctx.actions.run(
            cmd_args(
                tool,
                "wheel",
                _flags(
                    ctx,
                    staged.project("pyproject.toml"),
                    staged.project("readme"),
                    [(n, staged.project("licenses/" + n)) for n, _ in licenses],
                    tag,
                ),
                "--package-dir",
                pkg,
                "--native-dir",
                staged.project("native"),
                "--out-dir",
                out.as_output(),
            ),
            env = salted(),
            category = "wheel_pack",
            identifier = where,
        )
        return out

    raw = build("a")
    twin = build("twin/b/c")

    def check(marker, stamped):
        out = ctx.actions.declare_output(marker)
        ctx.actions.run(
            cmd_args(
                tool,
                "check",
                _flags(ctx, ctx.attrs.pyproject, ctx.attrs.readme, licenses, tag),
                "--dir",
                raw,
                "--twin-dir",
                twin,
                "--commit",
                ctx.attrs.commit,
                "--require-stamped",
                "true" if stamped else "false",
                "--out",
                out.as_output(),
            ),
            env = salted(),
            category = "wheel_check",
            identifier = marker,
        )
        return out

    checked = check(ctx.label.name + ".checked", False)
    release_checked = check(ctx.label.name + ".release_checked", True)

    def copy(dst_name, category, gate):
        # A copy made after the check passed, so the directory does not exist
        # unless it did (conda.bzl's joins).
        dst = ctx.actions.declare_output(dst_name, dir = True)
        ctx.actions.run(
            cmd_args(ctx.attrs._pkg_act[RunInfo], "copy-dir", raw, dst.as_output(), hidden = [gate]),
            env = salted(),
            category = category,
            identifier = ctx.label.name,
        )
        return dst

    out = copy("out", "wheel_join", checked)
    rel = copy("release", "wheel_release_join", release_checked)

    def files(d):
        return {
            "manifest": [DefaultInfo(default_output = d.project("manifest.json"))],
            "metadata": [DefaultInfo(default_output = d.project("METADATA"))],
            "whl": [DefaultInfo(default_output = d.project(name))],
        }

    return [DefaultInfo(
        default_output = out,
        sub_targets = files(out) | {
            "check": [DefaultInfo(default_output = checked)],
            "release": [DefaultInfo(default_output = rel, sub_targets = files(rel))],
            "release_check": [DefaultInfo(default_output = release_checked)],
            "twin": [DefaultInfo(default_output = twin.project(name))],
        },
    )]

_wheel_package = rule(
    impl = _wheel_package_impl,
    attrs = {
        # The source commit of the stamp (-c komira.package_commit), "" if none.
        "commit": attrs.string(default = ""),
        # The distribution's name; the pyproject's `name` must be the same
        # (komira_wheel refuses another). Stated here to name the wheel's file.
        "distribution": attrs.string(),
        "import_name": attrs.string(),
        # The licence files, by their name in the pyproject's `license-files`.
        "license_files": attrs.dict(attrs.string(), attrs.source(), default = {
            "LICENSE": "komira//:LICENSE",
            "NOTICE": "komira//:NOTICE",
        }),
        # A mojo_shared_lib's [runnable] directory: the library and lib/.
        "native": attrs.dep(),
        "native_lib": attrs.string(default = "libkomira.so"),
        # The release platform, from the target platform (the macro's select).
        "platform": attrs.string(),
        "pyproject": attrs.source(),
        "readme": attrs.source(),
        # The import package's files, by their path in the wheel.
        "srcs": attrs.dict(attrs.string(), attrs.source()),
        "stamp": attrs.string(),
        "_pkg_act": attrs.exec_dep(default = "komira//tools/build/package:pkg_act", providers = [RunInfo]),
        "_wheel": attrs.exec_dep(default = "komira//tools/build/package:komira_wheel", providers = [RunInfo]),
    },
)

def _with_stamp(commit, stamp, **kwargs):
    _wheel_package(
        commit = commit,
        stamp = stamp,
        platform = select({
            "komira//tools/build/package:is_linux_x86_64": "linux-x86_64",
            "DEFAULT": "unsupported",
        }),
        exec_compatible_with = LINUX_X86_64,
        **kwargs
    )

def _wheel_package_macro(**kwargs):
    # The stamp is read here, in the macro, so it keys only the wheel.
    _with_stamp(
        commit = read_config("komira", "package_commit", ""),
        stamp = read_config("komira", "package_stamp", "0"),
        **kwargs
    )

def _wheel_package_test_stamped_macro(**kwargs):
    # conda.bzl's TEST stamp, so a build without `-c komira.package_stamp` has
    # a stamped [release] to check. No release carries it.
    _with_stamp(commit = TEST_COMMIT, stamp = TEST_STAMP, **kwargs)

wheel_package = declares_docs(_wheel_package_macro)
wheel_package_test_stamped = declares_docs(_wheel_package_test_stamped_macro)
