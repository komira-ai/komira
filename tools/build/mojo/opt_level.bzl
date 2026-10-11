"""`mojo build --optimization-level`: the levels, the rules' defaults, and the
analysis-time check of the level each compile of a target uses.

Tests compile at 1 and shipped code at 3: a test is built, run once and
thrown away, so its compile time is most of its cost, while a binary or
shared library runs in production. Each rule states its default (defs.bzl);
`optimization_level` / `test_optimization_level` override it per target. The
level is the compiling target's own: a test linking a shared library links
that library as its own target built it.

Every `mojo build` of defs.bzl's `_build_executable` takes its
`--optimization-level` arguments from `opt_level_args`, which records the
level it puts on the command line under the action's category. mojo_library
(its welded tests), mojo_test and mojo_binary (and its `[shared]`) return
that record as `MojoOptLevelInfo`. `mojo_opt_level_check` reads it at
analysis: a row whose target has no compile of the row's category, or a
compile of it at another level, fails the check's analysis, so building the
check target is the test (tests//functional/opt_level).
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

OPT_LEVELS = ["0", "1", "2", "3"]
TEST_OPT_LEVEL = "1"
SHIPPED_OPT_LEVEL = "3"

MojoOptLevelInfo = provider(fields = {
    # {action category: the distinct levels of the target's compiles of that
    # category, in the order they were first used}
    "levels": provider_field(dict[str, list[str]]),
})

def opt_level_args(label, opt_level, category, levels):
    """The `--optimization-level` arguments of one `mojo build`.

    Fails analysis on a level `mojo build` does not accept. With `levels` (a
    dict), records the level of the returned arguments under `category`.
    """
    if opt_level not in OPT_LEVELS:
        fail("{}: optimization level `{}` is not one of {}".format(label.raw_target(), opt_level, ", ".join(OPT_LEVELS)))
    args = ["--optimization-level", opt_level]
    if levels != None:
        seen = levels.setdefault(category, [])
        if args[1] not in seen:
            seen.append(args[1])
    return args

def _check_impl(ctx):
    bad = []
    lines = []
    for dep, category, level in ctx.attrs.rows:
        name = str(dep.label.raw_target())
        if level not in OPT_LEVELS:
            fail("{}: the row for {} {} expects level `{}`, not one of {}".format(ctx.label.raw_target(), name, category, level, ", ".join(OPT_LEVELS)))
        got = dep[MojoOptLevelInfo].levels.get(category, [])
        if not got:
            bad.append("{} has no {} compile".format(name, category))
        elif got != [level]:
            bad.append("{} {} at -O{}, expected -O{}".format(name, category, "/".join(sorted(got)), level))
        else:
            lines.append("{}\t{}\t{}".format(name, category, level))
    if not ctx.attrs.rows:
        fail("{}: rows is empty: a check of no compile checks nothing".format(ctx.label.raw_target()))
    if bad:
        fail("{}: optimization levels: {}".format(ctx.label.raw_target(), "; ".join(bad)))
    return [DefaultInfo(default_output = ctx.actions.write("opt_levels.tsv", lines))]

_check_rule = rule(
    impl = _check_impl,
    attrs = {
        # (target, action category, level): every compile of that category
        # the target declares is at that level, and there is at least one.
        "rows": attrs.list(attrs.tuple(attrs.dep(providers = [MojoOptLevelInfo]), attrs.string(), attrs.string())),
    },
)

mojo_opt_level_check = declares_docs(_check_rule)
