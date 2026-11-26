"""`npm_tarball`: an npm package tarball written by `komira_npm` (npm/main.zig).

The tarball `npm pack` would write of the given files and the package's
manifest, byte for byte reproducible, which the rule refuses to write when it
would be wrong for the platform it is for. No shell, no Python: one Zig action
writes the tarball, a second writes it again from inputs staged elsewhere, and
a third reads it back.

Attributes:

    package             the npm name (`@komira-ai/komira`); the manifest's
                        `name` must be it
    manifest            the source package.json, the development one checked
                        in with the package (`"version": "0.0.0"`,
                        `"private": true`, optional dependencies at 0.0.0).
                        The tarball's package.json is it stamped: the version
                        and every optional dependency become the stamp's
                        version, and a stamped package drops `private`.
                        Every other key keeps its value and place
    license             the manifest's `license` must be it
    files               {path in the package: file or directory}; a directory
                        adds each file under it at `<path>/<its path>`. Each
                        must be one npm packs for the manifest's `files`
                        list (or package.json, a README or a licence file at
                        the top). A native library (ELF or Mach-O) is written
                        0755, every other file 0644
    platform            the platform row the package is for (tools/build/
                        platforms/table.bzl); unset, the package holds no
                        native library and its manifest names no `os`, `cpu`
                        or `libc`. Set, the manifest's `os`, `cpu` and `libc`
                        must be the row's as npm spells them (linux-x86_64:
                        `linux`, `x64`, `glibc`), and every native member is
                        held to native_policy's policy.zig as a wheel's is
    os_floor            the glibc (or macOS) the native members may need, when
                        it is above the platform row's `os_floor`
    max_glibcxx, max_cxxabi
                        the highest GLIBCXX_ and CXXABI_ versions a library
                        may need (unset: none may)

The manifest's `repository.url` must be https://github.com/komira-ai/komira,
which npm's trusted publishing requires. The version is the wheel's stamp
(wheel/stamp.zig): `0.1.<N>` with `-c komira.package_stamp=<N>`,
`-c komira.package_commit` and `-c komira.package_timestamp_ms`, `0.0.0` with
none, any other mix refused. The file name is npm pack's:
`<name without @, / as ->-<version>.tgz`.

Sub-targets:

    [default]        the tarball, copied only after [check] passed
    [check]          the marker of `komira_npm check`: the tarball read back
                     (npm/check.zig), and byte-equal to [twin]
    [twin]           the same tarball written by a second action, from the
                     same inputs staged at another path
    [release]        the tarball, copied only after [release_check] passed:
                     what a publisher reads, and nothing else
    [release_check]  [check] with a stamped package required
"""

load("@komira//tools/build/bench_salt:bench_salt.bzl", "salted")
load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/platforms:table.bzl", "row")
load(":conda.bzl", "TEST_COMMIT", "TEST_STAMP", "TEST_TIMESTAMP_MS")
load(":wheel.bzl", "brace_refusal", "wheel_version")

_NPM_OS = {"linux": "linux", "macos": "darwin"}
_NPM_CPU = {"arm64": "arm64", "x86_64": "x64"}
_ELF_ARCH = {"arm64": "aarch64", "x86_64": "x86_64"}

def npm_file_name(package, version):
    """The file name `npm pack` gives package `package` at `version`."""
    bare = package[1:] if package.startswith("@") else package
    return "{}-{}.tgz".format(bare.replace("/", "-"), version)

def npm_platform_flags(r):
    """The flags of `komira_npm` for platform row `r` (a dict with `name`,
    `os`, `cpu` and `os_floor`): the manifest's `os`, `cpu` and `libc` as npm
    spells them, and the floor and machine the native policy holds the
    members to."""
    floor = r["os_floor"].split("-", 1)
    if len(floor) != 2 or r["os"] not in _NPM_OS or r["cpu"] not in _NPM_CPU:
        fail("platform row {}: no npm platform for os {}, cpu {} and os_floor {}".format(r["name"], r["os"], r["cpu"], r["os_floor"]))
    out = ["--os", _NPM_OS[r["os"]], "--cpu", _NPM_CPU[r["cpu"]]]
    if r["os"] == "linux" and floor[0] == "glibc":
        return out + ["--libc", "glibc", "--glibc", floor[1], "--arch", _ELF_ARCH[r["cpu"]]]
    if r["os"] == "macos" and floor[0] == "macos":
        return out + ["--macos", floor[1]]
    fail("platform row {}: os {} does not take the os_floor {}".format(r["name"], r["os"], r["os_floor"]))

def _flags(ctx, manifest, files):
    out = [
        "--name",
        ctx.attrs.package,
        "--manifest",
        manifest,
        "--license",
        ctx.attrs.license,
        "--stamp",
        ctx.attrs.stamp,
        "--commit",
        ctx.attrs.commit,
        "--timestamp-ms",
        ctx.attrs.timestamp_ms,
    ]
    if ctx.attrs.platform != None:
        r = row(ctx.attrs.platform)
        if ctx.attrs.os_floor != None:
            r = r | {"os_floor": ctx.attrs.os_floor}
        out += npm_platform_flags(r)
    if ctx.attrs.max_glibcxx:
        out += ["--max-glibcxx", ctx.attrs.max_glibcxx]
    if ctx.attrs.max_cxxabi:
        out += ["--max-cxxabi", ctx.attrs.max_cxxabi]
    for path, f in files:
        out.append(cmd_args("--file", cmd_args(f, format = path + "={}")))
    return out

def _npm_tarball_impl(ctx):
    refusal = brace_refusal(str(ctx.label), list(ctx.attrs.files.keys()))
    if refusal:
        fail(refusal)
    if ctx.attrs.platform == None and (ctx.attrs.os_floor != None or ctx.attrs.max_glibcxx != None or ctx.attrs.max_cxxabi != None):
        fail("{}: os_floor, max_glibcxx and max_cxxabi bound native files, and a package with no platform holds none".format(ctx.label))
    tool = ctx.attrs._npm[RunInfo]
    name = npm_file_name(ctx.attrs.package, wheel_version(ctx.attrs.stamp))
    files = sorted(ctx.attrs.files.items())

    def write(where, manifest, files):
        out = ctx.actions.declare_output(where, dir = True)
        ctx.actions.run(
            cmd_args(tool, "write", _flags(ctx, manifest, files), "--out", cmd_args(out.as_output(), format = "{}/" + name)),
            env = salted(),
            category = "npm_write",
            identifier = where,
        )
        return out

    raw = write("a", ctx.attrs.manifest, files)

    # The twin's inputs are copies under another directory, so a tarball that
    # recorded where its inputs were would differ from the first.
    staged = ctx.actions.copied_dir("twin/b/c/in", {"manifest": ctx.attrs.manifest} | {
        "f{}".format(i): f
        for i, (_, f) in enumerate(files)
    })
    twin = write(
        "twin/b/c/out",
        staged.project("manifest"),
        [(p, staged.project("f{}".format(i))) for i, (p, _) in enumerate(files)],
    )

    def check(marker, stamped):
        out = ctx.actions.declare_output(marker)
        ctx.actions.run(
            cmd_args(
                tool,
                "check",
                _flags(ctx, ctx.attrs.manifest, files),
                "--tarball",
                raw.project(name),
                "--twin",
                twin.project(name),
                "--require-stamped",
                "true" if stamped else "false",
                "--out",
                out.as_output(),
            ),
            env = salted(),
            category = "npm_check",
            identifier = marker,
        )
        return out

    checked = check(ctx.label.name + ".checked", False)
    release_checked = check(ctx.label.name + ".release_checked", True)

    def gated_copy(where, gate):
        # A copy made after the check passed, so it does not exist unless it
        # did (as the wheel's).
        out = ctx.actions.declare_output(where, dir = True)
        ctx.actions.run(
            cmd_args(ctx.attrs._pkg_act[RunInfo], "copy-dir", raw, out.as_output(), hidden = [gate]),
            env = salted(),
            category = "npm_join",
            identifier = where,
        )
        return out.project(name)

    tgz = gated_copy("out", checked)
    rel = gated_copy("release", release_checked)
    return [DefaultInfo(
        default_output = tgz,
        other_outputs = [rel] if ctx.attrs.check_release else [],
        sub_targets = {
            "check": [DefaultInfo(default_output = checked)],
            "release": [DefaultInfo(default_output = rel)],
            "release_check": [DefaultInfo(default_output = release_checked)],
            "twin": [DefaultInfo(default_output = twin.project(name))],
        },
    )]

_npm_tarball = rule(
    impl = _npm_tarball_impl,
    attrs = {
        # Set by npm_tarball_test_stamped: the default output waits for
        # [release] too, so building the target runs the release check.
        "check_release": attrs.bool(default = False),
        # The stamp (-c komira.package_*), set by the macros.
        "commit": attrs.string(),
        "files": attrs.dict(attrs.string(), attrs.source()),
        "license": attrs.string(),
        "manifest": attrs.source(),
        "max_cxxabi": attrs.option(attrs.string(), default = None),
        "max_glibcxx": attrs.option(attrs.string(), default = None),
        "os_floor": attrs.option(attrs.string(), default = None),
        "package": attrs.string(),
        "platform": attrs.option(attrs.string(), default = None),
        "stamp": attrs.string(),
        "timestamp_ms": attrs.string(),
        "_npm": attrs.exec_dep(default = "komira//tools/build/package:komira_npm", providers = [RunInfo]),
        "_pkg_act": attrs.exec_dep(default = "komira//tools/build/package:pkg_act", providers = [RunInfo]),
    },
)

def _npm_tarball_macro(**kwargs):
    # The stamp is read here, in the macro, so it keys only the tarball; the
    # tool refuses any mix but all three or none.
    _npm_tarball(
        stamp = read_config("komira", "package_stamp", "0"),
        commit = read_config("komira", "package_commit", ""),
        timestamp_ms = read_config("komira", "package_timestamp_ms", "0"),
        exec_compatible_with = LINUX_X86_64,
        **kwargs
    )

def _npm_tarball_test_stamped_macro(**kwargs):
    # conda.bzl's TEST stamp, so a build without -c komira.package_* has a
    # stamped package whose [release] it checks. No release carries it.
    _npm_tarball(
        stamp = TEST_STAMP,
        commit = TEST_COMMIT,
        timestamp_ms = TEST_TIMESTAMP_MS,
        check_release = True,
        exec_compatible_with = LINUX_X86_64,
        **kwargs
    )

npm_tarball = declares_docs(_npm_tarball_macro)
npm_tarball_test_stamped = declares_docs(_npm_tarball_test_stamped_macro)

def _npm_platform_cases_impl(ctx):
    # Each row's flags and a file name, against what `cases` writes out.
    for name, want in ctx.attrs.cases.items():
        got = " ".join(npm_platform_flags(row(name)))
        if got != want:
            fail("{}: npm_platform_flags of row {} is `{}`, not `{}`".format(ctx.label, name, got, want))
    for package, want in ctx.attrs.file_names.items():
        got = npm_file_name(package, "0.1.7")
        if got != want:
            fail("{}: npm_file_name of {} at 0.1.7 is {}, not {}".format(ctx.label, package, got, want))
    out = ctx.actions.write(ctx.label.name + ".ok", "ok\n")
    return [DefaultInfo(default_output = out)]

_npm_platform_cases = rule(
    impl = _npm_platform_cases_impl,
    doc = "Holds `npm_platform_flags` of each platform row in `cases` (row name: the flags joined by spaces) and `npm_file_name` of each package in `file_names` at version 0.1.7 (package: file name) to what is written out; analysis fails on the first that differs.",
    attrs = {
        "cases": attrs.dict(attrs.string(), attrs.string()),
        "file_names": attrs.dict(attrs.string(), attrs.string(), default = {}),
    },
)

npm_platform_cases = declares_docs(_npm_platform_cases)
