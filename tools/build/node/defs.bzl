"""Hermetic Node.js for tests: `node_dist`, `npm_package`, `node_test`,
`esbuild_bundle` and `c_shared_lib` (README.md).

`node_dist` unpacks a sha256-pinned Node.js release archive (linux-x64) into
a directory holding `bin/node`, `include/node` (the Node-API headers) and the
licence, and fails unless that `node` runs and reports the pinned version.
`npm_package` unpacks one sha256-pinned npm tarball after checking its
registry integrity (`sha512-<base64>`) and the top-level `name` and `version`
of its `package.json`, which the pinned `node` parses. `node_test` runs one script with the pinned `node` as a build
action; its output exists only if the script passed, so building the target
is running the test. `esbuild_bundle` bundles an entry module, its sibling
sources and npm packages into one file with the pinned esbuild.
`c_shared_lib` builds C sources into a shared library with the pinned zig:
symbols it does not define (a Node-API addon's `napi_*`) stay undefined, and
the program that loads it resolves them.

`node` runs with `LD_LIBRARY_PATH` naming the dist's `native_libs` (the C++
runtime it links, from the pinned conda-forge packages) and an environment of
`LC_ALL=C`, `TZ=UTC0`, `HOME` and `TMPDIR` in the action's scratch directory,
and nothing else (`env -i`): no `NODE_OPTIONS`, no `NODE_PATH`. esbuild runs
with an empty environment.

Every action runs under the pinned busybox, on the linux x86_64 execution
platform (the macros set `exec_compatible_with`). Sources an action reads are
copied under buck-out first: a source file's path differs between a standalone
checkout and a repository mounting komira as a cell, and so would the action's
digest.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:test_runtime.bzl", "data_map")
load("@komira//tools/build/mojo:toolchain.bzl", "busybox_sh")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/platforms:table.bzl", "row")

NodeDistInfo = provider(
    doc = "An unpacked Node.js: its root directory (`bin/node`, `include/node`) and the libraries `node` loads beyond glibc.",
    fields = {
        "root": provider_field(Artifact),
        "version": provider_field(str),
        # A directory whose `lib/` holds libstdc++.so.6 and libgcc_s.so.1.
        "native_libs": provider_field(Artifact),
    },
)

NpmPackageInfo = provider(
    doc = "An unpacked npm package and the closure of its deps, by package name.",
    fields = {
        "name": provider_field(str),
        "version": provider_field(str),
        # {package name: (version, unpacked directory)}, this package included.
        "closure": provider_field(dict),
    },
)

# Busybox's applets on PATH, a private scratch directory $T, and `abs`, which
# makes a path absolute (the scripts `cd` or hand paths to programs that do).
_PRELUDE = """
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
"""

def _out(dep):
    return dep[DefaultInfo].default_outputs[0]

def _closure(where, deps):
    """{package name: (version, directory)} over `deps` and theirs; a package at two versions fails analysis."""
    closure = {}
    for d in deps:
        for k, v in d[NpmPackageInfo].closure.items():
            if k in closure and closure[k][0] != v[0]:
                fail("{}: {} is pinned at {} and at {} in its deps".format(where, k, closure[k][0], v[0]))
            closure[k] = v
    return closure

# ---- node_dist ---------------------------------------------------------------

# Keeps bin/node, include/node and LICENSE of the archive's top directory (npm,
# npx, corepack and their lib/node_modules are left out: no action installs
# with them), then runs that node, which must print v<version>.
_DIST_SCRIPT = _PRELUDE + """
ARCHIVE="$1"; OUT="$2"; TOP="$3"; WANT="$4"; LIBS=$(abs "$5")
mkdir -p "$T/x"
tar -xzf "$ARCHIVE" -C "$T/x"
if [ ! -x "$T/x/$TOP/bin/node" ] || [ ! -f "$T/x/$TOP/include/node/node_api.h" ]; then
    echo "node_dist: $ARCHIVE holds no $TOP/bin/node or $TOP/include/node/node_api.h" >&2
    exit 2
fi
mkdir -p "$OUT/bin" "$OUT/include"
mv "$T/x/$TOP/bin/node" "$OUT/bin/node"
mv "$T/x/$TOP/include/node" "$OUT/include/node"
mv "$T/x/$TOP/LICENSE" "$OUT/LICENSE"
GOT=$(env -i LD_LIBRARY_PATH="$LIBS/lib" "$OUT/bin/node" --version) || {
    echo "node_dist: $OUT/bin/node does not run" >&2
    exit 2
}
if [ "$GOT" != "v$WANT" ]; then
    echo "node_dist: the node in $ARCHIVE is $GOT, the pin says v$WANT" >&2
    exit 2
fi
rm -rf "$T"
"""

def _node_dist_impl(ctx):
    out = ctx.actions.declare_output("node", dir = True)
    libs = _out(ctx.attrs.native_libs)
    ctx.actions.run(
        busybox_sh(_out(ctx.attrs._busybox), _DIST_SCRIPT, _out(ctx.attrs.archive), out.as_output(), ctx.attrs.top, ctx.attrs.version, libs),
        category = "node_dist",
    )
    return [
        DefaultInfo(
            default_output = out,
            sub_targets = {"include": [DefaultInfo(default_output = out.project("include/node"))]},
        ),
        NodeDistInfo(root = out, version = ctx.attrs.version, native_libs = libs),
    ]

_node_dist = rule(
    impl = _node_dist_impl,
    doc = "A Node.js release archive (`.tar.gz`, linux-x64) reduced to `bin/node`, `include/node` and `LICENSE`; fails unless that `node` runs and prints `v<version>`. The sub-target `[include]` is the Node-API header directory.",
    attrs = {
        # A pinned_file holding the `.tar.gz`.
        "archive": attrs.dep(),
        # A directory whose lib/ holds the libraries node links beyond glibc.
        "native_libs": attrs.dep(),
        # The archive's single top directory.
        "top": attrs.string(),
        "version": attrs.string(),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)

# ---- npm_package -------------------------------------------------------------

# Reads package.json with JSON.parse, as npm does, and requires its top-level
# `name` and `version` to be the pinned strings: a nested key, another type
# (`"version": 1`) or a missing key is refused. argv: the file, the text that
# starts the error, the name, the version.
_PACKAGE_JSON_JS = """
const [file, where, name, version] = process.argv.slice(1);
const top = JSON.parse(require('fs').readFileSync(file, 'utf8'));
for (const [key, want] of [['name', name], ['version', version]]) {
    if (top[key] !== want) {
        console.error(`${where} does not state "${key}":"${want}" at its top level; its top-level "${key}" is ${JSON.stringify(top[key]) ?? 'absent'}`);
        process.exit(1);
    }
}
"""

# Checks the tarball's sha512 against the integrity, unpacks its `package/`
# directory, checks the name and version its package.json states (with the
# pinned node and _PACKAGE_JSON_JS; under `sh -e` its failure fails the
# action) and, with an executable named, that it runs and prints the version.
_NPM_SCRIPT = _PRELUDE + """
TGZ="$1"; OUT="$2"; NAME="$3"; VERSION="$4"; SRI="$5"; EXE="$6"; NODE=$(abs "$7"); LIBS=$(abs "$8"); JS="$9"
case "$SRI" in
    sha512-?*) ;;
    *) echo "npm_package: $NAME: integrity $SRI is not sha512-<base64>" >&2; exit 2 ;;
esac
WANT=$(printf '%s' "${SRI#sha512-}" | base64 -d | od -An -v -tx1 | tr -d ' \\n')
GOT=$(sha512sum "$TGZ" | cut -d ' ' -f 1)
if [ "$GOT" != "$WANT" ]; then
    echo "npm_package: $NAME: the sha512 of $TGZ is $GOT; the pinned integrity $SRI is $WANT" >&2
    exit 2
fi
mkdir -p "$T/x"
tar -xzf "$TGZ" -C "$T/x"
if [ ! -f "$T/x/package/package.json" ]; then
    echo "npm_package: $NAME: $TGZ holds no package/package.json" >&2
    exit 2
fi
env -i LD_LIBRARY_PATH="$LIBS/lib" "$NODE/bin/node" -e "$JS" "$T/x/package/package.json" "npm_package: $NAME: package.json of $TGZ" "$NAME" "$VERSION"
mv "$T/x/package" "$OUT"
if [ "$EXE" != "-" ]; then
    GOT=$(env -i "$OUT/$EXE" --version) || { echo "npm_package: $NAME: $EXE does not run" >&2; exit 2; }
    if [ "$GOT" != "$VERSION" ]; then
        echo "npm_package: $NAME: $EXE --version prints $GOT, the pin says $VERSION" >&2
        exit 2
    fi
fi
rm -rf "$T"
"""

def _npm_package_impl(ctx):
    if ctx.attrs.exe == "":
        fail("{}: exe is empty: name the package's executable, or leave exe out".format(ctx.label.raw_target()))
    out = ctx.actions.declare_output("package", dir = True)
    dist = ctx.attrs._node[NodeDistInfo]
    ctx.actions.run(
        busybox_sh(
            _out(ctx.attrs._busybox),
            _NPM_SCRIPT,
            _out(ctx.attrs.tarball),
            out.as_output(),
            ctx.attrs.package,
            ctx.attrs.version,
            ctx.attrs.integrity,
            ctx.attrs.exe or "-",
            dist.root,
            dist.native_libs,
            _PACKAGE_JSON_JS,
        ),
        category = "npm_package",
    )
    closure = _closure(str(ctx.label.raw_target()), ctx.attrs.deps)
    if ctx.attrs.package in closure:
        fail("{}: {} is in its own deps".format(ctx.label.raw_target(), ctx.attrs.package))
    closure[ctx.attrs.package] = (ctx.attrs.version, out)
    return [
        DefaultInfo(default_output = out),
        NpmPackageInfo(name = ctx.attrs.package, version = ctx.attrs.version, closure = closure),
    ]

_npm_package = rule(
    impl = _npm_package_impl,
    doc = "One npm tarball's `package/` directory, unpacked after its sha512 is checked against `integrity` (the registry's `dist.integrity`); fails unless its package.json's top-level `name` and `version` are `package` and `version` (parsed by the pinned `node`), and, with `exe`, unless that file of the package runs and prints `version`. `deps` are the packages it imports.",
    attrs = {
        "deps": attrs.list(attrs.dep(providers = [NpmPackageInfo]), default = []),
        # A path in the package of an executable whose `--version` is `version`.
        "exe": attrs.option(attrs.string(), default = None),
        "integrity": attrs.string(),
        # The npm package name, scope included (`@esbuild/linux-x64`).
        "package": attrs.string(),
        # A pinned_file holding the `.tgz`.
        "tarball": attrs.dep(),
        "version": attrs.string(),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        "_node": attrs.exec_dep(providers = [NodeDistInfo], default = "komira//third_party/node:node"),
    },
)

# ---- node_test ---------------------------------------------------------------

# Runs node on the staged script. With `expect` "pass" the script must exit
# 0; with "fail" it must exit non-zero with the expected text on stderr.
_TEST_SCRIPT = _PRELUDE + """
NODE=$(abs "$1"); LIBS=$(abs "$2"); OUT=$(abs "$3"); SCRIPT="$(abs "$4")/$5"; EXPECT="$6"; ERROR="$7"; shift 7
mkdir -p "$T/home" "$T/tmp"
run() {
    env -i LC_ALL=C TZ=UTC0 HOME="$T/home" TMPDIR="$T/tmp" LD_LIBRARY_PATH="$LIBS/lib" "$NODE/bin/node" "$SCRIPT" "$@"
}
if [ "$EXPECT" = pass ]; then
    run "$@"
else
    if run "$@" 2> "$T/stderr"; then
        echo "node_test: $SCRIPT exited 0; it was expected to fail with: $ERROR" >&2
        exit 1
    fi
    if ! grep -qF -- "$ERROR" "$T/stderr"; then
        cat "$T/stderr" >&2
        echo "node_test: $SCRIPT failed, but its stderr does not hold: $ERROR" >&2
        exit 1
    fi
fi
: > "$OUT"
rm -rf "$T"
"""

def _node_test_impl(ctx):
    dist = ctx.attrs.node[NodeDistInfo]
    where = str(ctx.label.raw_target())
    if ctx.attrs.expect_error == "":
        fail("{}: expect_error is empty: name the text the script must print on stderr, or leave expect_error out".format(where))
    staged = {ctx.attrs.src.short_path: ctx.attrs.src}
    for s in ctx.attrs.srcs:
        if s.short_path in staged:
            fail("{}: {} is listed twice".format(where, s.short_path))
        staged[s.short_path] = s
    for dest, a in data_map(ctx, where + ": data", ctx.attrs.data).items():
        if dest in staged:
            fail("{}: data destination {} is also a source".format(where, dest))
        staged[dest] = a
    for k, v in _closure(where, ctx.attrs.deps).items():
        if "node_modules/" + k in staged:
            fail("{}: data destination node_modules/{} is also a package of deps".format(where, k))
        staged["node_modules/" + k] = v[1]
    root = ctx.actions.copied_dir(ctx.label.name + ".srcs", staged)
    out = ctx.actions.declare_output(ctx.label.name + ".pass")
    ctx.actions.run(
        busybox_sh(
            _out(ctx.attrs._busybox),
            _TEST_SCRIPT,
            dist.root,
            dist.native_libs,
            out.as_output(),
            # The staged directory, not a projection of the script in it: a
            # projection would bring only the script to the worker.
            root,
            ctx.attrs.src.short_path,
            "pass" if ctx.attrs.expect_error == None else "fail",
            ctx.attrs.expect_error if ctx.attrs.expect_error != None else "-",
            ctx.attrs.args,
        ),
        category = "node_test",
    )
    return [DefaultInfo(default_output = out)]

_node_test = rule(
    impl = _node_test_impl,
    doc = "Runs `src` with the pinned `node` as a build action; the output (`<name>.pass`) exists only if it passed: exit 0, or, with `expect_error`, a non-zero exit whose stderr holds that text. `srcs` are staged next to `src` at their package paths, `data` ({dest: source}) at `dest`, and the closure of the npm packages in `deps` under `node_modules/<package>`, where node resolves a bare import from the script; `args` are the script's arguments.",
    attrs = {
        "args": attrs.list(attrs.arg(), default = []),
        "data": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "deps": attrs.list(attrs.dep(providers = [NpmPackageInfo]), default = []),
        "expect_error": attrs.option(attrs.string(), default = None),
        "node": attrs.exec_dep(providers = [NodeDistInfo], default = "komira//third_party/node:node"),
        "src": attrs.source(),
        "srcs": attrs.list(attrs.source(), default = []),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)

# ---- esbuild_bundle ----------------------------------------------------------

# Runs esbuild from the staged directory, so the bundle's path comments are
# paths in it (`main.mjs`, `node_modules/<package>/...`).
_BUNDLE_SCRIPT = _PRELUDE + """
ESBUILD=$(abs "$1"); DIR=$(abs "$2"); ENTRY="$3"; OUT=$(abs "$4"); FORMAT="$5"
cd "$DIR"
env -i "$ESBUILD" "$ENTRY" --bundle --platform=node "--format=$FORMAT" "--outfile=$OUT" --log-level=warning
rm -rf "$T"
"""

def _esbuild_bundle_impl(ctx):
    where = str(ctx.label.raw_target())
    staged = {ctx.attrs.entry.short_path: ctx.attrs.entry}
    for s in ctx.attrs.srcs:
        if s.short_path in staged:
            fail("{}: {} is listed twice".format(where, s.short_path))
        staged[s.short_path] = s
    for k, v in _closure(where, ctx.attrs.deps).items():
        staged["node_modules/" + k] = v[1]
    root = ctx.actions.copied_dir(ctx.label.name + ".srcs", staged)
    esbuild = ctx.attrs.esbuild[NpmPackageInfo]
    exe = cmd_args(esbuild.closure[esbuild.name][1], format = "{}/bin/esbuild")
    out = ctx.actions.declare_output(ctx.attrs.out or ctx.label.name + ".js")
    ctx.actions.run(
        busybox_sh(_out(ctx.attrs._busybox), _BUNDLE_SCRIPT, exe, root, ctx.attrs.entry.short_path, out.as_output(), ctx.attrs.format),
        category = "esbuild_bundle",
    )
    return [DefaultInfo(default_output = out)]

_esbuild_bundle = rule(
    impl = _esbuild_bundle_impl,
    doc = "`entry` bundled by the pinned esbuild (`--bundle --platform=node`) into one file (`out`, default `<name>.js`) in `format` (`cjs` or `esm`). `srcs` (JavaScript or TypeScript) are staged next to `entry` at their package paths, the closure of the npm packages in `deps` under `node_modules/<package>`; an import of anything else fails the build.",
    attrs = {
        "deps": attrs.list(attrs.dep(providers = [NpmPackageInfo]), default = []),
        "entry": attrs.source(),
        "esbuild": attrs.exec_dep(providers = [NpmPackageInfo], default = "komira//third_party/node:esbuild_linux-x64"),
        "format": attrs.enum(["cjs", "esm"], default = "cjs"),
        "out": attrs.option(attrs.string(), default = None),
        "srcs": attrs.list(attrs.source(), default = []),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)

# ---- c_shared_lib ------------------------------------------------------------

_SHARED_SCRIPT = _PRELUDE + """
ZIG=$(abs "$1"); OUT=$(abs "$2"); TRIPLE="$3"; shift 3
mkdir -p "$T/zig-global" "$T/zig-local" "$T/home"
ZIG_GLOBAL_CACHE_DIR="$T/zig-global"; ZIG_LOCAL_CACHE_DIR="$T/zig-local"; HOME="$T/home"
export ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR HOME
"$ZIG/zig" cc -target "$TRIPLE" -shared -fPIC -O2 -fvisibility=hidden -Wall -Werror -Wl,-z,undefs -o "$OUT" "$@"
rm -rf "$T"
"""

def _c_shared_lib_impl(ctx):
    staged = ctx.actions.copied_dir(ctx.label.name + ".srcs", {s.short_path: s for s in ctx.attrs.srcs + ctx.attrs.headers})
    out = ctx.actions.declare_output(ctx.attrs.out or "lib{}.so".format(ctx.label.name))
    args = [cmd_args(staged, format = "-I{}")]
    for d in ctx.attrs.include_dirs:
        args.append(cmd_args(_out(d), format = "-I{}"))
    args.extend(ctx.attrs.copts)
    for s in ctx.attrs.srcs:
        args.append(staged.project(s.short_path))
    ctx.actions.run(
        busybox_sh(_out(ctx.attrs._busybox), _SHARED_SCRIPT, _out(ctx.attrs._zig), out.as_output(), ctx.attrs.zig_triple, args),
        category = "c_shared_lib",
    )
    return [DefaultInfo(default_output = out)]

_c_shared_lib = rule(
    impl = _c_shared_lib_impl,
    doc = "C `srcs` compiled and linked by the pinned zig (`zig cc -shared -fPIC -O2 -fvisibility=hidden -Wall -Werror`) for `zig_triple` into one shared library (`out`, default `lib<name>.so`). Symbols it does not define stay undefined (`-z undefs`) for the loading program to resolve; only symbols marked with default visibility are exported. `headers` are staged with the sources (`-I` their directory); each of `include_dirs` (a directory output) is an `-I`.",
    attrs = {
        "copts": attrs.list(attrs.string(), default = []),
        "headers": attrs.list(attrs.source(), default = []),
        "include_dirs": attrs.list(attrs.dep(), default = []),
        "out": attrs.option(attrs.string(), default = None),
        "srcs": attrs.list(attrs.source()),
        "zig_triple": attrs.string(),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        "_zig": attrs.exec_dep(default = "komira//tools/build/toolchains:zig"),
    },
)

def _linux(kwargs):
    if "exec_compatible_with" not in kwargs:
        kwargs["exec_compatible_with"] = LINUX_X86_64
    return kwargs

def _dist_macro(**kwargs):
    _node_dist(**_linux(kwargs))

def _npm_macro(**kwargs):
    _npm_package(**_linux(kwargs))

def _test_macro(**kwargs):
    _node_test(**_linux(kwargs))

def _bundle_macro(**kwargs):
    _esbuild_bundle(**_linux(kwargs))

def _shared_macro(**kwargs):
    # The linux x86_64 row's triple: the glibc floor every link of that
    # platform targets.
    if "zig_triple" not in kwargs:
        kwargs["zig_triple"] = row("linux-x86_64")["zig_triple"]
    _c_shared_lib(**_linux(kwargs))

# Each rule and macro a BUCK file calls declares its package's doc_tree
# (tools/build/lint/doc_tree.bzl), so no BUCK file names one.
node_dist = declares_docs(_dist_macro)
npm_package = declares_docs(_npm_macro)
node_test = declares_docs(_test_macro)
esbuild_bundle = declares_docs(_bundle_macro)
c_shared_lib = declares_docs(_shared_macro)
