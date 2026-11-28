"""Hermetic Python for tests: `python_dist`, `python_wheel`,
`python_source_package`, `py_test`, `python_binding_test`, `python_oracle` and
`python_proto`.

`python_dist` unpacks a sha256-pinned CPython archive (an `install_only`
archive of python-build-standalone) into a directory and fails unless the
interpreter in it runs and reports the pinned version, and is free-threaded
exactly when the target says so. `python_wheel` installs
one sha256-pinned wheel into a directory of its own, with that interpreter
and `wheel_install.py` (no pip): it fails unless the wheel's `.dist-info` names
the pinned distribution and version. `python_source_package` stages the files
of an import package of this repository at their paths in a directory of its
own, which a test imports from as it does a wheel's. `py_test` runs one Python
script with that interpreter as a build action, through `pyrun.py`; its output exists only if
the script passed, so building the target is running the test.
`python_oracle` runs one script twice, through `oracle_run.py`, and outputs
the directory it wrote, which other targets take as test data; it fails
unless both runs wrote the same tree. `python_proto` runs the pinned protoc
to generate the `_pb2.py` modules of a set of `.proto` files.

Every action runs `bin/python3.<minor>` (`bin/python3.<minor>t` for a
free-threaded build) of the unpacked archive with `-I -S`:
no `PYTHON*` variable, no user or system site directory, no script directory
is read. The only importable code is the standard library of the archive, the
script's own directory, and the directories of the wheels in `deps` (and of
theirs), each passed to `pyrun.py` as a `--site` flag. The shared libraries
the wheels' extension modules link beyond glibc (the dist's `preload`, from
its `native_libs` directory) are loaded by path before the script runs, so
an extension module needing one finds that copy, not the worker's: the
loader resolves a needed name to an object already loaded under that soname.
The environment of the `python_wheel`, `py_test` and `python_oracle` actions
is `LC_ALL=C` and `TZ=UTC0` (a POSIX rule: local time is UTC and the C
library reads no zone file for it); a `py_test`'s and a `python_oracle`'s
also has `TZDIR`, the `zoneinfo` directory of its `tzdata` wheel, which
`pyrun.py` and `oracle_run.py` make Python's only zone path, so no zone is
read from the worker. A `py_test` that `-c komira.rerun` names also has
`KOMIRA_RERUN` (tools/build/rerun/README.md). An oracle's script runs in a child interpreter
`oracle_run.py` starts with `-s -S -P` instead (no user site directory, no
`site`, no script directory put first by the interpreter) and the
environment `LC_ALL=C PYTHONHASHSEED=0 TZ=UTC0 TZDIR=<absolute>` and nothing
else, so that string hashes are the same in every run; `-I` would ignore
`PYTHONHASHSEED`.

The rules run on linux x86_64 and on macOS arm64. The macros choose the
execution platform from the target platform's operating system:
`exec_compatible_with` is the linux x86_64 platform, or the darwin arm64 one
for a target configured for macOS, and `python` (and, for `python_binding_test`,
`runtime`) default to the interpreter and Mojo runtime of that platform. The
macOS interpreter is unpacked, and its version checked, by a macOS build of
`python_act` that a macOS worker runs.

A `python_wheel`, `py_test` or `python_binding_test` that names its `python` by
a plain label runs that one pinned interpreter, and every one but
`komira//third_party/python:cpython_macos` (CPython 3.10, 3.11, 3.12, the Linux
3.13, 3.14 and free-threaded 3.14) is a linux x86_64 build: the macros configure that target
for linux x86_64 only (the limit `python-linux-interpreters`), so a macOS build
skips it as incompatible. A `python` that is a `select` on the operating system
(`third_party/python`'s wheels, the protobuf edge wheels of python/tests) is
not marked. The farm's macOS tests run CPython 3.13 alone.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:test_runtime.bzl", "data_map")
load("@komira//tools/build/platforms:defs.bzl", "DARWIN_ARM64", "LINUX_X86_64")
load("@komira//tools/build/rerun:rerun.bzl", "RERUN_ATTRS", "rerun_env", "rerun_info")
load("@komira//tools/build/toolchains:mojo_versions.bzl", "by_mojo")

PythonDistInfo = provider(
    doc = "An unpacked CPython: its root directory and the interpreter's path in it.",
    fields = {
        "root": provider_field(Artifact),
        # `bin/python3.<minor>`, or `bin/python3.<minor>t` for a
        # free-threaded build, relative to `root`.
        "exe": provider_field(str),
        "version": provider_field(str),
        "freethreaded": provider_field(bool),
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

def _exe_name(version, freethreaded):
    parts = version.split(".")
    if len(parts) != 3:
        fail("python_dist: version must be <major>.<minor>.<micro>, got '{}'".format(version))
    return "bin/python{}.{}{}".format(parts[0], parts[1], "t" if freethreaded else "")

# `python_act dist` unpacks the archive (its single top directory is `python/`)
# into the output, removes what the archive installed into site-packages (pip:
# no action installs with it, and -S keeps the directory off sys.path), and
# runs the interpreter in it, which must print the pinned version, followed by
# `t` if and only if it is a free-threaded build (`Py_GIL_DISABLED`).

def _python_dist_impl(ctx):
    archive = ctx.attrs.archive[DefaultInfo].default_outputs[0]
    exe = _exe_name(ctx.attrs.version, ctx.attrs.freethreaded)
    want = ctx.attrs.version + ("t" if ctx.attrs.freethreaded else "")
    out = ctx.actions.declare_output("python", dir = True)
    if ctx.attrs.preload and not ctx.attrs.native_libs:
        fail("{}: preload names libraries but native_libs is not set".format(ctx.label))
    ctx.actions.run(
        cmd_args(
            ctx.attrs.act[RunInfo],
            "dist",
            "--archive",
            archive,
            "--out",
            out.as_output(),
            "--exe",
            exe,
            "--version",
            want,
        ),
        category = "python_dist",
    )
    return [
        DefaultInfo(default_output = out),
        PythonDistInfo(
            root = out,
            exe = exe,
            version = ctx.attrs.version,
            freethreaded = ctx.attrs.freethreaded,
            native_libs = ctx.attrs.native_libs[DefaultInfo].default_outputs[0] if ctx.attrs.native_libs else None,
            preload = ctx.attrs.preload,
        ),
    ]

_python_dist = rule(
    impl = _python_dist_impl,
    doc = "A CPython `install_only` archive unpacked into one directory, without the packages of its site-packages (pip); fails unless its `bin/python<major>.<minor>` (`bin/python<major>.<minor>t` with `freethreaded`) runs, prints `version`, and is a free-threaded build if and only if `freethreaded` is set. `py_test` loads the `preload` libraries of `native_libs`, in order, before a script runs.",
    attrs = {
        # A pinned_file holding the `.tar.gz`.
        "archive": attrs.dep(),
        # A free-threaded build (`Py_GIL_DISABLED`), whose interpreter is
        # `bin/python<major>.<minor>t`.
        "freethreaded": attrs.bool(default = False),
        # A directory holding the libraries `preload` names (paths in it).
        "native_libs": attrs.option(attrs.dep(), default = None),
        "preload": attrs.list(attrs.string(), default = []),
        "version": attrs.string(),
        # The unpacker and version check: python_act built for the platform
        # that runs the interpreter.
        "act": attrs.exec_dep(default = "komira//tools/build/python_act:python_act", providers = [RunInfo]),
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

def _run_py_test(ctx, lib_args = [], env_extra = {}):
    """The action every `py_test` and `python_binding_test` runs; `lib_args`
    go between `--` and the script's own arguments, `env_extra` is added to
    the action's environment."""
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
    cmd.add("--", cmd_args(staged, format = "{}/" + ctx.attrs.src.short_path), lib_args, ctx.attrs.args)
    # The zone database every reader takes: the C library and ORC read TZDIR,
    # and pyrun.py makes it Python's only zoneinfo path.
    tzdata = ctx.attrs.tzdata[PythonWheelInfo].closure[ctx.attrs.tzdata[PythonWheelInfo].name][1]
    env = dict(_ENV)
    env["TZDIR"] = cmd_args(tzdata, format = "{}/tzdata/zoneinfo")
    env.update(env_extra)
    env.update(rerun_env(ctx))
    ctx.actions.run(cmd, env = env, category = ctx.attrs._category)
    return [DefaultInfo(default_output = out, other_outputs = [tmp]), rerun_info(ctx)]

def _py_test_impl(ctx):
    return _run_py_test(ctx)

_PY_TEST_ATTRS = {
    "args": attrs.list(attrs.arg(), default = []),
    "deps": attrs.list(attrs.exec_dep(providers = [PythonWheelInfo]), default = []),
    "expect_error": attrs.option(attrs.string(), default = None),
    "python": attrs.exec_dep(providers = [PythonDistInfo], default = "komira//third_party/python:cpython"),
    "src": attrs.source(),
    "srcs": attrs.list(attrs.source(), default = []),
    "tzdata": attrs.exec_dep(providers = [PythonWheelInfo], default = "komira//third_party/python:tzdata"),
    "_runner": attrs.source(default = "komira//tools/build/python:pyrun.py"),
} | RERUN_ATTRS

_py_test = rule(
    impl = _py_test_impl,
    doc = "Runs `src` with the hermetic interpreter (`python`) as a build action; the output exists only if it passed (exit 0, or, with `expect_error`, an exception whose last traceback line is exactly that string). `srcs` are staged next to `src` and importable from it; `deps` are wheels (`python_wheel`), each with its own deps; `args` are the script's arguments. `tzdata` is the wheel whose `tzdata/zoneinfo` directory is the action's `TZDIR` and Python's only zone path.",
    attrs = _PY_TEST_ATTRS | {"_category": attrs.string(default = "py_test")},
)

# ---- python_binding_test -----------------------------------------------------
#
# A `py_test` that also loads shared libraries: the `mojo_shared_lib` targets
# of `libs` are copied, by file name, into one directory of the action, and the
# Mojo runtime libraries they link (the toolchain's `mojo_runtime`) are a
# second. The action's LD_LIBRARY_PATH and DYLD_LIBRARY_PATH are those two directories and nothing
# else, so the loader finds the library and the runtime in the action's inputs
# and never on the worker. The script learns the first directory from
# `--lib-dir <dir>`, its first two arguments (a flag, not an environment
# variable), and the second from `--runtime-dir <dir>`, the next two (for a
# script that opens a runtime library by path); `ctypes.CDLL(os.path.join(libdir, "<out_name>.so"))` loads a
# library by path. `data` ({dest: source}) is staged in the same directory at
# `dest`: a library's runnable directory (`libkomira[runnable]`, the library
# with its lib/ beside it) or a stand-in library under a path of its own. For a
# macOS target platform a destination named `*.so` is staged as `*.dylib`, the
# name a macOS process opens, so a test names a library as `libkomira.so` in
# its BUCK file and finds `libkomira.dylib` (`komira._native._LIB_NAME`).

def _python_binding_test_impl(ctx):
    libs = data_map(ctx, str(ctx.label.raw_target()), ctx.attrs.data)
    tops = {dest.split("/")[0]: True for dest in libs}
    for l in ctx.attrs.libs:
        out = l[DefaultInfo].default_outputs
        if len(out) != 1:
            fail("{}: lib {} has {} outputs, a shared library has one".format(ctx.label, l.label, len(out)))
        name = out[0].basename
        if name in libs or name in tops:
            fail("{}: two libs (or a lib and data) are named {}".format(ctx.label, name))
        libs[name] = out[0]
    libdir = ctx.actions.copied_dir("libs", libs)
    runtime = ctx.attrs.runtime[DefaultInfo].default_outputs[0]
    return _run_py_test(
        ctx,
        lib_args = ["--lib-dir", libdir, "--runtime-dir", runtime],
        env_extra = {
            "DYLD_LIBRARY_PATH": cmd_args(libdir, runtime, delimiter = ":"),
            "LD_LIBRARY_PATH": cmd_args(libdir, runtime, delimiter = ":"),
        },
    )

_python_binding_test = rule(
    impl = _python_binding_test_impl,
    doc = "A `py_test` that loads shared libraries: `libs` (`mojo_shared_lib` targets) are staged by file name in one directory, and `data` ({dest: source}, a build output allowed) at `dest` in it (a destination named `*.so` is staged as `*.dylib` when the target platform is macOS); the directory is passed to the script as `--lib-dir <dir>` and the runtime directory as `--runtime-dir <dir>`; the action's LD_LIBRARY_PATH and DYLD_LIBRARY_PATH are that directory and the Mojo runtime libraries (`runtime`), and nothing else.",
    attrs = _PY_TEST_ATTRS | {
        "data": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "libs": attrs.list(attrs.dep(), default = []),
        "runtime": attrs.exec_dep(default = "komira//tools/build/toolchains:mojo_runtime"),
        "_category": attrs.string(default = "python_binding_test"),
    },
)

# ---- python_source_package ---------------------------------------------------
#
# The files of an import package of this repository (`python/komira`) staged at
# their paths from the package in one directory, the site directory a test puts
# on sys.path with `--site`, as it does a wheel's: a test lists the target in
# `deps` and imports the package by its name. The closure's key is the target's
# name and its version is "source", so a wheel of the same distribution in the
# same closure fails analysis like any version clash.

def _python_source_package_impl(ctx):
    files = {}
    for s in ctx.attrs.srcs:
        files[s.short_path] = s
    site = ctx.actions.copied_dir("site", files)
    name = normalize(ctx.label.name)
    return [
        DefaultInfo(default_output = site),
        PythonWheelInfo(name = name, version = "source", closure = {name: ("source", site)}),
    ]

_python_source_package = rule(
    impl = _python_source_package_impl,
    doc = "The files `srcs` of an import package of this repository, staged at their paths from the package in one directory; a `py_test` or `python_binding_test` that lists the target in `deps` imports from it. The distribution's name is the target's name and its version is `source`.",
    attrs = {
        "srcs": attrs.list(attrs.source()),
    },
)

# ---- python_oracle -----------------------------------------------------------
#
# An oracle computes the answer a komira test compares against, so nothing it
# reads may come from komira: src, each srcs entry, each data source, each
# wheel of deps and the interpreter's directory, if an action built it (not a
# checked-in file), must be the output of a target under third_party/. Only
# direct inputs are checked: a third_party/ target is trusted not to build from
# komira.
_ORACLE_INPUT_REFUSED = "{}: the oracle's {} is built by {}, which is not under third_party/; an oracle reads checked-in files and third_party/ outputs only, so that its answer cannot come from komira (tools/build/python/README.md, Oracles)"

def _third_party(label):
    return label != None and (label.package == "third_party" or label.package.startswith("third_party/"))

def _check_independent(ctx, what, artifact):
    if artifact.is_source:
        return
    owner = artifact.owner
    if not _third_party(owner):
        fail(_ORACLE_INPUT_REFUSED.format(
            ctx.label.raw_target(),
            what,
            owner.raw_target() if owner != None else "an action of no rule",
        ))

def _check_outs(ctx):
    seen = {}
    for p in ctx.attrs.outs:
        if p == "" or p.startswith("/") or p.endswith("/"):
            fail("{}: outs entry {} must be a relative file path".format(ctx.label.raw_target(), repr(p)))
        for part in p.split("/"):
            if part in ("", ".", ".."):
                fail("{}: outs entry {} holds an empty, `.` or `..` segment".format(ctx.label.raw_target(), repr(p)))
        if p in seen:
            fail("{}: outs names {} twice".format(ctx.label.raw_target(), repr(p)))
        seen[p] = True

def _python_oracle_impl(ctx):
    dist = ctx.attrs.python[PythonDistInfo]
    where = str(ctx.label.raw_target())
    data = data_map(ctx, where + ": data", ctx.attrs.data)
    for dest in sorted(data.keys()):
        _check_independent(ctx, "data {}".format(repr(dest)), data[dest])
    _check_independent(ctx, "src", ctx.attrs.src)
    srcs = {ctx.attrs.src.short_path: ctx.attrs.src}
    for s in ctx.attrs.srcs:
        _check_independent(ctx, "srcs entry {}".format(repr(s.short_path)), s)
        if s.short_path in srcs:
            fail("{}: {} is listed twice".format(ctx.label, s.short_path))
        srcs[s.short_path] = s
    closure = {}
    for d in ctx.attrs.deps + [ctx.attrs.tzdata]:
        for k, v in d[PythonWheelInfo].closure.items():
            _check_independent(ctx, "wheel {}".format(k), v[1])
            if k in closure and closure[k][0] != v[0]:
                fail("{}: {} is pinned at {} and at {} in its deps".format(ctx.label, k, closure[k][0], v[0]))
            closure[k] = v
    # The interpreter's directory is built by the python_dist target itself;
    # its native_libs and preload libraries come with that target, trusted
    # like any other third_party/ target's inputs.
    _check_independent(ctx, "python", dist.root)
    _check_outs(ctx)
    staged = ctx.actions.copied_dir(ctx.label.name + ".srcs", srcs)
    data_dir = ctx.actions.copied_dir(ctx.label.name + ".data", data)
    out = ctx.actions.declare_output(ctx.label.name, dir = True)
    tmp = ctx.actions.declare_output(ctx.label.name + ".tmp", dir = True)
    cmd = cmd_args(_python(dist), "-I", "-S", ctx.attrs._runner, "--out", out.as_output(), "--tmpdir", tmp.as_output(), "--data", data_dir)
    for lib in dist.preload:
        cmd.add("--preload", cmd_args(dist.native_libs, format = "{}/" + lib))
    for k in sorted(closure.keys()):
        cmd.add("--site", closure[k][1])
    for p in ctx.attrs.outs:
        cmd.add("--outs", p)
    cmd.add("--", cmd_args(staged, format = "{}/" + ctx.attrs.src.short_path), ctx.attrs.args)
    # The zone database, as in a py_test: oracle_run.py passes TZDIR (made
    # absolute) and TZ=UTC0 to each run and makes TZDIR zoneinfo's only path.
    tzdata = ctx.attrs.tzdata[PythonWheelInfo].closure[ctx.attrs.tzdata[PythonWheelInfo].name][1]
    env = dict(_ENV)
    env["TZDIR"] = cmd_args(tzdata, format = "{}/tzdata/zoneinfo")
    ctx.actions.run(cmd, env = env, category = "python_oracle")
    return [DefaultInfo(
        default_output = out,
        other_outputs = [tmp],
        sub_targets = {p: [DefaultInfo(default_output = out.project(p))] for p in ctx.attrs.outs},
    )]

_python_oracle = rule(
    impl = _python_oracle_impl,
    doc = "Runs `src` twice with the hermetic interpreter (`oracle_run.py`) and outputs the directory the first run wrote, only if both runs wrote the same tree; each `outs` path is a sub-target `[<path>]`. The script gets `sys.argv = [src, <output directory>, <data directory>, *args]`; `data` ({dest: source}, or sources staged at their paths) is staged in the data directory, `srcs` next to `src`. Analysis fails if `src`, a `srcs` entry, a `data` source, a wheel of `deps` or the `python` dist was built by a target not under third_party/. `tzdata` is the wheel whose `tzdata/zoneinfo` directory is each run's `TZDIR` and Python's only zone path; it is in the closure.",
    attrs = {
        "args": attrs.list(attrs.string(), default = []),
        "data": attrs.one_of(attrs.list(attrs.source()), attrs.dict(attrs.string(), attrs.source()), default = {}),
        "deps": attrs.list(attrs.exec_dep(providers = [PythonWheelInfo]), default = []),
        "outs": attrs.list(attrs.string(), default = []),
        "python": attrs.exec_dep(providers = [PythonDistInfo], default = "komira//third_party/python:cpython"),
        "src": attrs.source(),
        "srcs": attrs.list(attrs.source(), default = []),
        "tzdata": attrs.exec_dep(providers = [PythonWheelInfo], default = "komira//third_party/python:tzdata"),
        "_runner": attrs.source(default = "komira//tools/build/python:oracle_run.py"),
    },
)

# ---- python_proto ------------------------------------------------------------

def _python_proto_impl(ctx):
    where = ctx.label.raw_target()
    prefix = ctx.attrs.import_prefix
    if prefix:
        for part in prefix.split("/"):
            if part in ("", ".", ".."):
                fail("{}: import_prefix {} holds an empty, `.` or `..` segment".format(where, repr(prefix)))
    if not ctx.attrs.srcs:
        fail("{}: srcs is empty".format(where))
    staged = {}
    outs = {}
    for src in ctx.attrs.srcs:
        if not src.basename.endswith(".proto"):
            fail("{}: src {} is not a .proto file".format(where, src.basename))
        path = prefix + "/" + src.basename if prefix else src.basename
        if path in staged:
            fail("{}: two srcs are named {}".format(where, src.basename))
        staged[path] = src
        module = src.basename[:-len(".proto")] + "_pb2"
        outs[module] = ctx.actions.declare_output(path[:-len(".proto")] + "_pb2.py")
    protoc = ctx.attrs._protoc[DefaultInfo].default_outputs[0]
    proto_path = ctx.actions.copied_dir(ctx.label.name + ".proto_path", staged)
    modules = sorted(outs.keys())
    # protoc writes `<import_prefix>/<stem>_pb2.py` under --python_out, so the
    # root is the first module's directory, one level up per prefix segment.
    depth = 1 + (len(prefix.split("/")) if prefix else 0)
    ctx.actions.run(
        cmd_args(
            cmd_args(protoc, format = "{}/bin/protoc"),
            cmd_args(proto_path, format = "--proto_path={}"),
            cmd_args(outs[modules[0]].as_output(), parent = depth, format = "--python_out={}"),
            [cmd_args(proto_path, format = "{}/" + p) for p in sorted(staged.keys())],
            hidden = [outs[m].as_output() for m in modules[1:]],
        ),
        category = "python_proto",
    )
    return [DefaultInfo(
        default_outputs = [outs[m] for m in modules],
        sub_targets = {m: [DefaultInfo(default_output = outs[m])] for m in modules},
    )]

_python_proto = rule(
    impl = _python_proto_impl,
    doc = "The Python modules the pinned protoc (`komira//tools/build/toolchains/proto:protoc`) generates for `srcs`, each `.proto` at `<import_prefix>/<name>.proto`, so the imports between them resolve: one `<import_prefix>/<stem>_pb2.py` per file, each the sub-target `[<stem>_pb2]`, for a `py_test`'s `srcs`.",
    attrs = {
        # The directory the files are imported from (`import "<import_prefix>/<name>.proto"`),
        # and so the Python package the modules import each other as; empty: the top level.
        "import_prefix": attrs.string(default = ""),
        "srcs": attrs.list(attrs.source()),
        "_protoc": attrs.exec_dep(default = "komira//tools/build/toolchains/proto:protoc"),
    },
)

_MACOS = "prelude//os/constraints:macos"

def _by_os(linux, macos):
    return select({_MACOS: macos, "DEFAULT": linux})

def _platform(kwargs):
    """Defaults a rule's execution platform to that of its target platform's OS, and `python` to that platform's interpreter."""
    if "exec_compatible_with" not in kwargs:
        kwargs["exec_compatible_with"] = _by_os(LINUX_X86_64, DARWIN_ARM64)
    return kwargs

def _interpreter(kwargs):
    if "python" not in kwargs:
        kwargs["python"] = _by_os("komira//third_party/python:cpython", "komira//third_party/python:cpython_macos")
    return kwargs

def _dist_macro(**kwargs):
    # A dist is for one platform, named by its exec_compatible_with and `act`.
    if "exec_compatible_with" not in kwargs:
        kwargs["exec_compatible_with"] = LINUX_X86_64
    _python_dist(**kwargs)

def _pinned_python(kwargs):
    """A `python` given as a plain label names one pinned interpreter, and every one but `:cpython_macos` is a linux x86_64 build (third_party/python): the target is configured for linux x86_64 only, so another platform skips it, and its wheels. No `python`, or a `select`, takes the platform's own."""
    python = kwargs.get("python")
    if type(python) == "string" and not python.endswith(":cpython_macos"):
        kwargs.setdefault("target_compatible_with", LINUX_X86_64)  # komira-limit:python-linux-interpreters
    return kwargs

def _wheel_macro(**kwargs):
    _python_wheel(**_platform(_pinned_python(kwargs)))

def _source_package_macro(**kwargs):
    _python_source_package(**kwargs)

def _py_test_macro(**kwargs):
    _py_test(**_interpreter(_platform(_pinned_python(kwargs))))

def _dylib_data(data):
    """`data` for a macOS target: each destination named `*.so` is staged as `*.dylib`, the name the loader of a macOS process opens (python/komira/_native.py)."""
    if type(data) != "dict":
        return data
    return select({
        _MACOS: {(k[:-len(".so")] + ".dylib" if k.endswith(".so") else k): v for k, v in data.items()},
        "DEFAULT": data,
    })

def _binding_test_macro(**kwargs):
    if "runtime" not in kwargs:
        # The runtime of the compiler the target platform chooses: selected here, on the attribute,
        # because `runtime` is an exec dependency (toolchains/mojo_versions.bzl).
        kwargs["runtime"] = by_mojo(
            _by_os("komira//tools/build/toolchains:mojo_runtime", "komira//tools/build/toolchains/darwin:mojo_runtime"),
            _by_os("komira//tools/build/toolchains:mojo_runtime_next", "komira//tools/build/toolchains/darwin:mojo_runtime_next"),
        )
    if "data" in kwargs:
        kwargs["data"] = _dylib_data(kwargs["data"])
    _python_binding_test(**_interpreter(_platform(_pinned_python(kwargs))))

def _oracle_macro(**kwargs):
    # An oracle computes its answer on linux whatever the target platform.
    if "exec_compatible_with" not in kwargs:
        kwargs["exec_compatible_with"] = LINUX_X86_64
    _python_oracle(**kwargs)

def _proto_macro(**kwargs):
    if "exec_compatible_with" not in kwargs:
        kwargs["exec_compatible_with"] = LINUX_X86_64
    _python_proto(**kwargs)

# Each rule and macro a BUCK file calls declares its package's doc_tree
# (tools/build/lint/doc_tree.bzl), so no BUCK file names one.
python_dist = declares_docs(_dist_macro)
python_wheel = declares_docs(_wheel_macro)
python_source_package = declares_docs(_source_package_macro)
py_test = declares_docs(_py_test_macro)
python_binding_test = declares_docs(_binding_test_macro)
python_oracle = declares_docs(_oracle_macro)
python_proto = declares_docs(_proto_macro)
