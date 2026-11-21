"""The rules of the Python package's wheel and its clean-environment install
test (python/BUCK): `picked_files` and `wheel_install_test`.

`picked_files(name, dir, paths)` names files of a directory another target
builds, one sub-target each, by file name: `:<name>[libkomira.so]`. The wheel
itself copies `//src/so:libkomira[dist]` whole; the wheels of the refusing
cases take its files one by one, so that each can be put somewhere else or
left out. A path the directory does not hold fails the action that reads it;
two paths with one file name fail analysis.

`wheel_install_test(name, python, wheels, script, args, files,
skip_requirements, expect_failure, exec_compatible_with)` installs `wheels` into an empty virtual
environment of the interpreter `python` (a `python_dist`), the way
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
interpreter's prefix). Building the target is running the test. It runs on
`exec_compatible_with`, Linux x86_64 unless given (python/BUCK passes the
macOS arm64 platform for the macOS wheel's test, with the interpreter built
for it).
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
        "wheels": attrs.list(attrs.source()),
        "_driver": attrs.source(default = "komira//python/tests:wheel_install_run.py"),
        "_installer": attrs.source(default = "komira//tools/build/python:wheel_install.py"),
    },
)

def _picked_files_macro(**kwargs):
    _picked_files(**kwargs)

def _wheel_install_test_macro(exec_compatible_with = LINUX_X86_64, **kwargs):
    _wheel_install_test(exec_compatible_with = exec_compatible_with, **kwargs)

picked_files = declares_docs(_picked_files_macro)
wheel_install_test = declares_docs(_wheel_install_test_macro)
