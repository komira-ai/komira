"""node_modules from a package-lock.json, and the node programs that run over it.

    npm_modules(name, lockfile, npm)      node_modules laid out from the lockfile
    tsc_check, jest_test, cdk_synth       a TypeScript check, a jest run and a
                                          `cdk synth` over a source tree
    node_tree_test, node_tree_build       any program of node_modules

`npm_modules` is the offline `npm ci --ignore-scripts`: every package of the
lockfile is a sha256-pinned download (kpin writes the pins, tools/build/kpin),
checked against the lockfile's sha512 integrity, unpacked by the pinned node
at the path the lockfile gives it, with `.bin` links and no install script.
The programs run from a copy of the sources next to a symlink to that tree,
with the environment of the other node rules (`env -i`, UTC, a scratch HOME)
and no network. README.md (this directory) is the contract.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/kpin:pins.bzl", "npm_kwargs")
load("@komira//tools/build/mojo:download.bzl", "pinned_file")
load("@komira//tools/build/mojo:test_runtime.bzl", "data_map")
load("@komira//tools/build/mojo:toolchain.bzl", "busybox_sh")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/rerun:rerun.bzl", "RERUN_ATTRS", "rerun_env", "rerun_info")
load(":defs.bzl", "NODE_PRELUDE", "NodeDistInfo")

NodeModulesInfo = provider(
    doc = "A laid-out node_modules directory.",
    fields = {"dir": provider_field(Artifact)},
)

def _out(dep):
    return dep[DefaultInfo].default_outputs[0]

# Runs one mode of node_tools.mjs with the pinned node. $T is the action's
# scratch directory; the program gets it as KOMIRA_SCRATCH, and busybox's
# applets are in $T/bin.
_TOOLS_SCRIPT = NODE_PRELUDE + """
abs() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
NODE=$(abs "$1"); LIBS=$(abs "$2"); TOOLS=$(abs "$3"); MODE="$4"; SPEC=$(abs "$5"); OUT=$(abs "$6")
mkdir -p "$T/home" "$T/tmp"
env -i LC_ALL=C TZ=UTC0 HOME="$T/home" TMPDIR="$T/tmp" LD_LIBRARY_PATH="$LIBS/lib" KOMIRA_SCRATCH="$T" "$NODE/bin/node" "$TOOLS" "$MODE" "$SPEC" "$OUT"
rm -rf "$T"
"""

def _tools_run(ctx, mode, spec, out, category):
    dist = ctx.attrs.node[NodeDistInfo]
    ctx.actions.run(
        busybox_sh(_out(ctx.attrs._busybox), _TOOLS_SCRIPT, dist.root, dist.native_libs, ctx.attrs._tools, mode, spec, out.as_output()),
        env = rerun_env(ctx),
        category = category,
    )

# ---- npm_modules ---------------------------------------------------------------

def _npm_modules_impl(ctx):
    where = str(ctx.label.raw_target())
    if sorted(ctx.attrs.tarballs.keys()) != sorted(ctx.attrs.sri512.keys()):
        fail("{}: tarballs and sri512 name different packages".format(where))
    spec = ctx.actions.write_json(
        "spec.json",
        {
            "lockfile": ctx.attrs.lockfile,
            "sri512": ctx.attrs.sri512,
            "tarballs": {k: _out(v) for k, v in ctx.attrs.tarballs.items()},
        },
        with_inputs = True,
    )
    out = ctx.actions.declare_output("node_modules", dir = True)
    _tools_run(ctx, "assemble", spec, out, "npm_modules")
    return [DefaultInfo(default_output = out), NodeModulesInfo(dir = out), rerun_info(ctx)]

_npm_modules = rule(
    impl = _npm_modules_impl,
    doc = "A `node_modules` directory laid out from `lockfile` (a lockfileVersion 3 package-lock.json) and `tarballs` ({`name@version`: a pinned .tgz}), the offline equivalent of `npm ci --ignore-scripts` for linux x86_64. Every tarball's sha512 must equal the lockfile's `integrity` (and `sri512`, the integrity of the pinned lock); each is unpacked at the path the lockfile gives it (nested node_modules included), its package.json must state the locked name and version, and `.bin` links are made for every package that has executables. Optional packages for another os or cpu (fsevents) are skipped; no install script runs. A lockfile package with no tarball, a changed byte or a mismatching name fails the target.",
    attrs = {
        "lockfile": attrs.source(),
        "node": attrs.exec_dep(providers = [NodeDistInfo], default = "komira//third_party/node:node"),
        "sri512": attrs.dict(attrs.string(), attrs.string()),
        "tarballs": attrs.dict(attrs.string(), attrs.dep()),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        "_tools": attrs.source(default = "komira//tools/build/node_tools:node_tools.mjs"),
    } | RERUN_ATTRS,
)

# ---- node_tree_run -------------------------------------------------------------

def _run_impl(ctx):
    where = str(ctx.label.raw_target())
    pkg = ctx.label.package
    staged = {}
    for s in ctx.attrs.srcs:
        if not s.is_source:
            fail("{}: {} is a build output; name it in data, {{dest: source}}".format(where, s))
        dest = pkg + "/" + s.short_path if pkg else s.short_path
        if dest in staged:
            fail("{}: {} is listed twice".format(where, dest))
        staged[dest] = s
    for dest, a in data_map(ctx, where + ": data", ctx.attrs.data).items():
        if dest in staged:
            fail("{}: data destination {} is also a source".format(where, dest))
        staged[dest] = a
    if ctx.attrs.out_dir != None and (ctx.attrs.out_dir == "" or ctx.attrs.out_dir.startswith("/") or ".." in ctx.attrs.out_dir.split("/")):
        fail("{}: out_dir {} must be a relative directory of the package".format(where, repr(ctx.attrs.out_dir)))
    tree = ctx.actions.copied_dir(ctx.label.name + ".tree", staged)
    spec = ctx.actions.write_json(
        "spec.json",
        {
            "args": ctx.attrs.args,
            "env": ctx.attrs.env,
            "modules": ctx.attrs.modules[NodeModulesInfo].dir,
            "outDir": ctx.attrs.out_dir,
            "package": pkg,
            "program": ctx.attrs.program,
            "tree": tree,
        },
        with_inputs = True,
    )
    if ctx.attrs.out_dir == None:
        out = ctx.actions.declare_output(ctx.label.name + ".pass")
    else:
        out = ctx.actions.declare_output(ctx.label.name, dir = True)
    _tools_run(ctx, "run", spec, out, "node_tree")
    return [DefaultInfo(default_output = out), rerun_info(ctx)]

_node_tree_run = rule(
    impl = _run_impl,
    doc = "Runs `program` (a path in the package, `node_modules/.bin/tsc`) with the pinned node and `args`, in a copy of `srcs` (staged at their paths in the cell) and `data` ({dest: source} from the cell root, build outputs allowed) with the `node_modules` of `modules` linked in as the package's own. The environment is `env -i` plus a scratch HOME, UTC, and `env`; there is no network. With `out_dir` the target is that directory of the package after the program passed; without it, the target's `<name>.pass` exists only if the program exited 0.",
    attrs = {
        "args": attrs.list(attrs.string(), default = []),
        "data": attrs.dict(attrs.string(), attrs.source(allow_directory = True), default = {}),
        "env": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "modules": attrs.dep(providers = [NodeModulesInfo]),
        "node": attrs.exec_dep(providers = [NodeDistInfo], default = "komira//third_party/node:node"),
        "out_dir": attrs.option(attrs.string(), default = None),
        "program": attrs.string(),
        "srcs": attrs.list(attrs.source(), default = []),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        "_tools": attrs.source(default = "komira//tools/build/node_tools:node_tools.mjs"),
    } | RERUN_ATTRS,
)

def _linux(kwargs):
    if "exec_compatible_with" not in kwargs:
        kwargs["exec_compatible_with"] = LINUX_X86_64
    return kwargs

# The target name of a key's download: `name@1.0.0` -> `name_at_1.0.0`, and
# a scope's slash is two underscores.
def _file_name(key):
    return "npm-" + key.replace("@", "_at_").replace("/", "__")

def _npm_modules_macro(name, lockfile, npm, tarballs = None, visibility = None, **kwargs):
    """`npm` is the `NPM` of a generated pins.lock.bzl (tools/build/kpin): one pinned download per entry unless `tarballs` ({key: label}) names the files."""
    files = {}
    for key in sorted(npm.keys()):
        if tarballs != None:
            if key not in tarballs:
                fail("npm_modules {}: tarballs has no {}".format(name, key))
            files[key] = tarballs[key]
        else:
            target = name + "." + _file_name(key)
            pinned_file(**npm_kwargs(npm, key, name = target, visibility = []))
            files[key] = ":" + target
    _npm_modules(
        name = name,
        lockfile = lockfile,
        sri512 = {k: npm[k]["sri512"] for k in npm},
        tarballs = files,
        visibility = visibility,
        **_linux(kwargs)
    )

def _tree_macro(name, program, **kwargs):
    _node_tree_run(name = name, program = program, **_linux(kwargs))

def _tsc_check(name, modules, srcs, data = {}, project = "tsconfig.json", **kwargs):
    """`tsc --noEmit -p <project>`: every type error fails the target."""
    _tree_macro(name, "node_modules/.bin/tsc", modules = modules, srcs = srcs, data = data, args = ["--noEmit", "-p", project], **kwargs)

def _tsc_build(name, modules, srcs, data = {}, project = "tsconfig.build.json", out_dir = "dist", **kwargs):
    """`tsc -p <project>`; the target is `out_dir`, which the project writes."""
    _tree_macro(name, "node_modules/.bin/tsc", modules = modules, srcs = srcs, data = data, args = ["-p", project], out_dir = out_dir, **kwargs)

def _jest_test(name, modules, srcs, data = {}, config = "jest.config.js", max_workers = 2, **kwargs):
    """`jest --ci --maxWorkers=<max_workers>` with its cache in the action's scratch copy and no watchman."""
    if max_workers < 1:
        fail("jest_test {}: max_workers must be at least 1".format(name))
    args = ["--ci", "--maxWorkers={}".format(max_workers), "--cacheDirectory=.jest-cache", "--watchman=false", "--config", config]
    _tree_macro(name, "node_modules/.bin/jest", modules = modules, srcs = srcs, data = data, args = args, **kwargs)

def _cdk_synth(name, modules, srcs, app, data = {}, context = {}, env = {}, **kwargs):
    """`cdk synth` of `app` (the command cdk.json holds, with `npx` replaced by `node node_modules/.bin/...`: there is no npx) with `context` as `-c key=value`, no version check, notices or telemetry, and no AWS or network."""
    args = ["synth", "--quiet", "--app", app, "--output", "cdk.out", "--no-version-reporting", "--no-notices"]
    for k in sorted(context.keys()):
        args += ["-c", "{}={}".format(k, context[k])]
    e = {"CDK_DISABLE_VERSION_CHECK": "1"} | env
    _tree_macro(name, "node_modules/.bin/cdk", modules = modules, srcs = srcs, data = data, args = args, env = e, **kwargs)

# Each rule and macro a BUCK file calls declares its package's doc_tree
# (tools/build/lint/doc_tree.bzl), so no BUCK file names one.
npm_modules = declares_docs(_npm_modules_macro)
node_tree_test = declares_docs(_tree_macro)
node_tree_build = declares_docs(_tree_macro)
tsc_check = declares_docs(_tsc_check)
tsc_build = declares_docs(_tsc_build)
jest_test = declares_docs(_jest_test)
cdk_synth = declares_docs(_cdk_synth)
