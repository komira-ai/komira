"""`wheel_file`: a Python wheel written by `komira_wheel` (wheel/main.zig).

A wheel of the given files and metadata, byte for byte reproducible, which
the rule refuses to write when it would be wrong for the platform it is
tagged for (native_policy/policy.zig). No shell, no Python: one Zig action writes the
wheel, a second writes it again from inputs staged elsewhere, and a third
reads it back.

Attributes:

    distribution        the name (`pip install <it>`), in normalised form
    summary, readme     METADATA's Summary, and its body (Markdown:
                        Description-Content-Type text/markdown)
    requires_python     Requires-Python
    requires_dist       Requires-Dist lines, in order
    classifiers         Classifier lines; a `License ::` one is refused beside
                        the licence expression (PEP 639)
    project_urls        {label: url}, Project-URL lines
    license_expression  License-Expression (an SPDX expression), and the
    license_files       licence files ({name: file}, default the root's
                        LICENSE and NOTICE) as License-File and
                        `.dist-info/licenses/<name>`
    files               {path in the wheel: file or directory}; a directory
                        adds each file under it at `<path>/<its path>`
    executable          paths of `files` written 0755 (shared libraries);
                        the rest are 0644
    platform            the platform row the wheel is for (tools/build/
                        platforms/table.bzl), default linux-x86_64; its tag
                        is `wheel_tag` of the row
    os_floor            the floor the tag promises, when it is above the
                        row's `os_floor` (the floor of what the repository
                        links): a wheel carrying a vendor's library that needs
                        a newer glibc names it (`glibc-2.35`); unset, the
                        row's. For a macOS wheel it is the macOS the tag
                        promises (`macos-11.0` is `macosx_11_0`), the most a
                        Mach-O member's minimum macOS may be
    max_glibcxx, max_cxxabi
                        the highest GLIBCXX_ and CXXABI_ versions a library
                        may need (unset: none may); they bound ELF libraries
                        only, a macOS wheel's Mach-O libraries have no such
                        versions and the attributes stay unset
    external_needed     sonames a library may need that another package
                        provides; none of them may be in the wheel. For a
                        macOS wheel, the file names of libraries a Mach-O
                        library may load as `@rpath/<file>` from another
                        package

The VERSION is the stamp's (wheel/stamp.zig): `-c komira.package_stamp=<N>`
with `-c komira.package_commit` and `-c komira.package_timestamp_ms` gives
`0.1.<N>`, dated with the commit time; none gives `0.0.0` dated 1980-01-01,
an unstamped development wheel; any other mix fails the build.

Sub-targets:

    [default]        the wheel, copied only after [check] passed
    [check]          the marker of `komira_wheel check`: the wheel read back
                     (wheel/check.zig), and byte-equal to [twin]
    [file_name]      one line, the wheel's file name
                     (`<dist>-<version>-<tag>.whl`), written at analysis: no
                     input of the wheel is built for it
    [twin]           the same wheel written by a second action, from the same
                     inputs staged at another path
    [release]        the wheel, copied only after [release_check] passed: what
                     a publisher reads, and nothing else
    [release_check]  [check] with a stamped wheel required

`wheel_libs_check(name, wheel, entry, runtime_libs, runtime_licenses,
runtime_dists, opened = [], expect_refusal = None, runtime = None)` reads a finished wheel
alone (`komira_wheel libs`, wheel/libs.zig) and refuses it unless the
libraries in it load from it as an install would load them: from the library
`entry` (a member path), for an ELF entry each DT_NEEDED a manylinux system
library, a library already loaded or a member its run path reaches, every run
path entry `$ORIGIN`-relative and inside the import package; for a Mach-O
entry each load command a macOS system library (under /usr/lib or
/System/Library), a library already loaded, or a member that `@rpath` (through
the loading library's own LC_RPATH entries) or `@loader_path` reaches, every
run path entry `@loader_path`-relative and inside the import package; each
of `opened` (member paths of libraries the package opens itself beside the
entry, such as the UDF runtime) a member under the same import package and of
the entry's format, its loads walked as the entry's are; every ELF and Mach-O member loaded by one of them; and each of `runtime_libs` (the Mojo runtime)
carried once with the bytes of the runtime's copy, its licence files
`runtime_licenses` in `.dist-info/licenses/` and named by METADATA, and no
Requires-Dist of a distribution in `runtime_dists`. The runtime is the
toolchain's (`toolchains//:mojo`), or the directory `runtime` names (a
`mojo_runtime`: a macOS wheel's check runs on Linux, and the darwin toolchain
executes on macOS). Beside the wheel it reads only those names and the
runtime libraries, nothing else the rule that wrote the wheel was given.
The output, `<name>.libs`, lists the libraries `entry` loads, in
load order, then those each of `opened` adds; with `expect_refusal`, it exists only if the wheel is refused with
exactly that line (and says `refused: <line>`). Building the target is running
the check.

`wheel_same_check(name, wheel, like, only_in_wheel, only_in_like)` reads two
finished wheels of one package for two platforms (`komira_wheel same`,
wheel/compare.zig), the macOS wheel and the Linux wheel of one build, and
refuses them unless every member but RECORD and WHEEL is in both with the same
bytes and mode, apart from `only_in_wheel` and `only_in_like`: each in its own
wheel alone, and each a native library (Mach-O or ELF), so no Python file can
differ. WHEEL may differ only in its Tag's platform part (the Python and ABI
tags are the same). The output, `<name>.same`, counts the members alike and
lists each wheel's own.
"""

load("@komira//tools/build/bench_salt:bench_salt.bzl", "salted")
load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoToolchainInfo")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/platforms:table.bzl", "row")
load(":conda.bzl", "TEST_COMMIT", "TEST_STAMP", "TEST_TIMESTAMP_MS")

_ARCH = {"arm64": "aarch64", "x86_64": "x86_64"}

def wheel_tag(r):
    """The tag of a wheel for platform row `r` (a dict with `name`, `os`,
    `cpu` and `os_floor`): manylinux at the row's glibc floor, or macosx at its
    macOS floor. A wheel holding a native library is never `any`."""
    floor = r["os_floor"].split("-", 1)
    parts = floor[1].split(".") if len(floor) == 2 else []
    if len(parts) != 2:
        fail("platform row {}: os_floor `{}` is not <name>-<major>.<minor>".format(r["name"], r["os_floor"]))
    if r["os"] == "linux" and floor[0] == "glibc" and r["cpu"] in _ARCH:
        return "py3-none-manylinux_{}_{}_{}".format(parts[0], parts[1], _ARCH[r["cpu"]])
    if r["os"] == "macos" and floor[0] == "macos" and r["cpu"] == "arm64":
        return "py3-none-macosx_{}_{}_arm64".format(parts[0], parts[1])
    fail("platform row {}: no wheel tag for os {}, cpu {} and os_floor {}".format(r["name"], r["os"], r["cpu"], r["os_floor"]))

def wheel_version(stamp):
    """The version a wheel of build number `stamp` (a string) carries."""
    return "0.0.0" if stamp in ("", "0") else "0.1.{}".format(stamp)

def brace_refusal(owner, paths):
    """The refusal of the first of `paths` (wheel member paths of target
    `owner`) that holds a brace, which the `{}` of a `cmd_args` format would
    misread; None when no path holds one."""
    for p in paths:
        if "{" in p or "}" in p:
            return "{}: the path {} holds a brace, which a command-line format would misread".format(owner, p)
    return None

def _flags(ctx, tag, files, readme, licenses):
    out = [
        "--name",
        ctx.attrs.distribution,
        "--summary",
        ctx.attrs.summary,
        "--readme",
        readme,
        "--requires-python",
        ctx.attrs.requires_python,
        "--license-expression",
        ctx.attrs.license_expression,
        "--tag",
        tag,
        "--stamp",
        ctx.attrs.stamp,
        "--commit",
        ctx.attrs.commit,
        "--timestamp-ms",
        ctx.attrs.timestamp_ms,
    ]
    out += [["--requires-dist", r] for r in ctx.attrs.requires_dist]
    out += [["--classifier", c] for c in ctx.attrs.classifiers]
    out += [["--project-url", "{}={}".format(k, v)] for k, v in sorted(ctx.attrs.project_urls.items())]
    out += [["--external-needed", n] for n in ctx.attrs.external_needed]
    if ctx.attrs.max_glibcxx:
        out += ["--max-glibcxx", ctx.attrs.max_glibcxx]
    if ctx.attrs.max_cxxabi:
        out += ["--max-cxxabi", ctx.attrs.max_cxxabi]
    out += [cmd_args("--license-file", cmd_args(f, format = name + "={}")) for name, f in licenses]
    for path, f in files:
        flag = "--exec-file" if path in ctx.attrs.executable else "--file"
        out.append(cmd_args(flag, cmd_args(f, format = path + "={}")))
    return out

def _wheel_file_impl(ctx):
    refusal = brace_refusal(str(ctx.label), list(ctx.attrs.files.keys()) + list(ctx.attrs.license_files.keys()))
    if refusal:
        fail(refusal)
    for p in ctx.attrs.executable:
        if p not in ctx.attrs.files:
            fail("{}: executable names {}, which is not a key of files".format(ctx.label, p))
    r = row(ctx.attrs.platform)
    if ctx.attrs.os_floor != None:
        r = r | {"os_floor": ctx.attrs.os_floor}
    tag = wheel_tag(r)
    tool = ctx.attrs._wheel[RunInfo]
    name = "{}-{}-{}.whl".format(ctx.attrs.distribution.replace("-", "_"), wheel_version(ctx.attrs.stamp), tag)
    files = sorted(ctx.attrs.files.items())
    licenses = sorted(ctx.attrs.license_files.items())

    def write(where, files, readme, licenses):
        out = ctx.actions.declare_output(where, dir = True)
        ctx.actions.run(
            cmd_args(tool, "write", _flags(ctx, tag, files, readme, licenses), "--out", cmd_args(out.as_output(), format = "{}/" + name)),
            env = salted(),
            category = "wheel_write",
            identifier = where,
        )
        return out

    raw = write("a", files, ctx.attrs.readme, licenses)

    # The twin's inputs are copies under another directory, so a wheel that
    # recorded where its inputs were would differ from the first.
    staged = ctx.actions.copied_dir("twin/b/c/in", {"readme": ctx.attrs.readme} | {
        "f{}".format(i): f
        for i, (_, f) in enumerate(files)
    } | {"l{}".format(i): f for i, (_, f) in enumerate(licenses)})
    twin = write(
        "twin/b/c/out",
        [(p, staged.project("f{}".format(i))) for i, (p, _) in enumerate(files)],
        staged.project("readme"),
        [(n, staged.project("l{}".format(i))) for i, (n, _) in enumerate(licenses)],
    )

    def check(marker, stamped):
        out = ctx.actions.declare_output(marker)
        ctx.actions.run(
            cmd_args(
                tool,
                "check",
                _flags(ctx, tag, files, ctx.attrs.readme, licenses),
                "--wheel",
                raw.project(name),
                "--twin",
                twin.project(name),
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

    def gated_copy(where, gate):
        # A copy made after the check passed, so it does not exist unless it
        # did (as conda.bzl's joins).
        out = ctx.actions.declare_output(where, dir = True)
        ctx.actions.run(
            cmd_args(ctx.attrs._pkg_act[RunInfo], "copy-dir", raw, out.as_output(), hidden = [gate]),
            env = salted(),
            category = "wheel_join",
            identifier = where,
        )
        return out.project(name)

    whl = gated_copy("out", checked)
    rel = gated_copy("release", release_checked)

    # The file name alone, written at analysis: what an index lists the wheel
    # as, known before anything is built (pypi.yml asks the index for it
    # before building a wheel whose build is costly).
    file_name = ctx.actions.write(ctx.label.name + ".file_name", name + "\n")
    return [DefaultInfo(
        default_output = whl,
        other_outputs = [rel] if ctx.attrs.check_release else [],
        sub_targets = {
            "check": [DefaultInfo(default_output = checked)],
            "file_name": [DefaultInfo(default_output = file_name)],
            "release": [DefaultInfo(default_output = rel)],
            "release_check": [DefaultInfo(default_output = release_checked)],
            "twin": [DefaultInfo(default_output = twin.project(name))],
        },
    )]

_wheel_file = rule(
    impl = _wheel_file_impl,
    attrs = {
        # Set by wheel_file_test_stamped: the default output waits for
        # [release] too, so building the target runs the release check.
        "check_release": attrs.bool(default = False),
        "classifiers": attrs.list(attrs.string(), default = []),
        # The stamp (-c komira.package_*), set by the macros.
        "commit": attrs.string(),
        "distribution": attrs.string(),
        "executable": attrs.list(attrs.string(), default = []),
        "external_needed": attrs.list(attrs.string(), default = []),
        "files": attrs.dict(attrs.string(), attrs.source()),
        "license_expression": attrs.string(),
        "license_files": attrs.dict(attrs.string(), attrs.source(), default = {
            "LICENSE": "komira//:LICENSE",
            "NOTICE": "komira//:NOTICE",
        }),
        "max_cxxabi": attrs.option(attrs.string(), default = None),
        "max_glibcxx": attrs.option(attrs.string(), default = None),
        "os_floor": attrs.option(attrs.string(), default = None),
        "platform": attrs.string(default = "linux-x86_64"),
        "project_urls": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "readme": attrs.source(),
        "requires_dist": attrs.list(attrs.string(), default = []),
        "requires_python": attrs.string(),
        "stamp": attrs.string(),
        "summary": attrs.string(),
        "timestamp_ms": attrs.string(),
        "_pkg_act": attrs.exec_dep(default = "komira//tools/build/package:pkg_act", providers = [RunInfo]),
        "_wheel": attrs.exec_dep(default = "komira//tools/build/package:komira_wheel", providers = [RunInfo]),
    },
)

def _wheel_file_macro(**kwargs):
    # The stamp is read here, in the macro, so it keys only the wheel; the
    # tool refuses any mix but all three or none.
    _wheel_file(
        stamp = read_config("komira", "package_stamp", "0"),
        commit = read_config("komira", "package_commit", ""),
        timestamp_ms = read_config("komira", "package_timestamp_ms", "0"),
        exec_compatible_with = LINUX_X86_64,
        **kwargs
    )

def _wheel_file_test_stamped_macro(**kwargs):
    # conda.bzl's TEST stamp, so a build without -c komira.package_* has a
    # stamped wheel whose [release] it checks. No release carries it.
    _wheel_file(
        stamp = TEST_STAMP,
        commit = TEST_COMMIT,
        timestamp_ms = TEST_TIMESTAMP_MS,
        check_release = True,
        exec_compatible_with = LINUX_X86_64,
        **kwargs
    )

def _wheel_file_at_stamp_macro(stamp, **kwargs):
    # The test commit and commit time with the build number `stamp`, so one
    # build holds wheels of several versions (an upgrade test's previous and
    # current release). The stamp is a positive number without leading zeros,
    # which the tool checks. Not a release: no -c komira.package_* reaches it.
    _wheel_file(
        stamp = stamp,
        commit = TEST_COMMIT,
        timestamp_ms = TEST_TIMESTAMP_MS,
        check_release = True,
        exec_compatible_with = LINUX_X86_64,
        **kwargs
    )

wheel_file = declares_docs(_wheel_file_macro)
wheel_file_test_stamped = declares_docs(_wheel_file_test_stamped_macro)
wheel_file_at_stamp = declares_docs(_wheel_file_at_stamp_macro)

def _wheel_tag_cases_impl(ctx):
    # Each row's tag, against the tag written out (not derived) in `cases`.
    for name, want in ctx.attrs.cases.items():
        got = wheel_tag(row(name))
        if got != want:
            fail("{}: wheel_tag of row {} is {}, not {}".format(ctx.label, name, got, want))
    for os_floor, want in ctx.attrs.linux_floors.items():
        got = wheel_tag({"cpu": "x86_64", "name": "fixture", "os": "linux", "os_floor": os_floor})
        if got != want:
            fail("{}: wheel_tag of a linux x86_64 row at {} is {}, not {}".format(ctx.label, os_floor, got, want))
    for path, want in ctx.attrs.path_refusals.items():
        got = brace_refusal("fixture", [path])
        if got != (want or None):
            fail("{}: brace_refusal of path {} is {}, not {}".format(ctx.label, path, got, want or None))
    out = ctx.actions.write(ctx.label.name + ".ok", "ok\n")
    return [DefaultInfo(default_output = out)]

_wheel_tag_cases = rule(
    impl = _wheel_tag_cases_impl,
    doc = "Holds `wheel_tag` of each platform row in `cases` (row name: tag) and of a linux x86_64 fixture row at each glibc floor in `linux_floors` (os_floor: tag) to the tag written out, and `brace_refusal` of target `fixture` with each path in `path_refusals` to the refusal written out (empty: none); analysis fails on the first that differs.",
    attrs = {
        "cases": attrs.dict(attrs.string(), attrs.string()),
        "linux_floors": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "path_refusals": attrs.dict(attrs.string(), attrs.string(), default = {}),
    },
)

wheel_tag_cases = declares_docs(_wheel_tag_cases)

def _wheel_libs_check_impl(ctx):
    runtime = ctx.attrs.runtime if hasattr(ctx.attrs, "runtime") else ctx.attrs.toolchain[MojoToolchainInfo].runtime
    out = ctx.actions.declare_output(ctx.label.name + ".libs")
    cmd = cmd_args(ctx.attrs._wheel[RunInfo], "libs", "--wheel", ctx.attrs.wheel, "--entry", ctx.attrs.entry)
    for path in ctx.attrs.opened:
        cmd.add("--opened", path)
    for name in ctx.attrs.runtime_libs:
        cmd.add("--runtime-lib", cmd_args(runtime.project(name), format = name + "={}"))
    for name in ctx.attrs.runtime_licenses:
        cmd.add("--runtime-license", name)
    for name in ctx.attrs.runtime_dists:
        cmd.add("--runtime-dist", name)
    if ctx.attrs.expect_refusal != None:
        cmd.add("--expect-refusal", ctx.attrs.expect_refusal)
    cmd.add("--out", out.as_output())
    ctx.actions.run(cmd, env = salted(), category = "wheel_libs")
    return [DefaultInfo(default_output = out)]

_LIBS_CHECK_DOC = "Reads the finished wheel `wheel` alone with `komira_wheel libs` (wheel/libs.zig): the libraries the member `entry` (ELF or Mach-O) and each member of `opened` load, through each one's run path, must all be in the wheel or be system libraries and be every native member, each of `runtime_libs` carried once with the bytes of the Mojo runtime and its `runtime_licenses` in the dist-info, and no Requires-Dist names one of `runtime_dists`. The output lists the loaded libraries; with `expect_refusal`, it exists only if the wheel is refused with exactly that line."

_LIBS_CHECK_ATTRS = {
    "entry": attrs.string(),
    "expect_refusal": attrs.option(attrs.string(), default = None),
    "opened": attrs.list(attrs.string(), default = []),
    "runtime_dists": attrs.list(attrs.string(), default = []),
    "runtime_libs": attrs.list(attrs.string()),
    "runtime_licenses": attrs.list(attrs.string(), default = []),
    "wheel": attrs.source(),
    "_wheel": attrs.exec_dep(default = "komira//tools/build/package:komira_wheel", providers = [RunInfo]),
}

# The runtime is the toolchain's.
_wheel_libs_check = rule(
    impl = _wheel_libs_check_impl,
    doc = _LIBS_CHECK_DOC + " The runtime is the toolchain's.",
    attrs = _LIBS_CHECK_ATTRS | {
        "toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)

# The runtime is a directory named by the caller: the darwin toolchain executes
# on macOS and this check on Linux, so a macOS wheel's check cannot reach the
# runtime through the toolchain.
_wheel_libs_check_runtime = rule(
    impl = _wheel_libs_check_impl,
    doc = _LIBS_CHECK_DOC + " The runtime is the directory `runtime` (a `mojo_runtime`).",
    attrs = _LIBS_CHECK_ATTRS | {
        "runtime": attrs.source(),
    },
)

def _wheel_libs_check_macro(**kwargs):
    if "runtime" in kwargs:
        _wheel_libs_check_runtime(exec_compatible_with = LINUX_X86_64, **kwargs)
    else:
        _wheel_libs_check(exec_compatible_with = LINUX_X86_64, **kwargs)

wheel_libs_check = declares_docs(_wheel_libs_check_macro)

def _wheel_same_check_impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name + ".same")
    cmd = cmd_args(ctx.attrs._wheel[RunInfo], "same", "--wheel", ctx.attrs.wheel, "--like", ctx.attrs.like)
    for m in ctx.attrs.only_in_wheel:
        cmd.add("--only-in-wheel", m)
    for m in ctx.attrs.only_in_like:
        cmd.add("--only-in-like", m)
    cmd.add("--out", out.as_output())
    ctx.actions.run(cmd, env = salted(), category = "wheel_same")
    return [DefaultInfo(default_output = out)]

_wheel_same_check = rule(
    impl = _wheel_same_check_impl,
    doc = "Reads two finished wheels of one package for two platforms, `wheel` and `like`, with `komira_wheel same` (wheel/compare.zig): every member but RECORD and WHEEL must be in both with the same bytes and mode, except `only_in_wheel` and `only_in_like`, each in its own wheel alone and each a native library; WHEEL may differ only in its Tag's platform part. The output lists the members alike and each wheel's own.",
    attrs = {
        "like": attrs.source(),
        "only_in_like": attrs.list(attrs.string(), default = []),
        "only_in_wheel": attrs.list(attrs.string(), default = []),
        "wheel": attrs.source(),
        "_wheel": attrs.exec_dep(default = "komira//tools/build/package:komira_wheel", providers = [RunInfo]),
    },
)

def _wheel_same_check_macro(**kwargs):
    _wheel_same_check(exec_compatible_with = LINUX_X86_64, **kwargs)

wheel_same_check = declares_docs(_wheel_same_check_macro)
