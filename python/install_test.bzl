"""The rules of the Python package's wheel and its clean-environment install
test (python/BUCK): `picked_files`, `wheel_install_test` and `python_versions`.

`python_versions(name, versions)` writes, for each platform of `versions`
({platform: [version]}), the sub-target `:<name>[<platform>]`: a JSON list of
that platform's versions, in the order given (`["3.11.17", "3.12.15"]`). It is
how a workflow's job matrix reads the supported Pythons (python/pythons.bzl).

`picked_files(name, dir, paths)` names files of a directory another target
builds, one sub-target each, by file name: `:<name>[libkomira.so]`. The wheel
itself copies `//src/so:libkomira[dist]` whole; the wheels of the refusing
cases take its files one by one, so that each can be put somewhere else or
left out. A path the directory does not hold fails the action that reads it;
two paths with one file name fail analysis.

`wheel_install_test(name, python, wheels, script, args, files,
skip_requirements, upgrade, expect_failure, exec_compatible_with)` installs
`wheels` into an empty virtual environment of the interpreter `python` (a
`python_dist`), the way
`python_wheel` installs a wheel and with no pip and no network, then runs
`script` with that environment's interpreter in isolated mode, from an empty
directory: python/tests/wheel_install_run.py says each step and what it
refuses. The action's environment is `LC_ALL=C` and `TZ=UTC0` and nothing
else: no library path, so the script loads what the environment holds. The
interpreter's `preload` libraries (the C++ runtime a user's system has) are
passed to the script as `--host-lib` paths, `args` as they are, and `files`
({flag: source}) as `<flag> <absolute path>`. The output, `<name>.pass`, exists
only if the run passed: with `expect_failure`, only if it failed with exactly
that line (`<site>` and `<python>` standing for the site directory and the
interpreter's prefix). With `upgrade`, `wheels` are the releases of one
distribution, oldest first, after any distribution they require, and each
release is installed the way `pip install` of a newer version installs it: the release before it is uninstalled first (its
RECORD's files deleted), and the script is given `--removed <path>` for each
file the replaced release had that the new one lacks. Building the target is
running the test. It runs on `exec_compatible_with`, Linux x86_64 unless given
(python/BUCK passes the macOS arm64 platform for the macOS wheel's test, with
the interpreter built for it), and on Linux x86_64 it is compatible with that
platform only, so a darwin-arm64 build skips it unless the call names its own.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/python:defs.bzl", "PythonDistInfo")

def _picked_files_impl(ctx):
    src = ctx.attrs.dir[DefaultInfo].default_outputs[0]
    subs = {}
    outs = []
    for p in ctx.attrs.paths:
        base = p.split("/")[-1]
        if base in subs:
            fail("{}: two paths have the file name {}".format(ctx.label, base))
        f = src.project(p)
        subs[base] = [DefaultInfo(default_output = f)]
        outs.append(f)
    return [DefaultInfo(default_outputs = outs, sub_targets = subs)]

_picked_files = rule(
    impl = _picked_files_impl,
    doc = "The files `paths` of the directory `dir` builds, each the sub-target named by its file name.",
    attrs = {
        "dir": attrs.dep(),
        "paths": attrs.list(attrs.string()),
    },
)

def _wheel_install_test_impl(ctx):
    dist = ctx.attrs.python[PythonDistInfo]
    out = ctx.actions.declare_output(ctx.label.name + ".pass")
    tmp = ctx.actions.declare_output(ctx.label.name + ".tmp", dir = True)
    cmd = cmd_args(
        cmd_args(dist.root, format = "{}/" + dist.exe),
        "-I",
        "-S",
        ctx.attrs._driver,
        "--installer",
        ctx.attrs._installer,
        "--out",
        out.as_output(),
        "--tmpdir",
        tmp.as_output(),
    )
    for w in ctx.attrs.wheels:
        cmd.add("--wheel", w)
    if ctx.attrs.skip_requirements:
        cmd.add("--skip-requirements")
    if ctx.attrs.upgrade:
        cmd.add("--upgrade")
    for lib in dist.preload:
        cmd.add("--host-lib", cmd_args(dist.native_libs, format = "{}/" + lib))
    for a in ctx.attrs.args:
        cmd.add("--arg", a)
    for flag, f in sorted(ctx.attrs.files.items()):
        if not flag.startswith("--") or "{" in flag or "}" in flag:
            fail("{}: files key {} is not a flag".format(ctx.label, flag))
        cmd.add("--path-arg", cmd_args(f, format = flag + "={}"))
    if ctx.attrs.expect_failure != None:
        cmd.add("--expect-failure", ctx.attrs.expect_failure)
    cmd.add("--script", ctx.attrs.script)
    ctx.actions.run(cmd, env = {"LC_ALL": "C", "TZ": "UTC0"}, category = "wheel_install_test")
    return [DefaultInfo(default_output = out, other_outputs = [tmp])]

_wheel_install_test = rule(
    impl = _wheel_install_test_impl,
    doc = "Installs `wheels` into an empty virtual environment of `python` and runs `script` there in isolated mode with no library path, as a build action (python/install_test.bzl); the output exists only if the run passed, or, with `expect_failure`, failed with exactly that line.",
    attrs = {
        "args": attrs.list(attrs.string(), default = []),
        "expect_failure": attrs.option(attrs.string(), default = None),
        "files": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "python": attrs.exec_dep(providers = [PythonDistInfo]),
        "script": attrs.source(),
        "skip_requirements": attrs.bool(default = False),
        "upgrade": attrs.bool(default = False),
        "wheels": attrs.list(attrs.source()),
        "_driver": attrs.source(default = "komira//python/tests:wheel_install_run.py"),
        "_installer": attrs.source(default = "komira//tools/build/python:wheel_install.py"),
    },
)

def _python_versions_impl(ctx):
    subs = {}
    for platform, versions in sorted(ctx.attrs.versions.items()):
        f = ctx.actions.write_json(platform + ".json", versions)
        subs[platform] = [DefaultInfo(default_output = f)]
    return [DefaultInfo(default_outputs = [s[0].default_outputs[0] for s in subs.values()], sub_targets = subs)]

_python_versions = rule(
    impl = _python_versions_impl,
    doc = "For each platform of `versions`, the sub-target `[<platform>]`: a JSON list of its versions, in the order given (python/pythons.bzl, HOSTED).",
    attrs = {
        "versions": attrs.dict(attrs.string(), attrs.list(attrs.string())),
    },
)

def _picked_files_macro(**kwargs):
    _picked_files(**kwargs)

def _wheel_install_test_macro(exec_compatible_with = LINUX_X86_64, **kwargs):
    if exec_compatible_with == LINUX_X86_64:
        # The wheels it installs are Linux wheels, into the Linux interpreter:
        # another target platform skips the test, as it skips the wheels.
        kwargs.setdefault("target_compatible_with", LINUX_X86_64)  # komira-limit:manylinux-wheel-linux-x86-64
    _wheel_install_test(exec_compatible_with = exec_compatible_with, **kwargs)

def _python_versions_macro(**kwargs):
    _python_versions(**kwargs)

picked_files = declares_docs(_picked_files_macro)
python_versions = declares_docs(_python_versions_macro)
wheel_install_test = declares_docs(_wheel_install_test_macro)
