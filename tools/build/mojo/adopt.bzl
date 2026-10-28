"""`mojo_adopted_library`: a library built by another set of rules, as komira's own rules see it.

A library built with buildrules' `mojo_package` (src/komira_json is the first) makes a gated `.mojoc`
file and no `MojoInfo`. The packages that list it in `deps` are `mojo_library`, `mojo_binary` and
`mojo_test` targets, which accept only a dependency with `MojoInfo`. This rule is that bridge, and
nothing more: it compiles nothing and runs no test. Its inputs are two targets of the package it
adopts, and it hands on what they made.

    mojo_adopted_library(
        name = "komira_json",                      # the target the dependents name; the import name
        lib = ":lib",                              # the package's `:lib`: the `.mojoc`, behind the run of every test
        test_runs = ":test",                       # the package's `:test`: the marker of each test run
        srcs = glob(["src/komira_json/**/*.mojo"]),  # the library's sources (what a conda package ships)
        test_srcs = glob(["tests/test_*.mojo"]),   # the test files `test_runs` runs (the weld lint reads them)
        readme = "README.md",
    )

What a dependent gets is what `mojo_library` would give it, for a library with no native
code: `-I` on the file of `lib`, so the file exists (and the dependent builds) only once every test has
passed, because `lib` is made only then. The same facts the conda package reads (`conda_name`, the
README, the `src` and `tests` sub-targets) are the library's own, so `conda_package(lib = ...)` packs
it as it packs a `mojo_library`.

With a `readme`, the README's examples are compiled and run as a `mojo_library`'s are: the rule calls
`readme_gate` (`readme.bzl`) with the same action (`defs.bzl`), so `[tests][readme]` and its
`[file]`, `[generated]` and `[objects]` sub-targets are the ones a `mojo_library` has, and a broken
example fails that target. The examples compile against `lib`, the gated file, so they run once the
package's tests have passed; the package's tests are not run again, and the README gate does not
gate `lib` or the dependents (it is part of `[tests]`, as in a `mojo_library`). The `readme_tool`
is set by this macro, as `mojo_library`'s is.

What it does not carry, because buildrules' rules do not: the branch coverage gate, the coverage runs
of the README and the mutation sub-targets of a `mojo_library`. A library adopted here has none of
them until buildrules has them. Its coverage is the package's own: `:coverage` (the per-file line
and branch counts), `:coverage[reports]` (one kcov report per test, the per-line records),
`:coverage[branches]` (one lcov file per test, the branch records) and, with a
`coverage_floor.txt` beside the BUCK file, `:coverage_floor` (the line floor and the branch floor, minimums: the build fails below either and above it prints a hint to raise it; the pull
request check builds). The pull request's coverage job (`coverage.yml`) selects `mojo_package`
packages as well as `mojo_library` targets and reads `:coverage[reports]` and `:coverage[branches]`: line and branch coverage, the
per-line annotations and the `line` and `branch` entries of `coverage_held`.

A package that opens a system library at run time (`OwnedDLHandle`; `[native-dependencies]` with `mode = "load"`
in its `mopm.toml`, which `:conda` records as a conda requirement) declares the sonames in `dlopen`, as
`mojo_library` does (`dlopen.bzl`): `MojoInfo.dlopen` and the conda refusal are the same, so
`conda_package(lib = ...)` over the adopted label requires the conda package `system_libs.bzl` names for
each soname, and the packer holds the declaration to the sources.

A library with Mojo dependencies lists them in `deps`, as a `mojo_library` does: the adopted (or `mojo_library`)
targets of the packages its `mopm.toml` names under `[dependencies]`. The package's own `:lib` is built from the
dependency packages' `:lib` (a path dependency, `{ path = "../komira_runtime_paths", version = "0.1" }`), so the
closure of `lib` and the closure of `deps` are one set, and the rule refuses a BUCK file where they differ, in
either direction, naming the packages: a dependency the manifest lacks would be built into the file and left out of
the `-I` of every dependent, and one the BUCK file lacks would be a dependency the published package records and no
dependent of the old label sees.

    mojo_adopted_library(
        name = "komira_resources",
        lib = ":lib",
        deps = ["//src/komira_runtime_paths:komira_runtime_paths"],   # `[dependencies]` of mopm.toml
        ...
    )

What a dependent then gets is `lib` and the closure of `deps` (`MojoInfo.pkgs`, one `-I` per package, the same
file of each package that its own `:lib` is), `MojoInfo.direct` and `direct_conda` (so `conda_package(lib = ...)`
requires the dependencies' conda packages), and the native facts of the closure. The C link of a dependent is
`lib`'s own `MojoNativeArchiveInfo`, which already lists the archives of the dependencies in the graph's link order,
so the dependencies' `c_link` are not merged in a second time.

A package that pins system libraries for its tests (its unit graph's `system_libs`: a library it opens by its bare name, `mode = "load"` in
`[native-dependencies]`) hands the directories of the pinned files on through its `lib`, which carries buildrules' `MojoSystemLibsInfo`. This rule makes
them `MojoInfo.system_libs`, with those of `deps`, and every `mojo_library`, `mojo_test` and adopted package that depends on it carries them on
(`system_libs.bzl`): the welded tests of such a library, its README examples, its kcov and branch coverage runs and its mutation runs, and a `mojo_test`, are
given them as `--lib-dir` arguments of the gate, which puts them on the library path. The files are the pinned ones, unpacked from the sha256-pinned
packages of the graph; a run takes nothing from the worker. A package that pins none changes no command.

A package that builds C of its own (`[native.<id>]` in its `mopm.toml`, a static library
`lib<id>.a`) hands it to its dependents here. buildrules gives its `:lib` `MojoNativeArchiveInfo`: the
archives the library links, in the graph's link order. This rule makes them `MojoInfo.c_link` (a
`MergedLinkInfo` over those archives, in that order), so a `mojo_library`, `mojo_binary` or
`mojo_test` that lists the adopted label in `deps` links them with no edit to its own BUCK file, and
the README examples are linked with them. A package with none has `c_link = None`, as before.

The older packaging of such a library (`native = ":<name>_native"`, its own shared library in the
release set, tools/build/native/README.md) still names C libraries by label. `c_deps` lists them,
and `native` names the shared library: they give `MojoInfo.native` the facts `mojo_library` gives
(`c_direct`, `linked`, `shipped`, the SONAME), so `conda_package(lib = ..., native = ...)` and the
shared library's `callers` take the adopted label. `c_deps` are not linked (the archives of
`MojoNativeArchiveInfo` are the link): they are the labels the shared library is built from, so each
C symbol is still defined once in any link.

A library whose C is per-library state (one copy per image, which a shared library would merge across images)
ships it as a static archive in its conda package instead, with no shared library: it lists the C in `c_deps`
and sets `native_static = True`. Its closure facts then carry the static archive (`MojoInfo.native.shipped`
and `statics`, the same as `mojo_library`'s `native_static`), so a dependent's check that every C library its
closure links is shipped by a library of the closure (`native_refusal`, native_facts.bzl; the release set's
checks read the same facts) finds the owner. Without it the adopted label links the C and ships none, and
every package that depends on it has no conda package. `native` and `native_static` are exclusive.

    mojo_adopted_library(
        name = "komira_log",
        c_deps = [":komira_log_holder"],   # the cxx_library the archive is built from
        native_static = True,
        ...
    )
"""

load("@buildrules//rules/mojo:providers.bzl", "MojoLibInfo", "MojoNativeArchiveInfo")
load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/rerun:rerun.bzl", "RERUN_ATTRS", "rerun_env")
load("@prelude//cxx:cxx_toolchain_types.bzl", "CxxToolchainInfo")
load("@prelude//linking:link_info.bzl", "Archive", "ArchiveLinkable", "LibOutputStyle", "LinkInfo", "LinkInfos", "MergedLinkInfo", "create_merged_link_info")
load("@prelude//linking:types.bzl", "Linkage")
load(":defs.bzl", "adopt_link_tail", "adopt_readme_test")
load(":dlopen.bzl", "DLOPEN_ATTRS", "dlopen_refusal", "dlopen_rows")
load(":native_facts.bzl", "native_facts")
load(":opt_level.bzl", "TEST_OPT_LEVEL")
load(":providers.bzl", "MojoInfo", "MojoPkgTSet", "MojoToolchainInfo", "mojo_pkg_children", "welded_tests_info")
load(":readme.bzl", "readme_gate")
load(":system_libs.bzl", "dep_system_libs", "merge_system_libs", "own_system_libs", "run_args")
load(":test_limit.bzl", "HANG_LIMIT_ATTRS")

# The README examples tool of mojo_library (readme.bzl): Zig, so it depends on no Mojo library.
_README_TOOL = "komira//tools/build/readme_examples:tool"

# The facts of a library that links no native code (native_facts.bzl, `native_facts`).
_NO_NATIVE = struct(
    c_direct = [],
    linked = {},
    owner_rank = {},
    shipped = {},
    sonames = {},
    soname = None,
    static = [],
    statics = {},
)

CxxLinkFacts = provider(fields = ["linker_type", "pic_behavior"])

def _cxx_link_facts_impl(ctx):
    toolchain = ctx.attrs.toolchain[CxxToolchainInfo]
    return [DefaultInfo(), CxxLinkFacts(linker_type = toolchain.linker_info.type, pic_behavior = toolchain.pic_behavior)]

# The two facts of the C/C++ toolchain a dependent's link needs (the linker type and the PIC behaviour),
# held by a rule of their own. A toolchain_dep of `mojo_adopted_library` itself would restrict its
# execution platform to the C toolchain's (a linux one), while its README gate compiles Mojo on the
# platform the target is built for; a target that depends on this rule through a plain dep leaves its own
# execution platform to the Mojo toolchain, and this rule runs on the C toolchain's.
cxx_link_facts = rule(
    impl = _cxx_link_facts_impl,
    attrs = {"toolchain": attrs.toolchain_dep(default = "toolchains//:cxx", providers = [CxxToolchainInfo])},
)

def _package_root(ctx, srcs):
    """The package-relative directory of the shallowest `__init__.mojo` (as defs.bzl's `_package_root`)."""
    inits = [s.short_path for s in srcs if s.basename == "__init__.mojo"]
    if not inits:
        fail("{}: srcs needs an __init__.mojo".format(ctx.label))
    shallowest = sorted(inits, key = lambda p: (p.count("/"), p))[0]
    return shallowest[:-len("__init__.mojo")].rstrip("/")

def _native_link(ctx):
    """The C closure of the package's own native archives, as the `MergedLinkInfo` komira's rules link.

    buildrules hands every library target `MojoNativeArchiveInfo`: the static libraries the unit
    links (`lib<id>.a` of the package's own `[native.<id>]` and of the members and registry packages
    it needs), in the graph's link order, a library before every library it needs. A dependent that
    links through komira's rules takes them from `MojoInfo.c_link`, in that order, as it takes the
    archive of a `cxx_library` in `deps`. Returns None for a package with none."""
    natives = ctx.attrs.lib.get(MojoNativeArchiveInfo)
    if natives == None or not natives.sonames:
        return None
    if ctx.attrs.cxx_toolchain == None:
        fail("{}: {} links native libraries ({}); set `c_deps` (the macro then sets `cxx_toolchain`)".format(ctx.label, ctx.attrs.lib.label, ", ".join(natives.sonames)))
    facts = ctx.attrs.cxx_toolchain[CxxLinkFacts]
    linkables = []
    for soname in natives.sonames:
        if not soname.endswith(".a"):
            fail("{}: native library {} is not a static archive; only `lib<id>.a` can be taken into a dependent's link".format(ctx.label, soname))
        linkables.append(ArchiveLinkable(archive = Archive(artifact = natives.archives[soname]), linker_type = facts.linker_type))
    infos = LinkInfos(default = LinkInfo(name = str(ctx.label.raw_target()), linkables = linkables))
    return create_merged_link_info(
        ctx,
        facts.pic_behavior,
        {LibOutputStyle("archive"): infos, LibOutputStyle("pic_archive"): infos},
        preferred_linkage = Linkage("static"),
    )

def _check_deps_are_closure(ctx, import_name, deps):
    """Refuses `deps` unless they are, with their own closures, exactly the packages `lib` was built from.

    `lib` is buildrules' `:lib` (`MojoLibInfo`): its `closure` maps each package of the unit's `--deps` directory
    to its `.mojoc`, the package itself included. A dependent of this label compiles against `lib` and the
    `.mojoc` of every package in `deps`' closures, so the two sets of names must be one, and a package named
    by both must be the same file (the dependency's own gated `:lib`), not a rebuild of it."""
    lib = ctx.attrs.lib.get(MojoLibInfo)
    if lib == None:
        if deps:
            fail("{}: `deps` is set, but `lib` ({}) has no MojoLibInfo to hold it to; `lib` must be a `mojo_package`'s `:lib`".format(ctx.label, ctx.attrs.lib.label.raw_target()))
        return
    built_from = {name: f for name, f in lib.closure.items() if name != import_name}
    given = {}
    for d in deps:
        for pkg in d[MojoInfo].pkgs.traverse():
            given[pkg.basename[:-len(".mojoc")]] = pkg
    missing = sorted([n for n in built_from if n not in given])
    extra = sorted([n for n in given if n not in built_from])
    if missing:
        fail("{}: `lib` ({}) is built from {}, which `deps` does not bring: add the target of each (the packages `[dependencies]` of mopm.toml names)".format(ctx.label, ctx.attrs.lib.label.raw_target(), ", ".join(missing)))
    if extra:
        fail("{}: `deps` brings {}, which `lib` ({}) is not built from: `[dependencies]` of mopm.toml does not reach it (add it there and run `buildrules mojo sync`, or drop the dep)".format(ctx.label, ", ".join(extra), ctx.attrs.lib.label.raw_target()))
    for name in sorted(given):
        if given[name] != built_from[name]:
            fail("{}: `deps` and `lib` ({}) hold two different files for {}: `lib` was built from {}, the dependency's closure holds {}".format(ctx.label, ctx.attrs.lib.label.raw_target(), name, built_from[name], given[name]))

def _conda_refusal(ctx, deps):
    """Why the old conda package cannot be built (`MojoInfo.conda_refusal`): the soname refusal, else a dependency with no package."""
    why = dlopen_refusal(ctx)
    if why != None:
        return why
    for d in deps:
        di = d[MojoInfo]
        if di.conda_name == None:
            return "it depends on {}, which has no conda package (`conda = False`, or it is not a mojo_library)".format(d.label.raw_target())
        if di.conda_refusal != None:
            return "it depends on {}, which has no conda package: {}".format(d.label.raw_target(), di.conda_refusal)
    return None

def _impl(ctx):
    import_name = ctx.attrs.import_name or ctx.label.name
    made = ctx.attrs.lib[DefaultInfo].default_outputs
    if len(made) != 1 or made[0].basename != import_name + ".mojoc":
        fail("{}: `lib` must make exactly {}.mojoc (a closure holds one `<import name>.mojoc` per package), not {}".format(
            ctx.label,
            import_name,
            [m.basename for m in made],
        ))
    public = made[0]
    markers = ctx.attrs.test_runs[DefaultInfo].default_outputs
    if not markers:
        fail("{}: `test_runs` ({}) runs no test, so the library is not gated by any".format(ctx.label, ctx.attrs.test_runs.label))
    root = _package_root(ctx, ctx.attrs.srcs)
    mapping = {}
    for s in ctx.attrs.srcs:
        if not s.short_path.startswith(root + "/"):
            fail("{}: {} is outside the package root {}".format(ctx.label, s.short_path, root))
        mapping[s.short_path[len(root) + 1:]] = s
    src_dir = ctx.actions.copied_dir("src/" + import_name, mapping)
    deps = [d for d in ctx.attrs.deps]
    for d in deps:
        if MojoInfo not in d:
            fail("{}: dep {} provides no MojoInfo (an adopted or `mojo_library` package)".format(ctx.label, d.label))
    _check_deps_are_closure(ctx, import_name, deps)
    infos = [d[MojoInfo] for d in deps]
    pkgs = ctx.actions.tset(MojoPkgTSet, value = public, children = mojo_pkg_children(ctx, infos))

    # The README gate, as a mojo_library's (readme.bzl, readme_gate): compiled against `lib`, with no C
    # closure; the README ships in the conda package, so a relative link in it is refused.
    c_link = _native_link(ctx)
    native = native_facts(ctx, import_name, ctx.attrs.c_deps + deps) if ctx.attrs.c_deps or ctx.attrs.native or deps else _NO_NATIVE
    # The pinned system libraries `lib` loads and those of the dependencies (system_libs.bzl): the README's runs are given them, and so is every dependent's.
    system_libs = merge_system_libs([own_system_libs(ctx.attrs.lib), dep_system_libs(deps)])
    gate = readme_gate(ctx, ctx.attrs.toolchain[MojoToolchainInfo], import_name, pkgs, adopt_link_tail(c_link), run_args([], system_libs), True, adopt_readme_test, owner = bool(native.c_direct), rerun = rerun_env(ctx))
    test_subtargets = {}
    if gate != None:
        markers = markers + [gate[0]]
        test_subtargets["readme"] = [DefaultInfo(
            default_output = gate[0],
            other_outputs = [gate[1]],
            sub_targets = {
                "file": [DefaultInfo(default_output = ctx.attrs.readme)],
                "generated": [DefaultInfo(default_output = gate[1])],
                "objects": [DefaultInfo(default_output = gate[3])],
            },
        )]
    return [
        DefaultInfo(
            default_output = public,
            sub_targets = {
                "src": [DefaultInfo(default_output = src_dir)],
                "tests": [DefaultInfo(default_outputs = markers, sub_targets = test_subtargets)],
            },
        ),
        MojoInfo(
            c_link = c_link,
            conda_name = ctx.attrs.conda_name or import_name,
            conda_refusal = _conda_refusal(ctx, deps),
            dlopen = dlopen_rows(ctx),
            direct = sorted([i.import_name for i in infos]),
            direct_conda = {i.import_name: struct(name = i.conda_name, refusal = i.conda_refusal) for i in infos},
            import_name = import_name,
            native = native,
            pkgs = pkgs,
            pkgs_def = MojoPkgTSet,
            readme = ctx.attrs.readme,
            system_libs = system_libs,
        ),
        welded_tests_info(ctx.attrs.test_srcs),
    ]

_adopted = rule(
    impl = _impl,
    attrs = {
        "c_deps": attrs.list(attrs.dep(providers = [MergedLinkInfo]), default = []),
        "conda_name": attrs.option(attrs.string(), default = None),
        "cxx_toolchain": attrs.option(attrs.dep(providers = [CxxLinkFacts]), default = None),
        "deps": attrs.list(attrs.dep(), default = []),
        "import_name": attrs.option(attrs.string(), default = None),
        "lib": attrs.dep(),
        "native": attrs.option(attrs.label(), default = None),
        "native_static": attrs.bool(default = False),
        "readme": attrs.option(attrs.source(), default = None),
        "readme_tool": attrs.option(attrs.exec_dep(providers = [RunInfo]), default = None),
        "srcs": attrs.list(attrs.source()),
        "test_optimization_level": attrs.string(default = TEST_OPT_LEVEL),
        "test_srcs": attrs.list(attrs.source()),
        "test_runs": attrs.dep(),
        "toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    } | DLOPEN_ATTRS | HANG_LIMIT_ATTRS | RERUN_ATTRS,
)

def _mojo_adopted_library(**kwargs):
    # A package that links its own C needs the C toolchain's link facts for `c_link`.
    if kwargs.get("c_deps"):
        if "cxx_toolchain" in kwargs:
            fail("{}: `cxx_toolchain` is set by mojo_adopted_library with `c_deps`; do not pass it".format(kwargs.get("name", "mojo_adopted_library")))
        kwargs["cxx_toolchain"] = "komira//tools/build/mojo:adopt_cxx_link_facts"
    if kwargs.get("readme") != None:
        if "readme_tool" in kwargs:
            fail("{}: `readme_tool` is set by mojo_adopted_library with the README; do not pass it".format(kwargs.get("name", "mojo_adopted_library")))
        kwargs["readme_tool"] = _README_TOOL
    _adopted(**kwargs)

mojo_adopted_library = declares_docs(_mojo_adopted_library)
