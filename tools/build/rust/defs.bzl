"""Rust rules for Buck2: rust_library, rust_binary, crates_io_library.

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

def _compile(ctx, crate_type, out):
    tc = ctx.attrs.toolchain[RustToolchainInfo]
    root, hidden, remap = _root(ctx)
    crate = _crate_name(ctx)
    externs = []
    closure = []
    seen = {}
    for d in ctx.attrs.deps:
        info = d[RustCrateInfo]
        externs.append(cmd_args(info.lib, format = "--extern=" + info.crate_name + "={}"))
        for lib in info.closure:
            if lib not in seen:
                seen[lib] = True
                closure.append(lib)
    rustc_args = cmd_args(
        "--crate-name=" + crate,
        "--crate-type=" + crate_type,
        "--edition=" + ctx.attrs.edition,
        "-Copt-level=" + ctx.attrs.opt_level,
        "-Cdebuginfo=0",
        "-Cstrip=debuginfo",
        # Distinguishes symbols of two crates with the same name.
        "-Cmetadata=" + str(ctx.label.raw_target()).replace(":", "_").replace("/", "_"),
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
        identifier = crate,
    )
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

def _library_impl(ctx):
    crate = _crate_name(ctx)
    ext = "so" if ctx.attrs.proc_macro else "rlib"
    lib = ctx.actions.declare_output("{}/lib{}.{}".format(crate, crate, ext))
    deps_closure = _compile(ctx, "proc-macro" if ctx.attrs.proc_macro else "rlib", lib)
    return [
        DefaultInfo(default_output = lib),
        RustCrateInfo(
            crate_name = crate,
            lib = lib,
            closure = [lib] + deps_closure,
        ),
    ]

rust_library_rule = rule(
    impl = _library_impl,
    attrs = _COMMON_ATTRS | {
        "proc_macro": attrs.bool(default = False),
    },
)

def _binary_impl(ctx):
    tc = ctx.attrs.toolchain[RustToolchainInfo]
    exe = ctx.actions.declare_output(ctx.label.name)
    _compile(ctx, "bin", exe)
    sub_targets = {}
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
    attrs = _COMMON_ATTRS | {
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
        crate = None,
        crate_root = "src/lib.rs",
        busybox = "komira//tools/build/toolchains:busybox",
        visibility = ["PUBLIC"],
        **kwargs):
    """A crates.io crate, pinned by sha256 and compiled with rust_library.

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
    )
    crate_source(
        name = name + ".src",
        archive = ":{}.crate".format(name),
        busybox = busybox,
        prefix = prefix,
        exec_compatible_with = ["komira//tools/build/platforms:light"],
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

# Each rule and macro a BUCK file calls declares its package's doc_tree
# (tools/build/lint/doc_tree.bzl), so no BUCK file names one.
crates_io_library = declares_docs(crates_io_library)
rust_binary = declares_docs(rust_binary_rule)
rust_library = declares_docs(rust_library_rule)
rust_sysroot = declares_docs(rust_sysroot_rule)
