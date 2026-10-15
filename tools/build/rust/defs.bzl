"""Rust rules for Buck2: rust_library, rust_binary, rust_test, crates_io_library.

Every compile runs the pinned rustc from `toolchains//:rust` through
`rustc_launch` (tools/build/rust/rustc_launch.zig), which links through zig (see that file). Nothing is
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
load("@komira//tools/build/mojo:run_check.bzl", "run_check_validation")
load("@komira//tools/build/rerun:rerun.bzl", "RERUN_ATTRS", "rerun_env", "rerun_info")
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
    # The gate (tools/build/run): `gate rust` runs one rust_test in a build
    # action.
    "gate": provider_field(typing.Any),
})

RustCrateInfo = provider(fields = {
    "crate_name": provider_field(str),
    # libC.rlib, or libC.so for a proc-macro.
    "lib": provider_field(typing.Any),
    # This crate's library and every library it depends on, without
    # duplicates. A list, not a transitive set: a transitive set's type is
    # per loading cell, and crates are used across cells.
    "closure": provider_field(list),
    # Native archives (`native_deps`) of this crate and of every crate it
    # depends on, without duplicates: linked into each binary or test that
    # links the crate, as `cargo:rustc-link-lib` of a `-sys` crate is.
    "natives": provider_field(list, default = []),
})

# A rust_test: the `.passed` marker its run writes. Only a passing run writes
# it; `tests = [...]` on rust_library and
# rust_binary takes these markers as inputs of the published artifact.
RustTestInfo = provider(fields = {
    "marker": provider_field(typing.Any),
})

# ---- toolchain ---------------------------------------------------------------

def _rust_sysroot_impl(ctx):
    out = ctx.actions.declare_output("sysroot", dir = True)
    # Keeps only what compiling needs: the rustc driver, the libraries it
    # loads (its own, and `libs`: the non-glibc libraries those need), and
    # the standard library for the one target. A Zig program does it
    # (tools/build/rust/rust_sysroot.zig); no shell runs.
    ctx.actions.run(
        cmd_args(
            ctx.attrs._tool[RunInfo],
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
        # A directory whose lib/ holds shared libraries rustc's own need
        # beyond glibc (conda_libs); copied into the sysroot's lib/.
        "libs": attrs.dep(),
        "rust_std": attrs.dep(),
        "rustc": attrs.dep(),
        "triple": attrs.string(),
        "version": attrs.string(),
        "_tool": attrs.exec_dep(default = "komira//tools/build/rust:rust_sysroot"),
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
            wrapper = ctx.attrs._launcher[DefaultInfo].default_outputs[0],
            run_check = ctx.attrs._run_check[DefaultInfo].default_outputs[0],
            gate = ctx.attrs._gate[DefaultInfo].default_outputs[0],
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
        "_gate": attrs.exec_dep(default = "komira//tools/build/run:gate"),
        "_run_check": attrs.dep(default = "komira//tools/build/mojo:run_check.sh"),
        # The lint of the scripts the Rust rules run: a validation (see
        # tools/build/lint/defs.bzl), not an input of any action.
        "_script_lint": attrs.list(attrs.dep(), default = [
            "komira//tools/build/lint:shell_lint",
            "komira//tools/build/mojo:shell_lint",
        ]),
        # The compile launcher (tools/build/rust/rustc_launch.zig; no shell).
        "_launcher": attrs.exec_dep(default = "komira//tools/build/rust:rustc_launch"),
    },
)

# ---- compiling ---------------------------------------------------------------

def _crate_name(ctx):
    name = ctx.attrs.crate_name or ctx.label.name.replace("-", "_")
    if not regex_match("^[A-Za-z_][A-Za-z0-9_]*$", name):
        fail("{}: crate name `{}` is not a Rust identifier; set `crate_name`".format(ctx.label, name))
    return name

# Variables the compile launcher (rustc_launch.zig) sets or clears itself: an
# `env` naming one would be silently overridden, so it is refused.
_RESERVED_ENV = ["BUCK_SCRATCH_PATH", "HOME", "LD_LIBRARY_PATH", "LD_PRELOAD", "PATH", "RUSTC_BOOTSTRAP", "RUSTFLAGS", "TMPDIR", "XDG_CACHE_HOME", "ZIG_GLOBAL_CACHE_DIR", "ZIG_LOCAL_CACHE_DIR"]

def _rustc_env(ctx):
    """`env`, checked: the variables rustc sees (`env!("CARGO_PKG_VERSION")`)."""
    for k in ctx.attrs.env:
        if not regex_match("^[A-Za-z_][A-Za-z0-9_]*$", k):
            fail("{}: env name `{}` is not a variable name".format(ctx.label.raw_target(), k))
        if k in _RESERVED_ENV:
            fail("{}: env `{}` is set by the compile wrapper and cannot be overridden".format(ctx.label.raw_target(), k))
    return ctx.attrs.env

def _patch_spec(ctx):
    """The crate_patch spec (json) for `patch`, checked at analysis."""
    where = str(ctx.label.raw_target())
    p = ctx.attrs.patch
    for k in p:
        if k not in ["add", "copy", "sub"]:
            fail("{}: patch has no `{}`; its keys are copy, sub and add".format(where, k))
    for c in p.get("copy", []):
        if type(c) != "string":
            fail("{}: patch.copy holds paths (strings), not {}".format(where, repr(c)))
    for e in p.get("sub", []):
        for k in e:
            if k not in ["file", "from", "to", "count"]:
                fail("{}: a patch.sub entry has no `{}` (file, from, to, count)".format(where, k))
        for k in ["file", "from", "to"]:
            if type(e.get(k)) != "string":
                fail("{}: every patch.sub entry needs a string `{}`: {}".format(where, k, repr(e)))
        if e["from"] == "":
            fail("{}: a patch.sub entry has an empty `from`".format(where))
    for e in p.get("add", []):
        for k in e:
            if k not in ["file", "content"]:
                fail("{}: a patch.add entry has no `{}` (file, content)".format(where, k))
        for k in ["file", "content"]:
            if type(e.get(k)) != "string":
                fail("{}: every patch.add entry needs a string `{}`: {}".format(where, k, repr(e)))
    return json.encode(p)

def _patched(ctx, d):
    """`d` (a directory of sources) edited by `patch`, or `d` when there is none."""
    if ctx.attrs.patch == None:
        return d
    spec = ctx.actions.write("patch.json", _patch_spec(ctx))
    out = ctx.actions.declare_output("patched", dir = True)
    ctx.actions.run(
        cmd_args(ctx.attrs._patch_tool[RunInfo], spec, d, out.as_output()),
        category = "crate_patch",
    )
    return out

def _root(ctx):
    """(root source argument, hidden inputs, path remap args)."""
    if ctx.attrs.src_dir != None:
        d = ctx.attrs.src_dir[DefaultInfo].default_outputs[0]
        d = _patched(ctx, d)
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
    d = _patched(ctx, d)
    remap = [cmd_args(d, format = "--remap-path-prefix={}=" + ctx.label.cell + "/" + ctx.label.package)]
    return d.project(roots[0].short_path), [d], remap

def _externs(deps, renamed = {}):
    """(--extern args of `deps` and `renamed`, their library closure without duplicates).

    A dependency in `renamed` is reached under its alias (`--extern=alias=lib`),
    not under its crate name; the aliases are taken in sorted order.
    """
    externs = []
    closure = []
    seen = {}
    pairs = [(d, None) for d in deps] + [(renamed[a], a) for a in sorted(renamed)]
    for d, alias in pairs:
        info = d[RustCrateInfo]
        externs.append(cmd_args(info.lib, format = "--extern=" + (alias or info.crate_name) + "={}"))
        for lib in info.closure:
            if lib not in seen:
                seen[lib] = True
                closure.append(lib)
    return externs, closure

def _natives(ctx):
    """The native archives `ctx`'s crate links: its own `native_deps`, then its dependencies' (renamed ones in alias order), each once."""
    out = []
    for n in ctx.attrs.native_deps:
        a = n[DefaultInfo].default_outputs[0]
        if a not in out:
            out.append(a)
    for d in ctx.attrs.deps + [ctx.attrs.renamed_deps[k] for k in sorted(ctx.attrs.renamed_deps)]:
        for a in d[RustCrateInfo].natives:
            if a not in out:
                out.append(a)
    return out

def _rustc(ctx, crate, crate_type, root, hidden, remap, externs, closure, metadata, out, identifier):
    tc = ctx.attrs.toolchain[RustToolchainInfo]
    # Linking: only a bin or a test is linked, and only it takes native_deps.
    natives = [cmd_args(n, format = "-Clink-arg={}") for n in _natives(ctx)] if crate_type in ["bin", "test"] else []
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
        # Cargo gives a proc-macro crate the compiler's own proc_macro crate.
        ["--extern=proc_macro"] if crate_type == "proc-macro" and getattr(ctx.attrs, "proc_macro_extern", False) else [],
        [cmd_args(lib, format = "-Ldependency={}", parent = 1) for lib in closure],
        natives,
        ctx.attrs.rustc_flags,
        "-o",
        out.as_output(),
        root,
        hidden = hidden,
    )
    ctx.actions.run(
        cmd_args(
            tc.wrapper,
            tc.busybox,
            tc.sysroot,
            tc.zig,
            tc.cc_target,
            out.as_output(),
            "--",
            rustc_args,
        ),
        # Only an `env` the target sets reaches the action, so a target
        # without one has the action it always had.
        env = _rustc_env(ctx),
        category = "rustc",
        identifier = identifier,
    )

def _metadata(ctx):
    return str(ctx.label.raw_target()).replace(":", "_").replace("/", "_")

def _compile(ctx, crate_type, out):
    """Compiles the target's own crate to `out`; returns its deps' closure."""
    root, hidden, remap = _root(ctx)
    externs, closure = _externs(ctx.attrs.deps, ctx.attrs.renamed_deps)
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
    # Environment of the rustc action: what `env!("CARGO_PKG_VERSION")` and
    # `option_env!` read at compile time. Not the environment of a test run.
    "env": attrs.dict(attrs.string(), attrs.string(), default = {}),
    "features": attrs.list(attrs.string(), default = []),
    # Native archives (a cxx_library's `[static-pic]`, say) linked into a
    # binary or test, and into the test crates of a library's `test_srcs`:
    # `-Clink-arg=<archive>`, after the objects that need them. A library's
    # are also linked into every binary or test that depends on it.
    "native_deps": attrs.list(attrs.dep(), default = []),
    "opt_level": attrs.string(default = "3"),
    # Edits to the sources before rustc reads them, where Cargo would run a
    # build script (README, "Cargo crates"): a dict with `copy` (entries of
    # the source tree to keep; all when empty), `sub` (exact text
    # substitutions {file, from, to, count}) and `add` (generated files
    # {file, content}).
    "patch": attrs.option(attrs.dict(attrs.string(), attrs.any()), default = None),
    # Dependencies a crate names differently from their crate name
    # (`package = "http"` in Cargo): alias -> dependency, `--extern=alias=lib`.
    "renamed_deps": attrs.dict(attrs.string(), attrs.dep(providers = [RustCrateInfo]), default = {}),
    "rustc_flags": attrs.list(attrs.string(), default = []),
    # A directory holding the crate's sources (an unpacked registry crate).
    "src_dir": attrs.option(attrs.dep(), default = None),
    # What paths inside `src_dir` are recorded as, e.g. `anyhow-1.0.102`.
    "src_dir_label": attrs.option(attrs.string(), default = None),
    "srcs": attrs.list(attrs.source(), default = []),
    "toolchain": attrs.toolchain_dep(default = "toolchains//:rust", providers = [RustToolchainInfo]),
    "_patch_tool": attrs.exec_dep(default = "komira//tools/build/rust:crate_patch"),
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
    return cmd_args(tc.gate, "rust", "--busybox", tc.busybox, "--label", label, "--test", exe, "--marker", marker_arg, "--timeout-s", str(timeout_s))

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

    ctx.actions.run(runner(marker.as_output()), env = rerun_env(ctx), category = "rust_gated_test", identifier = ctx.label.name)
    return [
        # Building the target runs the tests. `[bin]` is the harness itself
        # (a test executable, not a shippable artifact).
        DefaultInfo(default_output = marker, sub_targets = {"bin": [DefaultInfo(default_output = exe)]}),
        RustTestInfo(marker = marker),
        # `buck2 test` runs the same runner and timeout over the same
        # harness, outside the build (it writes no marker). So `buck2 test` of
        # a rust_test, or of a rust_library/rust_binary naming it in `tests`,
        # runs its tests rather than reporting NO TESTS RAN.
        ExternalRunnerTestInfo(type = "custom", command = [runner("/dev/null")], env = rerun_env(ctx), labels = ctx.attrs.labels),
        rerun_info(ctx),
    ]

rust_test_rule = rule(
    impl = _test_impl,
    attrs = _COMMON_ATTRS | RERUN_ATTRS | {
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
    externs, _ = _externs(ctx.attrs.deps, ctx.attrs.renamed_deps)
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
            env = rerun_env(ctx),
            category = "rust_gated_test",
            identifier = ident,
        )
        markers.append(marker)
    return markers

def _library_impl(ctx):
    tc = ctx.attrs.toolchain[RustToolchainInfo]
    crate = _crate_name(ctx)
    if ctx.attrs.proc_macro_extern and not ctx.attrs.proc_macro:
        fail("{}: proc_macro_extern is for a proc-macro crate; set proc_macro = True".format(ctx.label.raw_target()))
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
            natives = _natives(ctx),
        ),
        rerun_info(ctx),
    ]

rust_library_rule = rule(
    impl = _library_impl,
    attrs = _COMMON_ATTRS | _WELD_ATTRS | RERUN_ATTRS | {
        "proc_macro": attrs.bool(default = False),
        # With `proc_macro`, `--extern=proc_macro`: the compiler's proc_macro
        # crate in the extern prelude, as Cargo gives it to every proc-macro
        # crate (edition 2018 and later need it to name `proc_macro::..`
        # without `extern crate`). Opt-in so that a proc-macro crate that
        # compiled before keeps its action.
        "proc_macro_extern": attrs.bool(default = False),
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
    validation = []
    if ctx.attrs.expected_stdout != None:
        # Runs the binary in a remote action and fails unless its stdout is
        # exactly `expected_stdout`: `[run_check]`, and a validation of the
        # binary (tools/build/mojo/run_check.bzl).
        out = ctx.actions.declare_output(ctx.label.name + ".stdout")
        expected = ctx.actions.write(ctx.label.name + ".expected", ctx.attrs.expected_stdout)
        ctx.actions.run(
            cmd_args(tc.busybox, "sh", tc.run_check, tc.busybox, exe, out.as_output(), expected),
            env = rerun_env(ctx),
            category = "rust_run_check",
        )
        sub_targets["run_check"] = [DefaultInfo(default_output = out)]
        validation = run_check_validation(ctx, out, ctx.attrs.expected_stdout)
    return [
        DefaultInfo(default_output = exe, sub_targets = sub_targets),
        RunInfo(args = cmd_args(exe)),
        rerun_info(ctx),
    ] + validation

rust_binary_rule = rule(
    impl = _binary_impl,
    attrs = _COMMON_ATTRS | _WELD_ATTRS | RERUN_ATTRS | {
        "expected_stdout": attrs.option(attrs.string(), default = None),
    },
)

# ---- the weld's marker list -------------------------------------------------
#
# A library or binary with `tests` or `test_srcs` is published behind the
# markers of its tests (`[tests]`). A weld that drops one still builds green,
# its test simply not run, so building the target cannot show it. This check
# reads the target's `[tests]` sub-target at analysis, the marker list _gate
# returns, and fails unless it is exactly `markers` (each a marker's path in
# its target's outputs: `<test>.passed` of a rust_test,
# `test_srcs/<crate>.passed` of an external test). It reads that list, not
# the publishing copy action's inputs: a _gate that kept a marker in the list
# but dropped it from the action's hidden inputs passes here.

def _rust_weld_check_impl(ctx):
    tests = ctx.attrs.target[DefaultInfo].sub_targets.get("tests")
    got = sorted([m.short_path for m in tests[DefaultInfo].default_outputs]) if tests else []
    want = sorted(ctx.attrs.markers)
    if got != want:
        fail("rust_weld_check {}: the [tests] markers of {} are {}, not {}".format(
            ctx.label.raw_target(),
            ctx.attrs.target.label.raw_target(),
            got,
            want,
        ))
    return [DefaultInfo()]

rust_weld_check_rule = rule(
    impl = _rust_weld_check_impl,
    doc = "Fails analysis unless the `[tests]` sub-target of `target` (a rust_library or rust_binary), the marker list its rule hands the publishing copy action, is exactly `markers`. It reads that list, not the action's inputs.",
    attrs = {
        "markers": attrs.list(attrs.string()),
        "target": attrs.dep(),
    },
)

# ---- registry crates ---------------------------------------------------------

def _crate_source_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    if "/" in ctx.attrs.prefix:
        fail("{}: prefix {} is not one directory name".format(ctx.label, repr(ctx.attrs.prefix)))
    # The crate unpacks into a directory named `prefix`, so the output is
    # declared with that name and the busybox tar applet (no shell) extracts
    # into the output's parent; a wrong `prefix` leaves the output missing.
    out = ctx.actions.declare_output(ctx.attrs.prefix, dir = True)
    ctx.actions.run(
        cmd_args(bb, "tar", "-xzf", ctx.attrs.archive[DefaultInfo].default_outputs[0], "-C", cmd_args(out.as_output(), parent = 1)),
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
rust_weld_check = declares_docs(rust_weld_check_rule)
