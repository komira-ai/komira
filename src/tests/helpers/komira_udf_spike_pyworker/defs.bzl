"""The rules of this package's runtime directory and its bench.

`dist_native_libs` is the directory of shared libraries the pinned CPython's
wheels link beyond glibc (PythonDistInfo.native_libs); the worker loads them
before any extension module, as a py_test does.

`code_layer` lays out a VALUE capture's committed payloads as a code layer
holds them; `bytecode` compiles a directory's modules; `udf_bench` runs the
bench program and keeps its output.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoRunnableInfo")
load("@komira//tools/build/python:defs.bzl", "PythonDistInfo")

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
"$BB" mkdir -p "$OUT/good" "$OUT/bad"
"$BB" gunzip -c "$IN/payload.gz" > "$OUT/payload"
SHA=$("$BB" sha256sum "$OUT/payload" | "$BB" cut -d ' ' -f 1)
"$BB" grep -q "$SHA" "$IN/info.json" || { echo "code_layer: the payload's sha256 $SHA is not the one info.json records" >&2; exit 1; }
"$BB" mv "$OUT/payload" "$OUT/good/$SHA"
"$BB" gunzip -c "$IN/payload_bad.gz" > "$OUT/bad/$SHA"
"$BB" cp "$IN/info.json" "$OUT/info.json"
"""

def _code_layer_impl(ctx):
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    src = ctx.actions.symlinked_dir(ctx.label.name + ".in", {
        "info.json": ctx.attrs.info,
        "payload.gz": ctx.attrs.payload,
        "payload_bad.gz": ctx.attrs.payload_bad,
    })
    out = ctx.actions.declare_output("code", dir = True)
    ctx.actions.run(
        cmd_args(bb, "sh", "-c", _CODE_LAYER, "code_layer", bb, src, out.as_output()),
        category = "code_layer",
    )
    return [DefaultInfo(default_output = out)]

_code_layer = rule(
    impl = _code_layer_impl,
    doc = "A VALUE capture's code objects named by their sha256, as a code layer holds them: good/<sha> (the payload), bad/<sha> (payload_bad under the payload's name) and info.json, from the committed gzip'd payloads; refuses a payload whose sha256 is not the one info.json records.",
    attrs = {
        "info": attrs.source(doc = "info.json: the payload's sha256 and sizes."),
        "payload": attrs.source(doc = "The payload, gzip'd."),
        "payload_bad": attrs.source(doc = "The payload with its last byte flipped, gzip'd."),
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
dist_native_libs = declares_docs(_dist_native_libs)


# The bench (udf_bench): the action stages `data` in one directory (the
# runtime library, the CPython install, the wheels, the Python modules),
# changes into it and runs the binary from its runnable directory with
# `args`, then the run id: the one line of the `run_id` file. The run id file
# is an input of this action only, so bumping it re-runs the bench and
# nothing else; every welded test keeps its action key and stays a cache
# hit. Numbers from a cache hit are the numbers of the run that wrote them,
# and their `run_id` says which.
_BENCH = """
set -eu
BB="$1"; BIN="$2"; DATA="$3"; OUT="$4"; RUN_ID_FILE="$5"; shift 5
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
case "$BIN" in /*) ;; *) BIN="$PWD/$BIN" ;; esac
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
RUN_ID=$("$BB" head -n 1 "$RUN_ID_FILE")
cd "$DATA"
"$BIN" "$@" "$RUN_ID" > "$OUT"
"""

def _out(dep):
    return dep[DefaultInfo].default_outputs[0]

def _udf_bench_impl(ctx):
    runnable = ctx.attrs.binary[MojoRunnableInfo]
    data = ctx.actions.symlinked_dir(ctx.label.name + ".data", ctx.attrs.data)
    out = ctx.actions.declare_output(ctx.label.name + ".json")
    ctx.actions.run(
        cmd_args(
            _out(ctx.attrs._busybox),
            "sh",
            "-c",
            _BENCH,
            "udf_bench",
            _out(ctx.attrs._busybox),
            cmd_args(runnable.run_dir.project(runnable.binary), hidden = runnable.run_dir),
            data,
            out.as_output(),
            ctx.attrs.run_id,
            ctx.attrs.args,
        ),
        category = "udf_bench",
    )
    return [DefaultInfo(default_output = out)]

_udf_bench = rule(
    impl = _udf_bench_impl,
    doc = "Runs a bench mojo_binary over a staged data directory and keeps its stdout (one JSON object) as the output, with the run id file's first line as the last argument.",
    attrs = {
        "args": attrs.list(attrs.string(), default = [], doc = "Arguments before the run id."),
        "binary": attrs.dep(providers = [MojoRunnableInfo], doc = "The bench program (a mojo_binary)."),
        "data": attrs.dict(attrs.string(), attrs.source(), default = {}, doc = "{path in the data directory: file or directory}; the program runs there."),
        "run_id": attrs.source(doc = "A file whose first line names the run."),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)

udf_bench = declares_docs(_udf_bench)

# The adapter and the shared cases' fixtures (pyrt/), and the worker and its
# own fixtures (pyworker/), as runtime_dir stages them.
PYRT = {f: "pyrt/" + f for f in [
    "komira_udf_pyrt.py",
    "udf_fixtures.py",
    "udf_np.py",
]}

PYWORKER = {f: "pyworker/" + f for f in [
    "komira_udf_pyworker.py",
    "kudf_ipc.py",
    "udf_worker_badimport.py",
    "udf_worker_fixtures.py",
    "udf_worker_np.py",
]}

def runtime_dir(variants, site = ":site_bc", extra = {}):
    """The directory a build of the runtime library finds beside itself:
    pyworker_<variant>.so for each of `variants`, the CPython install as
    python/, its native libraries as native/, the adapter and fixture
    modules as pyrt/, the worker's as pyworker/, and the wheels'
    site/<wheel> directories, each compiled to bytecode (bytecode, above);
    then `extra`."""
    return {
        "native": ":native_libs",
        "pyrt": ":pyrt_bc",
        "python": ":python_bc",
        "pyworker": ":pyworker_bc",
        "site": site,
    } | {"pyworker_{}.so".format(v): ":pyworker_" + v for v in variants} | extra
