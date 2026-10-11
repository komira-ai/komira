"""A komira library's own shared library of C (README.md, "Each library's shared library").

`native_shared_library` links the C archives one Mojo library owns into
`lib<library>_native.so.1`, exporting exactly the names its callers pass to
`external_call`, and the names its dependent owners' archives reference,
that those archives define, and checks the result. A library whose archives
need another owner's C links against that owner's shared library
(`needed_owners`): `NEEDED` on it, and `DT_RUNPATH` `$ORIGIN` so the loader
finds it beside this one. Every
action runs a Zig-built tool and nothing else: `native_so` (native_so.zig)
writes the export list and reads the result back, and the link is the Mojo
toolchain's zig run through `zig_cc_launcher`, with the toolchain's target
(the platform row's `zig_triple`), so the library and the programs linking
it agree on glibc. docs/design/native_packaging.md, "How each shared library
is linked", is the design; the checks are its "Checks, per library".
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoToolchainInfo")
load("@komira//tools/build/platforms:table.bzl", "os_floor_version", "row")

NativeSharedInfo = provider(
    doc = "A komira library's own shared library, for the libraries that declare it a NEEDED owner.",
    # so: the shared library, lib<library>_native.so.1; soname: its SONAME.
    fields = ["so", "soname"],
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

def _native_shared_library_impl(ctx):
    tc = ctx.attrs._toolchain[MojoToolchainInfo]
    if tc.os != "linux":
        fail("{}: a library's shared library is ELF only (a version script, SONAME and DT_FLAGS); Mach-O is a later design".format(ctx.label))
    if not ctx.attrs.archives or not ctx.attrs.callers:
        fail("{}: needs `archives` and `callers`".format(ctx.label))
    soname = "lib{}_native.so.1".format(ctx.attrs.library)
    tool = ctx.attrs._native_so[RunInfo]
    archives = [cmd_args("--archive", str(d.label.raw_target()), _static_pic(ctx, d)) for d in ctx.attrs.archives]
    callers = [cmd_args("--caller", str(d.label.raw_target()), _caller_src(ctx, d)) for d in ctx.attrs.callers]
    caller_archives = [cmd_args("--caller-archive", str(d.label.raw_target()), _static_pic(ctx, d)) for d in ctx.attrs.caller_archives]
    owners = [d[NativeSharedInfo].so for d in ctx.attrs.needed_owners]

    exports = ctx.actions.declare_output("exports.txt")
    script = ctx.actions.declare_output(soname + ".map")
    report = ctx.actions.declare_output("exports_report.txt")
    ctx.actions.run(
        cmd_args(
            tool,
            "exports",
            "--soname",
            soname,
            "--list",
            exports.as_output(),
            "--script",
            script.as_output(),
            "--report",
            report.as_output(),
            archives,
            callers,
            caller_archives,
        ),
        category = "native_exports",
        identifier = soname,
    )

    # Every archive whole; its own references bound inside it (-Bsymbolic);
    # sections no export reaches dropped; an undefined symbol no NEEDED
    # library defines is a link error (-z defs); exactly the list global.
    # The declared owners' shared libraries after the archives: each is
    # NEEDED by its SONAME, and found at run time through RUNPATH $ORIGIN
    # (a program's own run path is not searched for its libraries' needs).
    # A C++ archive takes zig's libc++ and libc++abi, linked statically; the
    # version script keeps their symbols local.
    so = ctx.actions.declare_output(soname)
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
        category = "native_link",
        identifier = soname,
    )
    link = ctx.actions.symlink_file(soname[:-len(".1")], so)
    dynsym = ctx.actions.declare_output("dynsym.txt")
    ctx.actions.run(cmd_args(tool, "dynsym", so, dynsym.as_output()), category = "native_dynsym", identifier = soname)

    inputs = {
        "archives": archives,
        "callers": callers,
        "caller_archives": caller_archives,
        "floor": ["--floor", ctx.attrs.glibc_floor],
        "list": ["--list", exports],
        "owners": [cmd_args("--owner", o) for o in owners],
        "script": ["--script", script],
        "soname": ["--soname", soname],
        "weak": [cmd_args("--weak", w) for w in ctx.attrs.weak_undefined],
    }
    specs = []
    subs = {}
    for n, name, reads in _CHECKS:
        result = ctx.actions.declare_output("checks/{}_{}.json".format(n, name))
        ctx.actions.run(
            cmd_args(tool, "check", n, "--result", result.as_output(), "--so", so, [inputs[r] for r in reads]),
            category = "native_check",
            identifier = "{}_{}".format(n, name),
        )
        specs.append(ValidationSpec(name = "check_{}_{}".format(n, name), validation_result = result))
        subs["check_{}_{}".format(n, name)] = [DefaultInfo(default_output = result)]
    return [
        DefaultInfo(
            default_output = so,
            other_outputs = [link],
            sub_targets = subs | {
                "dynsym": [DefaultInfo(default_output = dynsym)],
                "exports": [DefaultInfo(default_output = exports, other_outputs = [report])],
                "link": [DefaultInfo(default_output = link)],
                "report": [DefaultInfo(default_output = report)],
                "version_script": [DefaultInfo(default_output = script)],
            },
        ),
        ValidationInfo(validations = specs),
        NativeSharedInfo(so = so, soname = soname),
    ]

_native_shared_library = rule(
    impl = _native_shared_library_impl,
    doc = "lib<library>_native.so.1, the shared library of the C `archives` a Mojo library owns, and its link name `[link]`: every archive linked whole, exporting exactly the `external_call` names of the `callers`' sources, and the names the `caller_archives` reference, that those archives define; NEEDED on each of `needed_owners`, with RUNPATH $ORIGIN (`[exports]`, `[version_script]`, `[report]`; `[dynsym]` reads the result). Checks 1 to 7 of docs/design/native_packaging.md are validations of this target, one action each (`[check_<n>_<name>]`).",
    attrs = {
        "archives": attrs.list(attrs.dep(), doc = "The C libraries (cxx_library targets) the library owns; each one's `[static-pic]` archive is linked whole."),
        "caller_archives": attrs.list(attrs.dep(), default = [], doc = "Dependent owners' C archives (cxx_library targets, each `[static-pic]`): every name one references and does not define is exported when this library's archives define it (s2n-tls's needs from aws-lc)."),
        "callers": attrs.list(attrs.dep(), doc = "The mojo_library targets whose `external_call` names the library answers, read from their `[src]` (library sources, never tests)."),
        "cxx_runtime": attrs.bool(default = False, doc = "An archive is C++: link zig's libc++ and libc++abi statically (`-lc++`); the version script keeps their symbols local."),
        "glibc_floor": attrs.string(doc = "The highest glibc version the library may need: the platform row's `os_floor` (check 5)."),
        "library": attrs.string(doc = "The Mojo library's import name; the SONAME is lib<library>_native.so.1."),
        "needed_owners": attrs.list(attrs.dep(providers = [NativeSharedInfo]), default = [], doc = "The native_shared_library targets of the owners whose C this library's archives call: linked, NEEDED, and found through RUNPATH $ORIGIN (checks 3 and 4)."),
        "weak_undefined": attrs.list(attrs.string(), doc = "Every weak undefined symbol the library has, each with its reason in the BUCK file (checks 3 and 7: the list must be exact)."),
        "_launcher": attrs.exec_dep(default = "komira//tools/build/toolchains:zig_cc_launcher", providers = [RunInfo]),
        "_native_so": attrs.exec_dep(default = "komira//tools/build/native:native_so", providers = [RunInfo]),
        "_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)

def _glibc_floor(name):
    floor = row(name)["os_floor"]
    if not floor.startswith("glibc-"):
        fail("platform row {}: os_floor {} is not a glibc floor".format(name, floor))
    return os_floor_version(name)

def native_shared_library(**kwargs):
    """`_native_shared_library` with `glibc_floor` read from the platform table.

    The Mojo toolchain links for row linux-x86_64 only (its `zig_triple`;
    komira-limit:mojo-toolchain-x86-64), so that row's `os_floor` is the floor.
    """
    _rule(glibc_floor = _glibc_floor("linux-x86_64"), **kwargs)

_rule = declares_docs(_native_shared_library)
