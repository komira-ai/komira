"""mojo_shared_lib: a C-ABI shared library gated by its exports and drivers.

Moved out of defs.bzl unchanged; defs.bzl re-exports `mojo_shared_lib_rule` and
declares the `mojo_shared_lib` macro over it.
"""

load("@prelude//linking:link_info.bzl", "MergedLinkInfo", "create_merged_link_info_for_propagation")
load("@komira//tools/build/native:shared.bzl", "NativeSharedInfo")
load("@komira//tools/build/platforms:table.bzl", "row")
load("@komira//tools/build/rerun:rerun.bzl", "RERUN_ATTRS", "rerun_env", "rerun_info")
load(":compile.bzl", _TOOLCHAIN_ATTR = "toolchain_attr", _build_executable = "build_executable", _c_link = "c_link", _check_deps = "check_deps", _dep_closure = "dep_closure", _link_tail = "link_tail", _main_src = "main_src", _stem = "stem", _toolchain = "toolchain")
load(":coverage.bzl", "COVERAGE_SHARED_LIB_ATTRS", "coverage_shared_lib")
load(":opt_level.bzl", "SHIPPED_OPT_LEVEL", "TEST_OPT_LEVEL")
load(":test_limit.bzl", "HANG_LIMIT_ATTRS", "hang_limit_flags")
load(":system_libs.bzl", "dep_system_libs", "run_args")
load(":test_runtime.bzl", _test_root = "test_root", gate_mojo = "gate_mojo")
load("@komira//tools/build/bench_salt:bench_salt.bzl", "salted")

# ---- mojo_shared_lib --------------------------------------------------------
#
# A C-ABI shared library: `mojo build --emit shared-lib` of one file of
# `@export` functions, over the closure of `deps`. Linux (`.so`) and macOS
# arm64 (`.dylib`); mojo_binary's `[shared]` and the bundles are Linux only,
# and the darwin wrapper still refuses `--emit shared-lib` for them.
#
#   out_name       the file is `<out_name>.so` (Linux) or `<out_name>.dylib`
#                  (macOS), its DT_SONAME / install name `@rpath/<file>`: no
#                  `lib` prefix is forced (mojo_binary's `[shared]` forces
#                  one). Drivers open `./<out_name>.so` or `./<out_name>.dylib`
#                  by `CompilationTarget.is_macos()`.
#   exports        the library's C ABI: exactly the main source's @export abi("C")
#                  functions, less `unlisted_exports` (checked, tools/so_exports.zig).
#                  The gate dlopens the library (RTLD_NOW, so an unresolved
#                  symbol fails there) and fails unless every one resolves.
#   c_exports      symbols a C library of the closure defines: expected by the
#                  gate, not compared with the source.
#   unlisted_exports
#                  @export functions kept out of `exports` on purpose; they
#                  must exist in the source. `exports_exact` makes them local.
#   exports_exact  default False. True links with a version script that makes
#                  `exports` and `c_exports` the whole dynamic symbol table:
#                  nothing else is visible, so a symbol of a static C
#                  dependency does not leak into the ABI, and an unlisted
#                  @export is MISSING for any driver that calls it.
#   gate_srcs      linked-run drivers: Mojo mains that dlopen `./<out_name>.so`
#                  (the gate stages it as their one data file) and call it.
#   force_load     C/C++ libraries linked whole (--whole-archive): every object
#                  of their archives is in the library, referenced or not.
#
# The published file is `<name>/<out_name>.so`: a copy of `ungated/<out_name>.so`
# that takes the PASS marker of every gate run as an input, so it cannot exist
# unless the exports check and every driver passed. The same pattern as
# mojo_library's tests.

_EXPORTS_DRIVER = """from std.ffi import OwnedDLHandle


def main() raises:
    # RTLD_NOW (the default flags): an unresolved symbol fails here, not at
    # the first call.
    var lib = OwnedDLHandle("./{so}")
    var missing = 0
{checks}
    if missing != 0:
        raise Error("{so}: " + String(missing) + " expected export(s) missing")
"""

_EXPORT_CHECK = """    if not lib.check_symbol("{sym}"):
        print("MISSING EXPORT: {sym}")
        missing += 1
"""

def _shared_lib_impl(ctx):
    tc = _toolchain(ctx)
    out_name = ctx.attrs.out_name or ctx.label.name
    if not regex_match("^[A-Za-z_][A-Za-z0-9_]*$", out_name):
        fail("{}: out_name `{}` is not [A-Za-z_][A-Za-z0-9_]*".format(ctx.label, out_name))
    if not ctx.attrs.exports and not ctx.attrs.c_exports:
        fail("{}: `exports` is empty: a gate that expects no symbol checks nothing".format(ctx.label))
    for sym in ctx.attrs.exports + ctx.attrs.c_exports + ctx.attrs.unlisted_exports:
        if not regex_match("^[A-Za-z_][A-Za-z0-9_]*$", sym):
            fail("{}: export `{}` is not a C symbol name".format(ctx.label, sym))
    abi_names = ctx.attrs.exports + ctx.attrs.c_exports
    for sym in ctx.attrs.c_exports:
        if sym in ctx.attrs.exports or sym in ctx.attrs.unlisted_exports:
            fail("{}: `{}` is in `c_exports` and also in `exports` or `unlisted_exports`".format(ctx.label, sym))
    main = _main_src(ctx)
    srcs = ctx.attrs.srcs if main in ctx.attrs.srcs else ctx.attrs.srcs + [main]
    _check_deps(ctx)
    for d in ctx.attrs.force_load:
        if MergedLinkInfo not in d:
            fail("{}: force_load {} provides no MergedLinkInfo (a C/C++ library)".format(ctx.label, d.label))
    force = None
    if ctx.attrs.force_load:
        force = _link_tail(create_merged_link_info_for_propagation(ctx, [d[MergedLinkInfo] for d in ctx.attrs.force_load]))
    darwin = tc.os == "darwin"
    link_extra = None
    if force != None:
        if darwin:
            # ld has no bracketed whole-archive: -force_load names one
            # archive, so each argument of the C libraries' link line is one.
            link_extra = cmd_args(force, format = "-Wl,-force_load,{}")
        else:
            link_extra = cmd_args("-Wl,--whole-archive", force, "-Wl,--no-whole-archive")
    if ctx.attrs.exports_exact:
        # The dynamic symbol table is `exports` and nothing else, so a symbol
        # of a static C dependency, or an @export the list does not name, is
        # local to the library. ELF: a version script. Mach-O: an exported
        # symbols list, whose names carry the C underscore.
        if darwin:
            script = ctx.actions.write(
                "exports.list",
                "".join(["_" + sym + "\n" for sym in abi_names]),
            )
            limit = cmd_args(script, format = "-Wl,-exported_symbols_list,{}")
        else:
            script = ctx.actions.write(
                "exports.map",
                "{ global: " + " ".join([sym + ";" for sym in abi_names]) + " local: *; };\n",
            )
            limit = cmd_args(script, format = "-Wl,--version-script={}")
        link_extra = cmd_args(link_extra, limit) if link_extra else cmd_args(limit)

    if not darwin:
        # The run path also names the library's own directory: an installed
        # package puts the library in `<prefix>/lib`, where the Mojo
        # runtime it is NEEDED on is installed beside it, so `$ORIGIN/lib`
        # (the `lib/` the gate stages) alone finds nothing there. lld joins
        # the two `-rpath` into one DT_RUNPATH.
        link_extra = cmd_args(link_extra, "-Wl,-rpath,$ORIGIN") if link_extra else cmd_args("-Wl,-rpath,$ORIGIN")

    # The owners' shared libraries (`native_owners`): linked ahead of the C
    # archives, so the library is NEEDED on each owner's SONAME and the
    # symbols the owner defines are bound to it. The gate stages each owner
    # and everything it NEEDs in lib/ beside the library, where its run path
    # (`$ORIGIN/lib`) finds them.
    link_head = None
    owner_files = {}
    if ctx.attrs.native_owners:
        if darwin:
            fail("{}: `native_owners` is ELF only (a library's shared library is Linux only; Mach-O is a later design)".format(ctx.label))
        link_head = cmd_args([o[NativeSharedInfo].so for o in ctx.attrs.native_owners])
        for o in ctx.attrs.native_owners:
            for soname, so in o[NativeSharedInfo].closure.items():
                owner_files["lib/" + soname] = so

    so_file = out_name + (".dylib" if darwin else ".so")
    ungated = _build_executable(
        ctx,
        tc,
        "ungated/" + so_file,
        srcs,
        main,
        _dep_closure(ctx),
        ctx.attrs.optimization_level,
        "mojo_build_shared_lib",
        None,
        _c_link(ctx),
        abi_lib = True,
        link_extra = link_extra,
        link_head = link_head,
    )

    # The gate: each driver is a Mojo program with no dependencies that
    # dlopens "./<out_name>.so", staged as its only data file.
    drivers = {}
    checks = "".join([_EXPORT_CHECK.format(sym = sym) for sym in abi_names])
    drivers["exports"] = ctx.actions.write(
        "gate/exports.mojo",
        _EXPORTS_DRIVER.format(so = so_file, checks = checks),
    )
    for g in ctx.attrs.gate_srcs:
        stem = _stem(g)
        if stem == "exports" or stem in drivers:
            fail("{}: gate_srcs has two drivers named `{}`".format(ctx.label, stem))
        drivers[stem] = g
    markers = []
    gate_subtargets = {}
    # The exports check: `exports` is the set of @export abi("C") functions of
    # the main source, less `unlisted_exports` (tools/so_exports.zig).
    exports_ok = ctx.actions.declare_output("gate/exports_listed.passed")
    ctx.actions.run(
        cmd_args(
            ctx.attrs._so_exports[RunInfo],
            "check",
            main,
            exports_ok.as_output(),
            str(ctx.label.raw_target()),
            ctx.attrs.exports,
            "--",
            ctx.attrs.unlisted_exports,
        ),
        env = salted(),
        category = "mojo_shared_lib_exports",
    )
    markers.append(exports_ok)
    for stem in sorted(drivers.keys()):
        src = drivers[stem]
        exe = _build_executable(ctx, tc, "gate/{}/{}".format(stem, stem), [src], src, [], ctx.attrs.driver_optimization_level, "mojo_build_gate_driver", stem, None)
        root, staged = _test_root(ctx, "gate/{}/root".format(stem), exe, {so_file: ungated} | owner_files)
        marker = ctx.actions.declare_output("gate/{}.passed".format(stem))
        ctx.actions.run(
            cmd_args(
                gate_mojo(tc, "{}:{}".format(ctx.label.raw_target(), stem), staged, marker.as_output(), hang_limit_flags(str(ctx.label.raw_target()), ctx.attrs.test_hang_limit_s), run_args([], dep_system_libs(ctx.attrs.deps))),
                hidden = root,
            ),
            env = salted(rerun_env(ctx)),
            category = "mojo_shared_lib_gate",
            identifier = stem,
        )
        gate_subtargets[stem] = [DefaultInfo(default_output = marker, other_outputs = [root])]
        markers.append(marker)

    public = ctx.actions.declare_output("pub/" + so_file)
    ctx.actions.run(
        cmd_args(tc.act, "copy", ungated, public.as_output(), hidden = markers),
        env = salted(),
        category = "mojo_shared_lib_join",
    )
    sub_targets = {
        "gate": [DefaultInfo(default_outputs = markers, sub_targets = gate_subtargets)],
        # Files only: the library before its gate ran.
        "ungated": [DefaultInfo(default_output = ungated)],
    }
    if not darwin:
        # The library where a host can load it: the gated file with lib/ beside
        # it, holding the Mojo runtime libraries and each native owner's
        # closure, which is where the run path (`$ORIGIN/lib`) looks. A copy,
        # not links: the loader expands `$ORIGIN` from the resolved path.
        files = {so_file: public}

        # The toolchain does not name its platform row, so the list is read
        # from one: the linux rows state the same runtime libraries (the
        # compiler's three and its NEEDED libstdc++ and libgcc_s), and this
        # fails the day they differ instead of shipping the wrong set.
        if row("linux-x86_64")["runtime_libs"] != row("linux-arm64")["runtime_libs"]:
            fail("{}: the linux platform rows list different runtime_libs; select the row by the target platform".format(ctx.label))
        for name in row("linux-x86_64")["runtime_libs"]:
            files["lib/" + name] = tc.runtime.project(name)
        for dest, so in owner_files.items():
            if dest in files:
                fail("{}: native owner library {} is also a Mojo runtime library".format(ctx.label, dest))
            files[dest] = so
        sub_targets["runnable"] = [DefaultInfo(default_output = ctx.actions.copied_dir(out_name + ".runnable", files))]
    return [DefaultInfo(
        default_output = public,
        sub_targets = sub_targets | coverage_shared_lib(ctx, tc, _build_executable, srcs, main, _dep_closure(ctx), _c_link(ctx), link_extra, so_file),
    ), rerun_info(ctx)]

mojo_shared_lib_rule = rule(
    impl = _shared_lib_impl,
    attrs = {
        "deps": attrs.list(attrs.dep(), default = []),
        "driver_optimization_level": attrs.string(default = TEST_OPT_LEVEL),
        "c_exports": attrs.list(attrs.string(), default = []),
        "exports": attrs.list(attrs.string()),
        "exports_exact": attrs.bool(default = False),
        "force_load": attrs.list(attrs.dep(), default = []),
        "gate_srcs": attrs.list(attrs.source(), default = []),
        "main": attrs.option(attrs.source(), default = None),
        "native_owners": attrs.list(attrs.dep(providers = [NativeSharedInfo]), default = []),
        "optimization_level": attrs.string(default = SHIPPED_OPT_LEVEL),
        "out_name": attrs.option(attrs.string(), default = None),
        "unlisted_exports": attrs.list(attrs.string(), default = []),
        "_so_exports": attrs.exec_dep(default = "komira//tools/build/mojo:so_exports"),
        "srcs": attrs.list(attrs.source()),
    } | _TOOLCHAIN_ATTR | COVERAGE_SHARED_LIB_ATTRS | HANG_LIMIT_ATTRS | RERUN_ATTRS,
)
