"""Two small rules for this package's runtime directory, and its layout.

`pyrt_files` stages the in-process Python runtime's adapter and fixture
modules (komira_udf_spike_python/pyrt/) that the worker runs user code
through. That package exports no target for them, so this rule takes them
from the staged data of one of its welded tests (`[tests][<test>]`, whose
other output is the test's root: share/pyrt/<file>).

`dist_native_libs` is the directory of shared libraries the pinned CPython's
wheels link beyond glibc (PythonDistInfo.native_libs); the worker loads them
before any extension module, as a py_test does.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/python:defs.bzl", "PythonDistInfo")

def _pyrt_files_impl(ctx):
    others = ctx.attrs.test[DefaultInfo].other_outputs
    if len(others) != 1:
        fail("{}: {} has {} other outputs; a welded test has one, its root".format(ctx.label, ctx.attrs.test.label, len(others)))
    root = others[0]
    out = ctx.actions.copied_dir("pyrt", {f: root.project("share/pyrt/" + f) for f in ctx.attrs.files})
    return [DefaultInfo(default_output = out)]

_pyrt_files = rule(
    impl = _pyrt_files_impl,
    doc = "A directory of files taken from share/pyrt/ of a welded Mojo test's staged root (the `[tests][<test>]` sub-target's other output).",
    attrs = {
        "files": attrs.list(attrs.string(), doc = "File names under share/pyrt/."),
        "test": attrs.dep(doc = "A `<library>[tests][<test>]` sub-target."),
    },
)

def _dist_native_libs_impl(ctx):
    libs = ctx.attrs.python[PythonDistInfo].native_libs
    if libs == None:
        fail("{}: {} has no native_libs".format(ctx.label, ctx.attrs.python.label))
    return [DefaultInfo(default_output = libs)]

_dist_native_libs = rule(
    impl = _dist_native_libs_impl,
    doc = "The native_libs directory of a python_dist (lib/<library>).",
    attrs = {
        "python": attrs.dep(providers = [PythonDistInfo]),
    },
)

_CODE_LAYER = """
set -eu
BB="$1"; IN="$2"; OUT="$3"
SHA=$("$BB" sha256sum "$IN/payload" | "$BB" cut -d ' ' -f 1)
"$BB" mkdir -p "$OUT/good" "$OUT/bad"
"$BB" cp "$IN/payload" "$OUT/good/$SHA"
"$BB" cp "$IN/payload_bad" "$OUT/bad/$SHA"
"$BB" cp "$IN/info.json" "$OUT/info.json"
"""

def _code_layer_impl(ctx):
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output("code", dir = True)
    ctx.actions.run(
        cmd_args(bb, "sh", "-c", _CODE_LAYER, "code_layer", bb, ctx.attrs.capture, out.as_output()),
        category = "code_layer",
    )
    return [DefaultInfo(default_output = out)]

_code_layer = rule(
    impl = _code_layer_impl,
    doc = "A VALUE capture's code objects named by their sha256, as a code layer holds them: good/<sha> (the payload), bad/<sha> (payload_bad under the payload's name) and info.json, from a directory holding payload, payload_bad and info.json.",
    attrs = {
        "capture": attrs.source(doc = "The capture's directory (make_closure.py's output)."),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)

# The pinned CPython ships its standard library without bytecode, and wheels
# never carry it, so every worker would compile each module it imports, on
# every start (hundreds of ms for numpy). A base image ships bytecode; this
# rule gives the worker's directories theirs: a copy compiled with
# unchecked-hash .pyc files, which the interpreter uses without comparing
# the source's mtime (staging does not keep it). A file that does not
# compile under the interpreter is left as source (compileall's status is
# not checked), as Python would compile it at import anyway.
_BYTECODE = """
set -eu
BB="$1"; PY="$2"; OUT="$3"; IN="$4"
"$BB" mkdir -p "$OUT"
"$BB" cp -RL "$IN/." "$OUT/"
"$BB" chmod -R u+w "$OUT"
"$PY" -I -S -m compileall -q -j 0 --invalidation-mode unchecked-hash "$OUT" > /dev/null 2>&1 || true
"""

def _bytecode_impl(ctx):
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    dist = ctx.attrs.python[PythonDistInfo]
    if (ctx.attrs.dir == None) == (len(ctx.attrs.srcs) == 0):
        fail("{}: set exactly one of dir and srcs".format(ctx.label))
    src = ctx.attrs.dir if ctx.attrs.dir != None else ctx.actions.symlinked_dir(ctx.label.name + ".in", ctx.attrs.srcs)
    out = ctx.actions.declare_output(ctx.label.name, dir = True)
    ctx.actions.run(
        cmd_args(
            bb,
            "sh",
            "-c",
            _BYTECODE,
            "bytecode",
            bb,
            cmd_args(dist.root, format = "{}/" + dist.exe),
            out.as_output(),
            src,
        ),
        category = "py_bytecode",
    )
    return [DefaultInfo(default_output = out)]

_bytecode = rule(
    impl = _bytecode_impl,
    doc = "A copy of `dir` (or of `srcs` staged as {dest: source}) with every module compiled by `python` into unchecked-hash .pyc files.",
    attrs = {
        "dir": attrs.option(attrs.source(), default = None, doc = "A directory to copy and compile."),
        "python": attrs.exec_dep(providers = [PythonDistInfo], default = "komira//third_party/python:cpython"),
        "srcs": attrs.dict(attrs.string(), attrs.source(), default = {}, doc = "{path: file or directory}."),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)

bytecode = declares_docs(_bytecode)
code_layer = declares_docs(_code_layer)
pyrt_files = declares_docs(_pyrt_files)
dist_native_libs = declares_docs(_dist_native_libs)


PYWORKER = {f: "pyworker/" + f for f in [
    "komira_udf_pyworker.py",
    "kudf_ipc.py",
    "udf_worker_fixtures.py",
    "udf_worker_np.py",
]}

def runtime_dir(variants, site = ":site_bc", extra = {}):
    """The directory a proxy build finds beside itself: pyworker_<variant>.so
    for each of `variants`, the CPython install as python/, its native
    libraries as native/, the in-process runtime's Python modules as pyrt/,
    the worker's as pyworker/, and the wheels' site/<wheel> directories, each
    compiled to bytecode (bytecode, above); then `extra`."""
    return {
        "native": ":native_libs",
        "pyrt": ":pyrt_bc",
        "python": ":python_bc",
        "pyworker": ":pyworker_bc",
        "site": site,
    } | {"pyworker_{}.so".format(v): ":pyworker_" + v for v in variants} | extra
