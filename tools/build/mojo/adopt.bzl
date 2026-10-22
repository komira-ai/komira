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

What it does not carry, because buildrules' rules do not: the README's examples compiled and run
(`readme.bzl`), the branch coverage gate and the mutation sub-targets of a `mojo_library`. A library
adopted here has none of the three until buildrules has them.

A library that has deps or native code is not adopted by this rule: it has no `deps` or `native`
attribute, so a BUCK file that needs them stops at the attribute, not at a wrong `MojoInfo`.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load(":providers.bzl", "MojoInfo", "MojoPkgTSet", "welded_tests_info")

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
    return [
        DefaultInfo(
            default_output = public,
            sub_targets = {
                "src": [DefaultInfo(default_output = src_dir)],
                "tests": [DefaultInfo(default_outputs = markers)],
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
            pkgs = ctx.actions.tset(MojoPkgTSet, value = public),
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
        "srcs": attrs.list(attrs.source()),
        "test_srcs": attrs.list(attrs.source()),
        "test_runs": attrs.dep(),
    },
)

mojo_adopted_library = declares_docs(_adopted)
