"""Rust rules for Buck2: rust_library, rust_binary, rust_test, crates_io_library.

Every compile runs the pinned rustc from `toolchains//:rust` through
`rustc_wrapper.sh`, which links through zig (see that file). Nothing is
taken from the worker except glibc: the sysroot carries rustc's own
libraries and, from pinned packages, the other libraries they need
(libgcc_s, zlib), in the directory their run path names.

The execution platform and the target platform are the same os and cpu
(linux x86_64), so a proc-macro crate is an ordinary dependency: it is
compiled once, as a shared library for this platform, and loaded by rustc
when a dependent crate is compiled.

Output layout of a crate `C` compiled by target `T`:

    T/C/libC.rlib          library (or T/C/libC.so for a proc-macro)
    T/<name>               executable (rust_binary)

Each library sits alone in its directory; the transitive closure reaches
rustc as one `-Ldependency=<dir>` per crate, and direct dependencies as
`--extern <crate>=<file>`.
"""

load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/mojo:download.bzl", "pinned_file")
load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

RustToolchainInfo = provider(fields = {
    "busybox": provider_field(typing.Any),
    # Directory: bin/rustc, lib/ (rustc's own libraries) and
    # lib/rustlib/<triple>/lib (the standard library).
    "sysroot": provider_field(typing.Any),
    # Directory: the unpacked zig distribution, the link driver.
    "zig": provider_field(typing.Any),
    # zig -target triple for link steps.
    "cc_target": provider_field(str),
    "wrapper": provider_field(typing.Any),
    "run_check": provider_field(typing.Any),
    # Runs one rust_test in a build action (test_runner.sh).
    "test_runner": provider_field(typing.Any),
})

RustCrateInfo = provider(fields = {
    "crate_name": provider_field(str),
    # libC.rlib, or libC.so for a proc-macro.
    "lib": provider_field(typing.Any),
    # This crate's library and every library it depends on, without
    # duplicates. A list, not a transitive set: a transitive set's type is
    # per loading cell, and crates are used across cells.
    "closure": provider_field(list),
})

# A rust_test: the `.passed` marker its run writes. Only a passing run writes
# it; `tests = [...]` on rust_library and
# rust_binary takes these markers as inputs of the published artifact.
RustTestInfo = provider(fields = {
    "marker": provider_field(typing.Any),
})

_PRELUDE = """
BB="$1"; shift
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
# Private scratch. A remote action has its working directory to itself; a
# local one runs in the checkout root next to every other local action, so
# it takes the per-action scratch directory buck2 names in BUCK_SCRATCH_PATH.
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.komira_action" ;;
    /*) T="$BUCK_SCRATCH_PATH/komira" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/komira" ;;
esac
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"; export PATH
"""

def _busybox_sh(busybox, script, *args):
    return cmd_args(busybox, "sh", "-euc", _PRELUDE + script, "sh", busybox, *args)

# ---- toolchain ---------------------------------------------------------------

def _rust_sysroot_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output("sysroot", dir = True)
    # Keeps only what compiling needs: the rustc driver, the libraries it
    # loads (its own, and `libs`: the non-glibc libraries those need), and
    # the standard library for the one target.
    script = """
RUSTC="$1"; STD="$2"; OUT="$3"; TRIPLE="$4"; VERSION="$5"; LIBS="$6"
X="$OUT.x"
mkdir -p "$X" "$OUT/bin" "$OUT/lib/rustlib/$TRIPLE"
tar -xJf "$RUSTC" -C "$X"
tar -xJf "$STD" -C "$X"
R="$X/rustc-$VERSION-$TRIPLE/rustc"
S="$X/rust-std-$VERSION-$TRIPLE/rust-std-$TRIPLE/lib/rustlib/$TRIPLE/lib"
mv "$R/bin/rustc" "$OUT/bin/rustc"
for f in $R/lib/*.so*; do mv "$f" "$OUT/lib/"; done
for f in $LIBS/lib/*; do
    if [ -e "$OUT/lib/${f##*/}" ]; then
        echo "rust_sysroot: REFUSING: ${f##*/} is both a rustc library and in libs" >&2
        exit 2
    fi
    cp "$f" "$OUT/lib/"
done
mv "$S" "$OUT/lib/rustlib/$TRIPLE/lib"
rm -rf "$X"
test -x "$OUT/bin/rustc"
ls "$OUT/lib/rustlib/$TRIPLE/lib/" | grep -q '^libstd-'
rm -rf "$T"
"""
    ctx.actions.run(
        _busybox_sh(
            bb,
            script,
            ctx.attrs.rustc[DefaultInfo].default_outputs[0],
            ctx.attrs.rust_std[DefaultInfo].default_outputs[0],
            out.as_output(),
            ctx.attrs.triple,
            ctx.attrs.version,
            ctx.attrs.libs[DefaultInfo].default_outputs[0],
        ),
        category = "rust_sysroot",
    )
    return [DefaultInfo(default_output = out)]

rust_sysroot_rule = rule(
    impl = _rust_sysroot_impl,
    attrs = {
        "busybox": attrs.dep(),
        # A directory whose lib/ holds shared libraries rustc's own need
        # beyond glibc (conda_libs); copied into the sysroot's lib/.
        "libs": attrs.dep(),
        "rust_std": attrs.dep(),
        "rustc": attrs.dep(),
        "triple": attrs.string(),
        "version": attrs.string(),
    },
)

def _rust_toolchain_impl(ctx):
    return [
        DefaultInfo(),
        RustToolchainInfo(
            busybox = ctx.attrs.busybox[DefaultInfo].default_outputs[0],
            sysroot = ctx.attrs.sysroot[DefaultInfo].default_outputs[0],
            zig = ctx.attrs.zig[DefaultInfo].default_outputs[0],
            cc_target = ctx.attrs.cc_target,
            wrapper = ctx.attrs._wrapper[DefaultInfo].default_outputs[0],
            run_check = ctx.attrs._run_check[DefaultInfo].default_outputs[0],
            test_runner = ctx.attrs._test_runner[DefaultInfo].default_outputs[0],
        ),
    ]

rust_toolchain = rule(
    impl = _rust_toolchain_impl,
    is_toolchain_rule = True,
    attrs = {
        "busybox": attrs.exec_dep(),
        "cc_target": attrs.string(),
        "sysroot": attrs.exec_dep(),
        "zig": attrs.exec_dep(),
        "_run_check": attrs.dep(default = "komira//tools/build/mojo:run_check.sh"),
        # The lint of the scripts the Rust rules run: a validation (see
        # tools/build/lint/defs.bzl), not an input of any action.
        "_script_lint": attrs.list(attrs.dep(), default = [
            "komira//tools/build/lint:shell_lint",
            "komira//tools/build/mojo:shell_lint",
            "komira//tools/build/rust:shell_lint",
        ]),
        "_test_runner": attrs.dep(default = "komira//tools/build/rust:test_runner.sh"),
        "_wrapper": attrs.dep(default = "komira//tools/build/rust:rustc_wrapper.sh"),
    },
)

# ---- compiling ---------------------------------------------------------------

def _crate_name(ctx):
    name = ctx.attrs.crate_name or ctx.label.name.replace("-", "_")
    if not regex_match("^[A-Za-z_][A-Za-z0-9_]*$", name):
        fail("{}: crate name `{}` is not a Rust identifier; set `crate_name`".format(ctx.label, name))
    return name

def _root(ctx):
    """(root source argument, hidden inputs, path remap args)."""
    if ctx.attrs.src_dir != None:
        d = ctx.attrs.src_dir[DefaultInfo].default_outputs[0]
        remap = []
        if ctx.attrs.src_dir_label:
            # Paths recorded in the output (panic locations, file!()) name
            # the crate, not the output directory it was unpacked into.
            remap = [cmd_args(d, format = "--remap-path-prefix={}=" + ctx.attrs.src_dir_label)]
        return d.project(ctx.attrs.crate_root), [d], remap
    roots = [s for s in ctx.attrs.srcs if s.short_path == ctx.attrs.crate_root or s.short_path.endswith("/" + ctx.attrs.crate_root)]
    if len(roots) != 1:
        fail("{}: crate_root `{}` must name exactly one of srcs".format(ctx.label, ctx.attrs.crate_root))

    # Sources are copied into buck-out, keyed by their path in the package.
    # Read in place, their path would start with where the cell is mounted
    # (`tools/...` standalone, `komira/tools/...` in a repository that has
    # komira as a submodule), and every compile of komira's own crates would
    # get a different action digest in each. The copy's path has the cell's
    # name, not its location. Paths recorded in the output (panic locations,
    # file!()) read <cell>/<package>/<file>, not the copy's path.
    d = ctx.actions.copied_dir("__srcs__", {s.short_path: s for s in ctx.attrs.srcs})
    remap = [cmd_args(d, format = "--remap-path-prefix={}=" + ctx.label.cell + "/" + ctx.label.package)]
    return d.project(roots[0].short_path), [d], remap

def _externs(deps):
    """(--extern args of `deps`, their library closure without duplicates)."""
    externs = []
    closure = []
    seen = {}
    for d in deps:
        info = d[RustCrateInfo]
        externs.append(cmd_args(info.lib, format = "--extern=" + info.crate_name + "={}"))
        for lib in info.closure:
            if lib not in seen:
                seen[lib] = True
                closure.append(lib)
    return externs, closure

def _rustc(ctx, crate, crate_type, root, hidden, remap, externs, closure, metadata, out, identifier):
    tc = ctx.attrs.toolchain[RustToolchainInfo]
    rustc_args = cmd_args(
        "--crate-name=" + crate,
        # `test`: a libtest harness over the crate's #[test] functions.
        "--test" if crate_type == "test" else "--crate-type=" + crate_type,
        "--edition=" + ctx.attrs.edition,
        "-Copt-level=" + ctx.attrs.opt_level,
        "-Cdebuginfo=0",
        "-Cstrip=debuginfo",
        # Distinguishes symbols of two crates with the same name.
        "-Cmetadata=" + metadata,
        ["--cfg=feature=\"{}\"".format(f) for f in ctx.attrs.features],
        ["--cfg=" + c for c in ctx.attrs.cfgs],
        ["--cap-lints=allow"] if ctx.attrs.cap_lints else [],
        remap,
        externs,
        [cmd_args(lib, format = "-Ldependency={}", parent = 1) for lib in closure],
        ctx.attrs.rustc_flags,
        "-o",
        out.as_output(),
        root,
        hidden = hidden,
    )
    ctx.actions.run(
        cmd_args(
            tc.busybox,
            "sh",
            tc.wrapper,
            tc.busybox,
            tc.sysroot,
            tc.zig,
            tc.cc_target,
            out.as_output(),
            "--",
            rustc_args,
        ),
        category = "rustc",
        identifier = identifier,
    )

def _metadata(ctx):
    return str(ctx.label.raw_target()).replace(":", "_").replace("/", "_")

def _compile(ctx, crate_type, out):
    """Compiles the target's own crate to `out`; returns its deps' closure."""
    root, hidden, remap = _root(ctx)
    externs, closure = _externs(ctx.attrs.deps)
    crate = _crate_name(ctx)
    _rustc(ctx, crate, crate_type, root, hidden, remap, externs, closure, _metadata(ctx), out, crate)
    return closure

_COMMON_ATTRS = {
    # Set for crates downloaded from a registry, whose warnings are not ours.
    "cap_lints": attrs.bool(default = False),
    "cfgs": attrs.list(attrs.string(), default = []),
    "crate_name": attrs.option(attrs.string(), default = None),
    # Path of the crate root: relative to the package among `srcs`, or inside
    # `src_dir`.
    "crate_root": attrs.string(),
    "deps": attrs.list(attrs.dep(providers = [RustCrateInfo]), default = []),
    "edition": attrs.string(default = "2021"),
    "features": attrs.list(attrs.string(), default = []),
    "opt_level": attrs.string(default = "3"),
    "rustc_flags": attrs.list(attrs.string(), default = []),
    # A directory holding the crate's sources (an unpacked registry crate).
    "src_dir": attrs.option(attrs.dep(), default = None),
    # What paths inside `src_dir` are recorded as, e.g. `anyhow-1.0.102`.
    "src_dir_label": attrs.option(attrs.string(), default = None),
    "srcs": attrs.list(attrs.source(), default = []),
    "toolchain": attrs.toolchain_dep(default = "toolchains//:rust", providers = [RustToolchainInfo]),
}

# ---- the test weld -----------------------------------------------------------
#
# The same weld mojo_library makes (tools/build/mojo/defs.bzl): a rust_test is
# compiled with `rustc --test` and RUN as a build action that writes a `.passed`
# marker. `tests = [...]` on rust_library or rust_binary compiles the artifact
# UNGATED, then publishes it through one copy action that takes every marker
# as a hidden input. The compile and the tests run in parallel; the published
# library (what `deps` links against) or binary (what RunInfo runs) cannot
# exist unless each test passed. With no `tests`, nothing changes: the compile
# writes the published path directly, as before.
#
# A crate's inline #[test]s are its unit tests: a rust_test over the SAME
# `srcs` and `crate_root`, which does not depend on the library, gates it. A
# rust_test that depends on the library cannot gate that library (buck2
# refuses the cycle). A library's external tests (`tests/*.rs`, Cargo's
# integration tests) are `test_srcs` instead: compiled inside rust_library
# against the UNGATED rlib, as mojo_library compiles its test_srcs against
# the ungated package, and run by the same runner; their markers join the
# gate with those of `tests`.

_DEFAULT_TEST_TIMEOUT_S = 600

def _runner(tc, label, exe, marker_arg, timeout_s):
    return cmd_args(tc.busybox, "sh", tc.test_runner, tc.busybox, label, exe, marker_arg, str(timeout_s))

def _gate(ctx, tc, ungated, public, markers):
    """Publishes `ungated` as `public` once every marker in `markers` exists."""
    ctx.actions.run(
        cmd_args(tc.busybox, "cp", ungated, public.as_output(), hidden = markers),
        category = "rust_gate_join",
    )
    return markers

def _tests_sub_target(markers):
    return {"tests": [DefaultInfo(default_outputs = markers)]}

def _test_impl(ctx):
    tc = ctx.attrs.toolchain[RustToolchainInfo]
    exe = ctx.actions.declare_output("bin/" + ctx.label.name)
    _compile(ctx, "test", exe)
    marker = ctx.actions.declare_output(ctx.label.name + ".passed")
    if ctx.attrs.test_timeout_s < 1:
        fail("{}: test_timeout_s must be at least 1, not {}".format(ctx.label.raw_target(), ctx.attrs.test_timeout_s))

    def runner(marker_arg):
        return _runner(tc, str(ctx.label.raw_target()), exe, marker_arg, ctx.attrs.test_timeout_s)

    ctx.actions.run(runner(marker.as_output()), category = "rust_gated_test", identifier = ctx.label.name)
    return [
        # Building the target runs the tests. `[bin]` is the harness itself
        # (a test executable, not a shippable artifact).
        DefaultInfo(default_output = marker, sub_targets = {"bin": [DefaultInfo(default_output = exe)]}),
        RustTestInfo(marker = marker),
        # `buck2 test` runs the same runner and timeout over the same
        # harness, outside the build (it writes no marker). So `buck2 test` of
        # a rust_test, or of a rust_library/rust_binary naming it in `tests`,
        # runs its tests rather than reporting NO TESTS RAN.
        ExternalRunnerTestInfo(type = "custom", command = [runner("/dev/null")], labels = ctx.attrs.labels),
    ]

rust_test_rule = rule(
    impl = _test_impl,
    attrs = _COMMON_ATTRS | {
        "labels": attrs.list(attrs.string(), default = []),
        # Each harness invocation (the list, then the run) is killed after
        # this many seconds, and the run is NO VERDICT (exit 142).
        "test_timeout_s": attrs.int(default = _DEFAULT_TEST_TIMEOUT_S),
    },
)

_WELD_ATTRS = {
    # rust_test targets whose passing runs this artifact is published behind.
    "welded_tests": attrs.list(attrs.dep(providers = [RustTestInfo]), default = []),
}

def _test_src_roots(ctx):
    """The `test_srcs` that are test crates: `tests/<name>.rs`, as Cargo has it.

    Any other file of `test_srcs` must sit under `tests/` (a module such as
    `tests/common/mod.rs`, reached by `mod common;`) and is not a crate.
    """
    roots = []
    for s in ctx.attrs.test_srcs:
        p = s.short_path
        if not p.startswith("tests/"):
            fail("{}: test_srcs `{}` is not under tests/".format(ctx.label.raw_target(), p))
        rest = p[len("tests/"):]
        if "/" in rest:
            continue
        if not rest.endswith(".rs"):
            fail("{}: test_srcs `{}` is not a .rs file".format(ctx.label.raw_target(), p))
        name = rest[:-len(".rs")].replace("-", "_")
        if not regex_match("^[A-Za-z_][A-Za-z0-9_]*$", name):
            fail("{}: test_srcs `{}` does not name a Rust identifier".format(ctx.label.raw_target(), p))
        roots.append((s, name))
    if not roots:
        fail("{}: test_srcs has no test crate (a file tests/<name>.rs)".format(ctx.label.raw_target()))
    return roots

def _external_tests(ctx, tc, crate, ungated, deps_closure):
    """Compiles and runs each `test_srcs` crate against `ungated`; returns the markers.

    A test crate sees the library and the library's `deps`, as a Cargo
    integration test does, and the library's features, cfgs and flags.
    """
    d = ctx.actions.copied_dir("__test_srcs__", {s.short_path: s for s in ctx.attrs.test_srcs})
    remap = [cmd_args(d, format = "--remap-path-prefix={}=" + ctx.label.cell + "/" + ctx.label.package)]
    externs, _ = _externs(ctx.attrs.deps)
    externs = externs + [cmd_args(ungated, format = "--extern=" + crate + "={}")]
    closure = [ungated] + deps_closure
    label = str(ctx.label.raw_target())
    markers = []
    for src, name in _test_src_roots(ctx):
        exe = ctx.actions.declare_output("test_srcs/bin/" + name)
        ident = "test_srcs/" + name
        metadata = _metadata(ctx) + "_test_srcs_" + name
        _rustc(ctx, name, "test", d.project(src.short_path), [d], remap, externs, closure, metadata, exe, ident)
        marker = ctx.actions.declare_output("test_srcs/" + name + ".passed")
        ctx.actions.run(
            _runner(tc, label + " " + src.short_path, exe, marker.as_output(), _DEFAULT_TEST_TIMEOUT_S),
            category = "rust_gated_test",
            identifier = ident,
        )
        markers.append(marker)
    return markers

def _library_impl(ctx):
    tc = ctx.attrs.toolchain[RustToolchainInfo]
    crate = _crate_name(ctx)
    ext = "so" if ctx.attrs.proc_macro else "rlib"
    path = "{}/lib{}.{}".format(crate, crate, ext)
    lib = ctx.actions.declare_output(path)
    sub_targets = {}
    if ctx.attrs.welded_tests or ctx.attrs.test_srcs:
        # Alone in its own directory too: -Ldependency names a library's directory.
        ungated = ctx.actions.declare_output("ungated/" + path)
        deps_closure = _compile(ctx, "proc-macro" if ctx.attrs.proc_macro else "rlib", ungated)
        markers = [t[RustTestInfo].marker for t in ctx.attrs.welded_tests]
        if ctx.attrs.test_srcs:
            markers += _external_tests(ctx, tc, crate, ungated, deps_closure)
        sub_targets = _tests_sub_target(_gate(ctx, tc, ungated, lib, markers))
    else:
        deps_closure = _compile(ctx, "proc-macro" if ctx.attrs.proc_macro else "rlib", lib)
    return [
        DefaultInfo(default_output = lib, sub_targets = sub_targets),
        RustCrateInfo(
            crate_name = crate,
            lib = lib,
            closure = [lib] + deps_closure,
        ),
    ]

rust_library_rule = rule(
    impl = _library_impl,
    attrs = _COMMON_ATTRS | _WELD_ATTRS | {
        "proc_macro": attrs.bool(default = False),
        # External tests: each `tests/<name>.rs` is a test crate compiled
        # against the ungated library and run; the library is published
        # behind them. Other files under tests/ are modules they use.
        "test_srcs": attrs.list(attrs.source(), default = []),
    },
)

def _binary_impl(ctx):
    tc = ctx.attrs.toolchain[RustToolchainInfo]
    exe = ctx.actions.declare_output(ctx.label.name)
    sub_targets = {}
    if ctx.attrs.welded_tests:
        ungated = ctx.actions.declare_output("ungated/" + ctx.label.name)
        _compile(ctx, "bin", ungated)
        markers = [t[RustTestInfo].marker for t in ctx.attrs.welded_tests]
        sub_targets = _tests_sub_target(_gate(ctx, tc, ungated, exe, markers))
    else:
        _compile(ctx, "bin", exe)
    if ctx.attrs.expected_stdout != None:
        # Runs the binary in a remote action and fails unless its stdout is
        # exactly `expected_stdout`.
        out = ctx.actions.declare_output(ctx.label.name + ".stdout")
        expected = ctx.actions.write(ctx.label.name + ".expected", ctx.attrs.expected_stdout)
        ctx.actions.run(
            cmd_args(tc.busybox, "sh", tc.run_check, tc.busybox, exe, out.as_output(), expected),
            category = "rust_run_check",
        )
        sub_targets["run_check"] = [DefaultInfo(default_output = out)]
    return [
        DefaultInfo(default_output = exe, sub_targets = sub_targets),
        RunInfo(args = cmd_args(exe)),
    ]

rust_binary_rule = rule(
    impl = _binary_impl,
    attrs = _COMMON_ATTRS | _WELD_ATTRS | {
        "expected_stdout": attrs.option(attrs.string(), default = None),
    },
)

# ---- registry crates ---------------------------------------------------------

def _crate_source_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(ctx.attrs.prefix, dir = True)
    script = """
mkdir -p "$2.x"
tar -xzf "$1" -C "$2.x"
mv "$2.x/$3" "$2"
rm -rf "$2.x" "$T"
test -f "$2/Cargo.toml"
"""
    ctx.actions.run(
        _busybox_sh(bb, script, ctx.attrs.archive[DefaultInfo].default_outputs[0], out.as_output(), ctx.attrs.prefix),
        category = "crate_unpack",
    )
    return [DefaultInfo(default_output = out)]

crate_source = rule(
    impl = _crate_source_impl,
    attrs = {
        "archive": attrs.dep(),
        "busybox": attrs.dep(),
        "prefix": attrs.string(),
    },
)

def crates_io_library(
        name,
        version,
        sha256,
        size,
        crate = None,
        crate_root = "src/lib.rs",
        busybox = "komira//tools/build/toolchains:busybox",
        visibility = ["PUBLIC"],
        **kwargs):
    """A crates.io crate, pinned by the sha256 and size (bytes) of its `.crate` file, compiled with rust_library.

    `crate` is the registry name (default `name`). Features and cfgs are
    stated explicitly: nothing is resolved and no build script runs, so a
    cfg that a crate's build.rs would emit for the pinned rustc is written
    here instead.
    """
    crate = crate or name
    prefix = "{}-{}".format(crate, version)
    pinned_file(
        name = name + ".crate",
        url = "https://static.crates.io/crates/{}/{}.crate".format(crate, prefix),
        sha256 = sha256,
        size_bytes = size,
    )
    crate_source(
        name = name + ".src",
        archive = ":{}.crate".format(name),
        busybox = busybox,
        prefix = prefix,
        exec_compatible_with = LINUX_X86_64,
    )
    rust_library(
        name = name,
        crate_name = crate.replace("-", "_"),
        src_dir = ":{}.src".format(name),
        src_dir_label = prefix,
        crate_root = crate_root,
        cap_lints = True,
        visibility = visibility,
        **kwargs
    )

def _welded(rule_fn):
    """`rule_fn`, taking `tests = [...]`: rust_test targets it is published behind.

    `tests` is buck2's own attribute (the targets `buck2 test` runs for this
    one), which carries labels only; the weld needs their markers, so the
    same list also reaches the rule as `welded_tests`.
    """
    def call(tests = [], **kwargs):
        if "welded_tests" in kwargs:
            fail("{}: pass `tests = [...]`, not `welded_tests`".format(kwargs.get("name", "")))
        return rule_fn(tests = tests, welded_tests = tests, **kwargs)
    return call

# Each rule and macro a BUCK file calls declares its package's doc_tree
# (tools/build/lint/doc_tree.bzl), so no BUCK file names one.
crates_io_library = declares_docs(crates_io_library)
rust_binary = declares_docs(_welded(rust_binary_rule))
rust_library = declares_docs(_welded(rust_library_rule))
rust_sysroot = declares_docs(rust_sysroot_rule)
rust_test = declares_docs(rust_test_rule)
