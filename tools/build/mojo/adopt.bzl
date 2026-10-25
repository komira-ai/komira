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

What a dependent gets is what `mojo_library` would give it, for a library with no deps and no native
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

A library that has deps or native code is not adopted by this rule: it has no `deps` or `native`
attribute, so a BUCK file that needs them stops at the attribute, not at a wrong `MojoInfo`.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/rerun:rerun.bzl", "RERUN_ATTRS", "rerun_env")
load(":defs.bzl", "adopt_readme_test")
load(":opt_level.bzl", "TEST_OPT_LEVEL")
load(":providers.bzl", "MojoInfo", "MojoPkgTSet", "MojoToolchainInfo", "welded_tests_info")
load(":readme.bzl", "readme_gate")

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

def _package_root(ctx, srcs):
    """The package-relative directory of the shallowest `__init__.mojo` (as defs.bzl's `_package_root`)."""
    inits = [s.short_path for s in srcs if s.basename == "__init__.mojo"]
    if not inits:
        fail("{}: srcs needs an __init__.mojo".format(ctx.label))
    shallowest = sorted(inits, key = lambda p: (p.count("/"), p))[0]
    return shallowest[:-len("__init__.mojo")].rstrip("/")

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
    pkgs = ctx.actions.tset(MojoPkgTSet, value = public)

    # The README gate, as a mojo_library's (readme.bzl, readme_gate): compiled against `lib`, with no C
    # closure; the README ships in the conda package, so a relative link in it is refused.
    gate = readme_gate(ctx, ctx.attrs.toolchain[MojoToolchainInfo], import_name, pkgs, None, [], True, adopt_readme_test, rerun = rerun_env(ctx))
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
            c_link = None,
            conda_name = ctx.attrs.conda_name or import_name,
            conda_refusal = None,
            dlopen = [],
            direct = [],
            direct_conda = {},
            import_name = import_name,
            native = _NO_NATIVE,
            pkgs = pkgs,
            pkgs_def = MojoPkgTSet,
            readme = ctx.attrs.readme,
        ),
        welded_tests_info(ctx.attrs.test_srcs),
    ]

_adopted = rule(
    impl = _impl,
    attrs = {
        "conda_name": attrs.option(attrs.string(), default = None),
        "import_name": attrs.option(attrs.string(), default = None),
        "lib": attrs.dep(),
        "readme": attrs.option(attrs.source(), default = None),
        "readme_tool": attrs.option(attrs.exec_dep(providers = [RunInfo]), default = None),
        "srcs": attrs.list(attrs.source()),
        "test_optimization_level": attrs.string(default = TEST_OPT_LEVEL),
        "test_srcs": attrs.list(attrs.source()),
        "test_runs": attrs.dep(),
        "toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    } | RERUN_ATTRS,
)

def _mojo_adopted_library(**kwargs):
    if kwargs.get("readme") != None:
        if "readme_tool" in kwargs:
            fail("{}: `readme_tool` is set by mojo_adopted_library with the README; do not pass it".format(kwargs.get("name", "mojo_adopted_library")))
        kwargs["readme_tool"] = _README_TOOL
    _adopted(**kwargs)

mojo_adopted_library = declares_docs(_mojo_adopted_library)
