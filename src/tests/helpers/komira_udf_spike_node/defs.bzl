"""`node_bench`: runs a script with the pinned node in one build action and
keeps its stdout, one JSON object, as the target's output.

`node_test` keeps only a pass marker; the numbers of a bench are the point,
so this rule stages the same way (the script, its `srcs`, `data` and the
closure of the npm packages in `deps`, in one directory) and runs the same
`node` with the same empty environment, then keeps the output. The last
argument of the script is the run id: the one line of the `run_id` file. The
run id file is an input of this action only, so bumping it re-runs the bench
and nothing else; every welded test keeps its action key and stays a cache
hit. Numbers from a cache hit are the numbers of the run that wrote them, and
their `run_id` says which.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:test_runtime.bzl", "data_map")
load("@komira//tools/build/mojo:toolchain.bzl", "busybox_sh")
load("@komira//tools/build/node:defs.bzl", "NodeDistInfo", "NpmPackageInfo", "node_test")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

_SCRIPT = """
BB="$1"; shift
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.komira_action" ;;
    /*) T="$BUCK_SCRATCH_PATH/komira" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/komira" ;;
esac
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"; export PATH
abs() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
NODE=$(abs "$1"); LIBS=$(abs "$2"); OUT=$(abs "$3"); ROOT=$(abs "$4"); SCRIPT="$5"; RUN_ID_FILE="$6"; shift 6
mkdir -p "$T/home" "$T/tmp"
RUN_ID=$(head -n 1 "$RUN_ID_FILE")
env -i LC_ALL=C TZ=UTC0 HOME="$T/home" TMPDIR="$T/tmp" LD_LIBRARY_PATH="$LIBS/lib" "$NODE/bin/node" "$ROOT/$SCRIPT" "$@" "$RUN_ID" > "$OUT"
rm -rf "$T"
"""

def _out(dep):
    return dep[DefaultInfo].default_outputs[0]

def _node_bench_impl(ctx):
    where = str(ctx.label.raw_target())
    dist = ctx.attrs.node[NodeDistInfo]
    staged = {ctx.attrs.src.short_path: ctx.attrs.src}
    for s in ctx.attrs.srcs:
        staged[s.short_path] = s
    for dest, a in data_map(ctx, where + ": data", ctx.attrs.data).items():
        staged[dest] = a
    for dep in ctx.attrs.deps:
        for name, v in dep[NpmPackageInfo].closure.items():
            staged["node_modules/" + name] = v[1]
    root = ctx.actions.copied_dir(ctx.label.name + ".srcs", staged)
    out = ctx.actions.declare_output(ctx.label.name + ".json")
    ctx.actions.run(
        busybox_sh(
            _out(ctx.attrs._busybox),
            _SCRIPT,
            dist.root,
            dist.native_libs,
            out.as_output(),
            root,
            ctx.attrs.src.short_path,
            ctx.attrs.run_id,
            ctx.attrs.args,
        ),
        category = "node_bench",
    )
    return [DefaultInfo(default_output = out)]

_node_bench = rule(
    impl = _node_bench_impl,
    doc = "Runs `src` with the pinned node as a build action and keeps its stdout (one JSON object) as the output; the script's last argument is the first line of the `run_id` file.",
    attrs = {
        "args": attrs.list(attrs.arg(), default = [], doc = "Arguments before the run id."),
        "data": attrs.dict(attrs.string(), attrs.source(), default = {}, doc = "{path in the staged directory: file or directory}."),
        "deps": attrs.list(attrs.dep(providers = [NpmPackageInfo]), default = [], doc = "npm packages, staged under node_modules."),
        "node": attrs.exec_dep(providers = [NodeDistInfo], default = "komira//third_party/node:node"),
        "run_id": attrs.source(doc = "A file whose first line names the run."),
        "src": attrs.source(doc = "The script."),
        "srcs": attrs.list(attrs.source(), default = [], doc = "Files staged next to the script."),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)

def _bench_macro(**kwargs):
    if "exec_compatible_with" not in kwargs:
        kwargs["exec_compatible_with"] = LINUX_X86_64
    _node_bench(**kwargs)

node_bench = declares_docs(_bench_macro)

def udf_node_test(name, src, data, args = []):
    """A node_test of `tests/<src>` with the helpers beside it, the base
    image's apache-arrow under node_modules, and `data` staged (BUCK)."""
    node_test(
        name = name,
        src = "tests/" + src,
        srcs = ["tests/helpers.js"],
        args = args,
        data = data,
        deps = ["//third_party/node:apache-arrow"],
    )

def udf_node_log(name, src, data, args = []):
    """The stdout of a test script, kept as a file (a node_test keeps only its
    pass marker): the same staging as udf_node_test, run by node_bench."""
    node_bench(
        name = name,
        src = "tests/" + src,
        srcs = ["tests/helpers.js"],
        args = args,
        data = data,
        deps = ["//third_party/node:apache-arrow"],
        run_id = "bench/run_id",
    )
