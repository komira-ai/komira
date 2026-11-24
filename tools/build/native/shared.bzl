"""A komira library's own shared library of C (README.md, "Each library's shared library").

`native_shared_library` links the C archives one Mojo library owns into
`libkomira_<library>_native.so.1` (Linux, ELF) or
`libkomira_<library>_native.1.dylib` (macOS, Mach-O), exporting exactly the
names its callers pass to `external_call`, and the names its dependent
owners' archives reference, that those archives define, and checks the
result. A library whose archives need another owner's C links against that
owner's shared library (`needed_owners`): `NEEDED` on it (on Mach-O, loaded
by its install name `@rpath/<file>`), and a run path, `$ORIGIN` (on Mach-O
`@loader_path`), so the loader finds it beside this one. The form follows
the operating system the Mojo toolchain of the target platform compiles for
(`MojoToolchainInfo.os`); `shared_names` and `macho_link_args` below are
the Mach-O form, and `:shared_form_darwin` in BUCK holds it.

Every action but the macOS link runs a Zig-built tool and nothing else:
`native_so` (native_so.zig) writes the export list and reads the result
back. On Linux the link is the Mojo toolchain's zig run through
`zig_cc_launcher`, with the toolchain's target (the platform row's
`zig_triple`), so the library and the programs linking it agree on glibc.
On macOS the link runs on a Mac, as every Mojo link there does: the macOS
compile wrapper's `link` mode (tools/build/mojo/tools/macos_link.zig) runs
the host's /usr/bin/cc after the host identity check, at the toolchain's
deployment target, so the library and the programs linking it agree on the
minimum macOS. docs/design/native_packaging.md, "How each shared library is
linked", is the design; the checks are its "Checks, per library" and "The
same checks on a Mach-O library".
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:native_facts.bzl", "native_dylib", "native_soname")
load("@komira//tools/build/mojo:providers.bzl", "MojoInfo", "MojoToolchainInfo")
load("@komira//tools/build/platforms:table.bzl", "os_floor_version", "row")
load("@komira//tools/build/bench_salt:bench_salt.bzl", "salted")

NativeSharedInfo = provider(
    doc = "A komira library's own shared library, for the libraries that declare it a NEEDED owner and for its library's conda package.",
    # so: the shared library, libkomira_<library>_native.so.1 (on macOS
    # libkomira_<library>_native.1.dylib); soname: the name the loader finds
    # it by, its SONAME (on macOS its file name, which its install name
    # @rpath/<file> ends in); library: the Mojo library's import name;
    # archives: the labels of the archives linked whole, sorted; glibc_floor:
    # the glibc floor check 5 held it to (None for a Mach-O library, which
    # check 5 holds to the darwin-arm64 row's macOS floor);
    # closure: {soname: shared library} of this one and every owner it NEEDs,
    # transitively (`needed_owners`), for the order check of a packaged
    # README's link commands (komira_pack readme-link --needed-of).
    fields = ["archives", "closure", "glibc_floor", "library", "so", "soname"],
)

# What each check reads besides the shared object (native_so.zig, `check`).
_CHECKS = [
    ("1", "exports", ["list", "script"]),
    ("2", "callers", ["archives", "callers", "caller_archives"]),
    ("3", "komira_undefined", ["weak", "owners"]),
    ("4", "needed", ["soname", "owners"]),
    ("5", "glibc_floor", ["floor"]),
    ("6", "symbolic", []),
    ("7", "undefined", ["weak"]),
]

# The weak undefined names of the ELF C runtime the zig link adds (crti's
# __gmon_start__), which every library's `weak_undefined` lists. A Mach-O link
# has no such runtime object, so check 7 of a Mach-O library expects the list
# without them.
ELF_CRT_WEAK = ["__gmon_start__"]

def shared_names(os, library):
    """The names of library `library`'s shared library for operating system `os` (`MojoToolchainInfo.os`).

    struct of `file` (the library's file name), `name` (what the loader and
    every library linking it name it by: the SONAME, or the Mach-O install
    name `@rpath/<file>`), `link` (the unversioned link name, `[link]`),
    `format` (`native_so exports --format`), `script` (the file name of
    the export script: a version script, or ld64's exported symbols list)
    and `script_sub` (its sub-target). Fails for any other `os`.
    """
    if os == "linux":
        soname = native_soname(library)
        return struct(file = soname, name = soname, link = soname[:-len(".1")], format = "elf", script = soname + ".map", script_sub = "version_script")
    if os == "darwin":
        file = native_dylib(library)
        return struct(
            file = file,
            name = "@rpath/" + file,
            link = file[:-len(".1.dylib")] + ".dylib",
            format = "macho",
            script = "exported_symbols.txt",
            script_sub = "exported_symbols_list",
        )
    fail("no shared library form for operating system {} (a library's shared library is ELF on linux and Mach-O on darwin)".format(os))

def _flag(prefix, value):
    return prefix + value if type(value) == "string" else cmd_args(value, format = prefix + "{}")

def macho_link_args(names, deployment_target, out, script, archives, cxx_runtime, owners):
    """The host C driver's arguments that link a Mach-O library (after `mojo_compile link ... --`).

    ld64's counterparts of the ELF link's flags: the install name
    (`-install_name`) for the SONAME; the exported symbols list for the
    version script; `-dead_strip` for `--gc-sections`; `-undefined,error`
    (ld64's default, stated) for `-z defs`; `-S` for `--strip-debug`; each
    archive `-force_load`ed for `--whole-archive`. There is no `-Bsymbolic`
    and no DT_FLAGS: a two-level namespace (ld64's default) binds the
    library's own references to its own definitions (check 6). A C++
    archive takes the system's libc++ (`-lc++`, /usr/lib/libc++.1.dylib), as
    every Mojo program linked on macOS does; each owner's library is loaded
    by its install name, with the one run path `@loader_path`. The CPU is
    arm64: macos-arm64 is the one Mac release platform. A flat list of
    strings and command lines (strings alone when every argument is one,
    as `:shared_form_darwin` gives them).
    """
    flat = [
        "-arch",
        "arm64",
        "-mmacosx-version-min=" + deployment_target,
        "-dynamiclib",
        "-o",
        out,
        "-Wl,-install_name," + names.name,
        _flag("-Wl,-exported_symbols_list,", script),
        "-Wl,-dead_strip",
        "-Wl,-undefined,error",
        "-Wl,-S",
    ]
    flat += [_flag("-Wl,-force_load,", a) for a in archives]
    if cxx_runtime:
        flat.append("-lc++")
    flat += owners
    if owners:
        flat.append("-Wl,-rpath,@loader_path")
    return flat

def _static_pic(ctx, dep):
    subs = dep[DefaultInfo].sub_targets
    if "static-pic" not in subs:
        fail("{}: archive {} has no [static-pic] archive (not a cxx_library?)".format(ctx.label, dep.label.raw_target()))
    return subs["static-pic"][DefaultInfo].default_outputs[0]

def _caller_src(ctx, dep):
    subs = dep[DefaultInfo].sub_targets
    if "src" not in subs:
        fail("{}: caller {} has no [src] sub-target (not a mojo_library?)".format(ctx.label, dep.label.raw_target()))
    return subs["src"][DefaultInfo].default_outputs[0]

def _readme_objects(ctx):
    """The owning library's README programs as object files
    (`[tests][readme][objects]`, tools/build/mojo/readme.bzl): the library is
    the one of `callers` whose import name is `library`. An owner whose
    library has no README, or is not among its callers, is refused here."""
    own = [d for d in ctx.attrs.callers if MojoInfo in d and d[MojoInfo].import_name == ctx.attrs.library]
    if not own:
        fail("{}: no caller is the Mojo library {}, whose README must call this library's C".format(ctx.label, ctx.attrs.library))
    tests = own[0][DefaultInfo].sub_targets.get("tests")
    readme = tests[DefaultInfo].sub_targets.get("readme") if tests != None else None
    if readme == None:
        fail("{}: {} has no README.md, so no README program calls this library's C (docs/design/native_packaging.md, \"Every owner is called, not only loaded\")".format(ctx.label, own[0].label.raw_target()))
    return readme[DefaultInfo].sub_targets["objects"][DefaultInfo].default_outputs[0]

def _native_shared_library_impl(ctx):
    tc = ctx.attrs._toolchain[MojoToolchainInfo]
    if not ctx.attrs.archives or not ctx.attrs.callers:
        fail("{}: needs `archives` and `callers`".format(ctx.label))
    names = shared_names(tc.os, ctx.attrs.library)
    macho = names.format == "macho"

    # `soname` is the name the loader finds the library by, which is also its
    # file name, and keys `closure`; `ident` is what the library names itself
    # (check 4), the same on ELF and `@rpath/<file>` on Mach-O.
    soname = names.file
    ident = names.name
    tool = ctx.attrs._native_so[RunInfo]
    archives = [cmd_args("--archive", str(d.label.raw_target()), _static_pic(ctx, d)) for d in ctx.attrs.archives]
    callers = [cmd_args("--caller", str(d.label.raw_target()), _caller_src(ctx, d)) for d in ctx.attrs.callers]
    caller_archives = [cmd_args("--caller-archive", str(d.label.raw_target()), _static_pic(ctx, d)) for d in ctx.attrs.caller_archives]
    owners = [d[NativeSharedInfo].so for d in ctx.attrs.needed_owners]

    exports = ctx.actions.declare_output("exports.txt")
    script = ctx.actions.declare_output(names.script)
    report = ctx.actions.declare_output("exports_report.txt")
    ctx.actions.run(
        cmd_args(
            tool,
            "exports",
            "--soname",
            ident,
            "--list",
            exports.as_output(),
            "--script",
            script.as_output(),
            "--report",
            report.as_output(),
            ["--format", "macho"] if macho else [],
            archives,
            callers,
            caller_archives,
        ),
        env = salted(),
        category = "native_exports",
        identifier = soname,
    )

    so = ctx.actions.declare_output(soname)
    closure = {soname: so}
    for d in ctx.attrs.needed_owners:
        closure.update(d[NativeSharedInfo].closure)
    if macho:
        # The Mach-O link (macho_link_args), on a Mac: the macOS compile
        # wrapper's `link` mode runs the host's /usr/bin/cc after refusing a
        # host the action key does not name (tc.macos_hosts).
        ctx.actions.run(
            cmd_args(
                tc.wrapper,
                "link",
                "--deployment-target=" + tc.cc_target,
                ["--macos-host=" + h for h in tc.macos_hosts],
                "--",
                macho_link_args(
                    names,
                    tc.cc_target,
                    so.as_output(),
                    script,
                    [_static_pic(ctx, d) for d in ctx.attrs.archives],
                    ctx.attrs.cxx_runtime,
                    owners,
                ),
            ),
            env = salted(),
            category = "native_link",
            identifier = soname,
        )
    else:
        _elf_link(ctx, tc, soname, so, script, owners)
    link = ctx.actions.symlink_file(names.link, so)
    dynsym = ctx.actions.declare_output("dynsym.txt")
    ctx.actions.run(cmd_args(tool, "dynsym", so, dynsym.as_output()), env = salted(), category = "native_dynsym", identifier = soname)

    floor = os_floor_version("darwin-arm64") if macho else ctx.attrs.glibc_floor
    weak = [w for w in ctx.attrs.weak_undefined if w not in ELF_CRT_WEAK] if macho else ctx.attrs.weak_undefined
    inputs = {
        "archives": archives,
        "callers": callers,
        "caller_archives": caller_archives,
        "floor": ["--floor", floor],
        "list": ["--list", exports],
        "owners": [cmd_args("--owner", o) for o in owners],
        "script": ["--script", script],
        "soname": ["--soname", ident],
        "weak": [cmd_args("--weak", w) for w in weak],
    }
    return _checks_and_providers(ctx, tool, names, soname, so, link, dynsym, exports, script, report, inputs, closure, None if macho else ctx.attrs.glibc_floor)

def _elf_link(ctx, tc, soname, so, script, owners):
    """The ELF link, by the Mojo toolchain's zig."""

    # Every archive whole; its own references bound inside it (-Bsymbolic);
    # sections no export reaches dropped; an undefined symbol no NEEDED
    # library defines is a link error (-z defs); exactly the list global.
    # The declared owners' shared libraries after the archives: each is
    # NEEDED by its SONAME, and found at run time through RUNPATH $ORIGIN
    # (a program's own run path is not searched for its libraries' needs).
    # A C++ archive takes zig's libc++ and libc++abi, linked statically; the
    # version script keeps their symbols local.
    ctx.actions.run(
        cmd_args(
            ctx.attrs._launcher[RunInfo],
            tc.link,
            "cc",
            "-target",
            tc.cc_target,
            "-shared",
            "-o",
            so.as_output(),
            "-Wl,-soname," + soname,
            "-Wl,-Bsymbolic",
            "-Wl,--gc-sections",
            "-Wl,-z,defs",
            cmd_args(script, format = "-Wl,--version-script,{}"),
            "-Wl,--strip-debug",
            "-Wl,--whole-archive",
            [_static_pic(ctx, d) for d in ctx.attrs.archives],
            "-Wl,--no-whole-archive",
            ["-lc++"] if ctx.attrs.cxx_runtime else [],
            owners,
            ["-Wl,--enable-new-dtags", "-Wl,-rpath,$ORIGIN"] if owners else [],
        ),
        env = salted(),
        category = "native_link",
        identifier = soname,
    )

def _checks_and_providers(ctx, tool, names, soname, so, link, dynsym, exports, script, report, inputs, closure, glibc_floor):
    """Checks 1 to 7 and the README check, each a validation, and the providers."""
    specs = []
    subs = {}
    for n, name, reads in _CHECKS:
        result = ctx.actions.declare_output("checks/{}_{}.json".format(n, name))
        ctx.actions.run(
            cmd_args(tool, "check", n, "--result", result.as_output(), "--so", so, [inputs[r] for r in reads]),
            env = salted(),
            category = "native_check",
            identifier = "{}_{}".format(n, name),
        )
        specs.append(ValidationSpec(name = "check_{}_{}".format(n, name), validation_result = result))
        subs["check_{}_{}".format(n, name)] = [DefaultInfo(default_output = result)]

    # Every owner is called, not only loaded (docs/design/native_packaging.md,
    # slice 10): some program of the library's README gate links one export.
    readme_result = ctx.actions.declare_output("checks/readme_calls.json")
    ctx.actions.run(
        cmd_args(tool, "readme", "--result", readme_result.as_output(), "--soname", inputs["soname"][1], "--list", exports, "--objects", _readme_objects(ctx)),
        env = salted(),
        category = "native_check",
        identifier = "readme_calls",
    )
    specs.append(ValidationSpec(name = "readme_calls", validation_result = readme_result))
    subs["readme_calls"] = [DefaultInfo(default_output = readme_result)]
    return [
        DefaultInfo(
            default_output = so,
            other_outputs = [link],
            sub_targets = subs | {
                "dynsym": [DefaultInfo(default_output = dynsym)],
                "exports": [DefaultInfo(default_output = exports, other_outputs = [report])],
                "link": [DefaultInfo(default_output = link)],
                "report": [DefaultInfo(default_output = report)],
                names.script_sub: [DefaultInfo(default_output = script)],
            },
        ),
        ValidationInfo(validations = specs),
        NativeSharedInfo(
            archives = sorted([str(d.label.raw_target()) for d in ctx.attrs.archives]),
            closure = closure,
            glibc_floor = glibc_floor,
            library = ctx.attrs.library,
            so = so,
            soname = soname,
        ),
    ]

_native_shared_library = rule(
    impl = _native_shared_library_impl,
    doc = "libkomira_<library>_native.so.1 (on macOS libkomira_<library>_native.1.dylib, install name @rpath/<file>), the shared library of the C `archives` a Mojo library owns, and its link name `[link]`: every archive linked whole, exporting exactly the `external_call` names of the `callers`' sources, and the names the `caller_archives` reference, that those archives define; NEEDED on each of `needed_owners`, with RUNPATH $ORIGIN (on macOS LC_RPATH @loader_path) (`[exports]`, `[version_script]` or on macOS `[exported_symbols_list]`, `[report]`; `[dynsym]` reads the result). Checks 1 to 7 of docs/design/native_packaging.md are validations of this target, one action each (`[check_<n>_<name>]`), and so is the README check (`[readme_calls]`): some program of the library's welded README gate, compiled to an object, references one of the exports.",
    attrs = {
        "archives": attrs.list(attrs.dep(), doc = "The C libraries (cxx_library targets) the library owns; each one's `[static-pic]` archive is linked whole."),
        "caller_archives": attrs.list(attrs.dep(), default = [], doc = "Dependent owners' C archives (cxx_library targets, each `[static-pic]`): every name one references and does not define is exported when this library's archives define it (s2n-tls's needs from aws-lc)."),
        "callers": attrs.list(attrs.dep(), doc = "The mojo_library targets whose `external_call` names the library answers, read from their `[src]` (library sources, never tests)."),
        "cxx_runtime": attrs.bool(default = False, doc = "An archive is C++: `-lc++`, on Linux zig's libc++ and libc++abi linked statically (the version script keeps their symbols local), on macOS the system's /usr/lib/libc++.1.dylib."),
        "glibc_floor": attrs.string(doc = "The highest glibc version the library may need: the platform row's `os_floor` (check 5). A Mach-O library is held to the darwin-arm64 row's macOS floor instead."),
        "library": attrs.string(doc = "The Mojo library's import name; the SONAME is libkomira_<library>_native.so.1 (on macOS the file is libkomira_<library>_native.1.dylib)."),
        "needed_owners": attrs.list(attrs.dep(providers = [NativeSharedInfo]), default = [], doc = "The native_shared_library targets of the owners whose C this library's archives call: linked, NEEDED, and found through RUNPATH $ORIGIN, on macOS LC_RPATH @loader_path (checks 3 and 4)."),
        "weak_undefined": attrs.list(attrs.string(), doc = "Every weak undefined symbol the library has, each with its reason in the BUCK file (checks 3 and 7: the list must be exact). A Mach-O library is held to it without the ELF C runtime's names (`ELF_CRT_WEAK`)."),
        # The ELF link's driver; a macOS target links on a Mac with the host's
        # cc (the Mojo toolchain's wrapper) and takes no Linux tool.
        "_launcher": attrs.option(attrs.exec_dep(providers = [RunInfo]), default = select({
            "prelude//os/constraints:macos": None,
            "DEFAULT": "komira//tools/build/toolchains:zig_cc_launcher",
        })),
        "_native_so": attrs.exec_dep(default = "komira//tools/build/native:native_so", providers = [RunInfo]),
        "_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)

def glibc_floor_of(platform_row):
    """The glibc version of a platform row's `os_floor` (`glibc-2.34` -> `2.34`).

    Takes the row itself, so a test can hand it a fixture row with another
    floor (`:glibc_floor_test` in BUCK)."""
    floor = platform_row["os_floor"]
    if not floor.startswith("glibc-"):
        fail("platform row {}: os_floor {} is not a glibc floor".format(platform_row.get("name", "?"), floor))
    return floor[len("glibc-"):]

def linux_glibc_floor():
    """The glibc floor every library's shared library and conda package carry.

    The Mojo toolchain links for row linux-x86_64 only (its `zig_triple`;
    komira-limit:mojo-toolchain-x86-64), so that row's `os_floor` is the
    floor: check 5 holds each shared library to it, and the packer writes it
    as the `__glibc >=<floor>` requirement (tools/build/package/conda.bzl).
    """
    floor = glibc_floor_of(row("linux-x86_64"))
    if floor != os_floor_version("linux-x86_64"):
        fail("glibc floor {} is not the table's os_floor_version {}".format(floor, os_floor_version("linux-x86_64")))
    return floor

def native_shared_library(**kwargs):
    """`_native_shared_library` with `glibc_floor` read from the platform table."""
    _rule(glibc_floor = linux_glibc_floor(), **kwargs)

def _glibc_floor_test_impl(ctx):
    got = glibc_floor_of({"name": "fixture", "os_floor": ctx.attrs.os_floor})
    if got != ctx.attrs.expect:
        fail("{}: glibc_floor_of a fixture row with os_floor {} gives {}, not {}: the floor is not read from the row".format(ctx.label, ctx.attrs.os_floor, got, ctx.attrs.expect))
    out = ctx.actions.write(ctx.label.name + ".passed", "glibc_floor_of({}) = {}\n".format(ctx.attrs.os_floor, got))
    return [DefaultInfo(default_output = out)]

# glibc_floor_of over a fixture platform row (a floor no real row has): fails
# at analysis unless the floor comes from the row, so a constant floor is red.
_glibc_floor_test = rule(
    impl = _glibc_floor_test_impl,
    attrs = {
        "expect": attrs.string(),
        "os_floor": attrs.string(),
    },
)

glibc_floor_test = declares_docs(_glibc_floor_test)

def _shared_form_test_impl(ctx):
    names = shared_names(ctx.attrs.os, ctx.attrs.library)
    got = {
        "file": names.file,
        "format": names.format,
        "link": names.link,
        "name": names.name,
        "script": names.script,
        "script_sub": names.script_sub,
    }
    if got != ctx.attrs.expect_names:
        fail("{}: shared_names({}, {}) is {}, not {}".format(ctx.label, ctx.attrs.os, ctx.attrs.library, got, ctx.attrs.expect_names))
    lines = ["shared_names({}, {}) = {}".format(ctx.attrs.os, ctx.attrs.library, got)]
    if ctx.attrs.expect_link_args != None:
        args = macho_link_args(names, "11.0", "out.dylib", "exported_symbols.txt", ctx.attrs.archives, ctx.attrs.cxx_runtime, ctx.attrs.owners)
        if args != ctx.attrs.expect_link_args:
            fail("{}: macho_link_args is\n  {}\nnot\n  {}".format(ctx.label, args, ctx.attrs.expect_link_args))
        lines.append("macho_link_args = {}".format(args))
    out = ctx.actions.write(ctx.label.name + ".passed", "\n".join(lines) + "\n")
    return [DefaultInfo(default_output = out)]

# shared_names and macho_link_args over fixture values: fails at analysis
# unless the names (and, for darwin, the ld64 arguments of the link) are
# exactly the expected ones, so a form that is refused, or one that drops an
# argument (the install name, the exported symbols list, a force-loaded
# archive, the owners' run path), is red.
_shared_form_test = rule(
    impl = _shared_form_test_impl,
    attrs = {
        "archives": attrs.list(attrs.string(), default = []),
        "cxx_runtime": attrs.bool(default = False),
        "expect_link_args": attrs.option(attrs.list(attrs.string()), default = None),
        "expect_names": attrs.dict(attrs.string(), attrs.string()),
        "library": attrs.string(),
        "os": attrs.string(),
        "owners": attrs.list(attrs.string(), default = []),
    },
)

shared_form_test = declares_docs(_shared_form_test)

_rule = declares_docs(_native_shared_library)
