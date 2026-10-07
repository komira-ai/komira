"""Hermetic Python for tests: `python_dist`, `python_wheel` and `py_test`.

`python_dist` unpacks a sha256-pinned CPython archive (an `install_only`
archive of python-build-standalone) into a directory and fails unless the
interpreter in it runs and reports the pinned version. `python_wheel` installs
one sha256-pinned wheel into a directory of its own, with that interpreter
and `wheel_install.py` (no pip): it fails unless the wheel's `.dist-info` names
the pinned distribution and version. `py_test` runs one Python script with that
interpreter as a build action, through `pyrun.py`; its output exists only if
the script passed, so building the target is running the test.

Every action runs `bin/python3.<minor>` of the unpacked archive with `-I -S`:
no `PYTHON*` variable, no user or system site directory, no script directory
is read. The only importable code is the standard library of the archive, the
script's own directory, and the directories of the wheels in `deps` (and of
theirs), each passed to `pyrun.py` as a `--site` flag. The shared libraries
the wheels' extension modules link beyond glibc (the dist's `preload`, from
its `native_libs` directory) are loaded by path before the script runs, so
an extension module needing one finds that copy, not the worker's: the
loader resolves a needed name to an object already loaded under that soname.
The environment of the `python_wheel` and `py_test` actions is `LC_ALL=C`
and `TZ=UTC0` (a POSIX rule: local time is UTC and the C library reads no
zone file for it); a `py_test`'s also has `TZDIR`, the `zoneinfo` directory
of its `tzdata` wheel, which `pyrun.py` makes Python's only zone path, so no
zone is read from the worker.

The rules are linux x86_64 only: the macros set `exec_compatible_with` to
the linux x86_64 execution platform.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:toolchain.bzl", "busybox_sh")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

PythonDistInfo = provider(
    doc = "An unpacked CPython: its root directory and the interpreter's path in it.",
    fields = {
        "root": provider_field(Artifact),
        # `bin/python3.<minor>`, relative to `root`.
        "exe": provider_field(str),
        "version": provider_field(str),
        # A directory of shared libraries the wheels' extension modules link
        # beyond glibc, and the paths in it to load before a script runs, in
        # that order.
        "native_libs": provider_field(Artifact | None),
        "preload": provider_field(list[str]),
    },
)

PythonWheelInfo = provider(
    doc = "Installed wheels: this one and the closure of its deps, by normalized distribution name.",
    fields = {
        "name": provider_field(str),
        "version": provider_field(str),
        # {normalized name: (version, site directory)}, this wheel included.
        "closure": provider_field(dict),
    },
)

def normalize(name):
    """The PEP 503 normalized form of a distribution name."""
    out = name.lower()
    for c in ["_", "."]:
        out = out.replace(c, "-")
    for _ in range(4):
        out = out.replace("--", "-")
    return out

def _exe_name(version):
    parts = version.split(".")
    if len(parts) != 3:
        fail("python_dist: version must be <major>.<minor>.<micro>, got '{}'".format(version))
    return "bin/python{}.{}".format(parts[0], parts[1])

# Unpacks the archive (its single top directory is `python/`), moves that
# directory to the output, and runs the interpreter in it, which must print
# the pinned version.
_DIST_SCRIPT = """
BB="$1"; shift
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.komira_action" ;;
    /*) T="$BUCK_SCRATCH_PATH/komira" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/komira" ;;
esac
"$BB" mkdir -p "$T/bin" "$T/x"
"$BB" --install -s "$T/bin"
PATH="$T/bin"; export PATH
ARCHIVE="$1"; OUT="$2"; EXE="$3"; WANT="$4"
tar -xzf "$ARCHIVE" -C "$T/x"
if [ ! -x "$T/x/python/$EXE" ]; then
    echo "python_dist: $ARCHIVE holds no python/$EXE" >&2
    exit 2
fi
mv "$T/x/python" "$OUT"
# Removes what the archive installed into site-packages (pip): no action
# installs with it, and -S keeps the directory off sys.path.
rm -rf "$OUT"/lib/python3.*/site-packages/*
GOT=$("$OUT/$EXE" -I -S -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])') || {
    echo "python_dist: $OUT/$EXE does not run" >&2
    exit 2
}
if [ "$GOT" != "$WANT" ]; then
    echo "python_dist: the interpreter in $ARCHIVE is $GOT, the pin says $WANT" >&2
    exit 2
fi
rm -rf "$T"
"""

def _python_dist_impl(ctx):
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    archive = ctx.attrs.archive[DefaultInfo].default_outputs[0]
    exe = _exe_name(ctx.attrs.version)
    out = ctx.actions.declare_output("python", dir = True)
    if ctx.attrs.preload and not ctx.attrs.native_libs:
        fail("{}: preload names libraries but native_libs is not set".format(ctx.label))
    ctx.actions.run(
        busybox_sh(bb, _DIST_SCRIPT, archive, out.as_output(), exe, ctx.attrs.version),
        category = "python_dist",
    )
    return [
        DefaultInfo(default_output = out),
        PythonDistInfo(
            root = out,
            exe = exe,
            version = ctx.attrs.version,
            native_libs = ctx.attrs.native_libs[DefaultInfo].default_outputs[0] if ctx.attrs.native_libs else None,
            preload = ctx.attrs.preload,
        ),
    ]

_python_dist = rule(
    impl = _python_dist_impl,
    doc = "A CPython `install_only` archive unpacked into one directory, without the packages of its site-packages (pip); fails unless its `bin/python<major>.<minor>` runs and prints `version`. `py_test` loads the `preload` libraries of `native_libs`, in order, before a script runs.",
    attrs = {
        # A pinned_file holding the `.tar.gz`.
        "archive": attrs.dep(),
        # A directory holding the libraries `preload` names (paths in it).
        "native_libs": attrs.option(attrs.dep(), default = None),
        "preload": attrs.list(attrs.string(), default = []),
        "version": attrs.string(),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)

# The C locale, set so that the interpreter does not coerce it to C.UTF-8
# (PEP 538), which would load the worker's locale files; with it, the
# interpreter is in UTF-8 mode (PEP 540) and reads no locale file. TZ is a
# POSIX rule rather than a zone name, so the C library's local time is UTC
# and comes from no zone file (an unset TZ reads the worker's /etc/localtime).
_ENV = {"LC_ALL": "C", "TZ": "UTC0"}

def _python(dist):
    return cmd_args(dist.root, format = "{}/" + dist.exe)

def _python_wheel_impl(ctx):
    dist = ctx.attrs.python[PythonDistInfo]
    wheel = ctx.attrs.wheel[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output("site", dir = True)
    ctx.actions.run(
        cmd_args(
            _python(dist),
            "-I",
            "-S",
            ctx.attrs._installer,
            "--wheel",
            wheel,
            "--name",
            ctx.attrs.distribution,
            "--version",
            ctx.attrs.version,
            "--out",
            out.as_output(),
        ),
        env = _ENV,
        category = "python_wheel",
    )
    key = normalize(ctx.attrs.distribution)
    closure = {key: (ctx.attrs.version, out)}
    for d in ctx.attrs.deps:
        for k, v in d[PythonWheelInfo].closure.items():
            if k in closure and closure[k][0] != v[0]:
                fail("{}: {} is pinned at {} and at {} in its deps".format(ctx.label, k, closure[k][0], v[0]))
            closure[k] = v
    return [
        DefaultInfo(default_output = out),
        PythonWheelInfo(name = key, version = ctx.attrs.version, closure = closure),
    ]

_python_wheel = rule(
    impl = _python_wheel_impl,
    doc = "One wheel installed into a directory (its `purelib` and `platlib` merged in, its `scripts`, `headers` and `data` left out), by `wheel_install.py` run with `python`; fails unless the wheel is `distribution` at `version`. `deps` are the wheels it imports.",
    attrs = {
        "deps": attrs.list(attrs.dep(providers = [PythonWheelInfo]), default = []),
        "distribution": attrs.string(),
        "python": attrs.exec_dep(providers = [PythonDistInfo]),
        "version": attrs.string(),
        # A pinned_file holding the `.whl`.
        "wheel": attrs.dep(),
        "_installer": attrs.source(default = "komira//tools/build/python:wheel_install.py"),
    },
)

def _py_test_impl(ctx):
    dist = ctx.attrs.python[PythonDistInfo]
    srcs = {ctx.attrs.src.short_path: ctx.attrs.src}
    for s in ctx.attrs.srcs:
        if s.short_path in srcs:
            fail("{}: {} is listed twice".format(ctx.label, s.short_path))
        srcs[s.short_path] = s
    staged = ctx.actions.copied_dir("srcs", srcs)
    closure = {}
    for d in ctx.attrs.deps + [ctx.attrs.tzdata]:
        for k, v in d[PythonWheelInfo].closure.items():
            if k in closure and closure[k][0] != v[0]:
                fail("{}: {} is pinned at {} and at {} in its deps".format(ctx.label, k, closure[k][0], v[0]))
            closure[k] = v
    out = ctx.actions.declare_output(ctx.label.name + ".pass")
    tmp = ctx.actions.declare_output(ctx.label.name + ".tmp", dir = True)
    cmd = cmd_args(_python(dist), "-I", "-S", ctx.attrs._runner, "--out", out.as_output(), "--tmpdir", tmp.as_output())
    for lib in dist.preload:
        cmd.add("--preload", cmd_args(dist.native_libs, format = "{}/" + lib))
    for k in sorted(closure.keys()):
        cmd.add("--site", closure[k][1])
    if ctx.attrs.expect_error != None:
        cmd.add("--expect-error", ctx.attrs.expect_error)
    cmd.add("--", cmd_args(staged, format = "{}/" + ctx.attrs.src.short_path), ctx.attrs.args)
    # The zone database every reader takes: the C library and ORC read TZDIR,
    # and pyrun.py makes it Python's only zoneinfo path.
    tzdata = ctx.attrs.tzdata[PythonWheelInfo].closure[ctx.attrs.tzdata[PythonWheelInfo].name][1]
    env = dict(_ENV)
    env["TZDIR"] = cmd_args(tzdata, format = "{}/tzdata/zoneinfo")
    ctx.actions.run(cmd, env = env, category = "py_test")
    return [DefaultInfo(default_output = out, other_outputs = [tmp])]

_py_test = rule(
    impl = _py_test_impl,
    doc = "Runs `src` with the hermetic interpreter (`python`) as a build action; the output exists only if it passed (exit 0, or, with `expect_error`, an exception whose last traceback line is exactly that string). `srcs` are staged next to `src` and importable from it; `deps` are wheels (`python_wheel`), each with its own deps; `args` are the script's arguments. `tzdata` is the wheel whose `tzdata/zoneinfo` directory is the action's `TZDIR` and Python's only zone path.",
    attrs = {
        "args": attrs.list(attrs.arg(), default = []),
        "deps": attrs.list(attrs.exec_dep(providers = [PythonWheelInfo]), default = []),
        "expect_error": attrs.option(attrs.string(), default = None),
        "python": attrs.exec_dep(providers = [PythonDistInfo], default = "komira//third_party/python:cpython"),
        "src": attrs.source(),
        "srcs": attrs.list(attrs.source(), default = []),
        "tzdata": attrs.exec_dep(providers = [PythonWheelInfo], default = "komira//third_party/python:tzdata"),
        "_runner": attrs.source(default = "komira//tools/build/python:pyrun.py"),
    },
)

def _linux(kwargs):
    if "exec_compatible_with" not in kwargs:
        kwargs["exec_compatible_with"] = LINUX_X86_64
    return kwargs

def _dist_macro(**kwargs):
    _python_dist(**_linux(kwargs))

def _wheel_macro(**kwargs):
    _python_wheel(**_linux(kwargs))

def _py_test_macro(**kwargs):
    _py_test(**_linux(kwargs))

# Each rule and macro a BUCK file calls declares its package's doc_tree
# (tools/build/lint/doc_tree.bzl), so no BUCK file names one.
python_dist = declares_docs(_dist_macro)
python_wheel = declares_docs(_wheel_macro)
py_test = declares_docs(_py_test_macro)
