"""The build system's self-test scenarios and graph checks.

docs/design/build_selftests.md is the design; README.md here says how to run
them.

`selftest_scenario` is a `buck2 test` target that drives buck2 from outside:
its command is the scenario's Zig binary itself, given the pinned buck2
release, and it runs on the client, from the project root. Every inner
command it issues runs under the scenario's own `--isolation-dir` (or in a
scratch tree) and with `-c komira_selftest.inner=true`, and every action an
inner build runs executes on the farm (the helper library checks that).

The recursion guard: `//tools/build/selftest:inner` is the config_setting of
`komira_selftest.inner=true`. Under it every scenario is incompatible (a
constraint no platform has), so an inner `//...` skips the scenarios instead
of running them a level deeper; and the scenario binary is given `--nested`,
which the helper library refuses, so a scenario that lost its
incompatibility under the key fails instead of driving buck2.

`graph_check` declares a BXL graph check (graph/checks.bxl): the check's name
and the targets it queries, as strings, never as dependencies, and its Zig
checker. release/ci/build_targets.sh runs the BXL for each graph_check of a
batch; the checker runs over the facts the BXL collected as a build action.
python_closure also reads files (`trees`, doc_tree targets as strings, and
`srcs`) and takes its allowlist (`surface`, `ceiling`).
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:toolchain.bzl", "zig_exe")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/selftest/graph:graph_check_info.bzl", "GraphCheckInfo")

# Built with zig 0.15.2 (`:zig`); the executables are built behind the check
# that the pin is that release.
_ZIG = "komira//tools/build/toolchains:zig"
_ZIG_VERSION = "komira//tools/build/toolchains:zig_version"

_SELFTEST = "komira//tools/build/selftest"

# The helper library's sources: every scenario's binary imports them, and
# `:lib` (their welded unit tests) gates every scenario's binary.
LIB_SRCS = [
    "lib/args.zig",
    "lib/expect.zig",
    "lib/guard.zig",
    "lib/lib.zig",
    "lib/lib_test.zig",
    "lib/parse.zig",
    "lib/reds.zig",
    "lib/refusals.zig",
    "lib/runner.zig",
    "lib/scratch.zig",
    "lib/text.zig",
    "lib/whatran.zig",
]

def _unzst_impl(ctx):
    out = ctx.actions.declare_output(ctx.attrs.out)
    ctx.actions.run(
        cmd_args(ctx.attrs._unzst[RunInfo], ctx.attrs.src, out.as_output()),
        category = "unzst",
    )
    return [DefaultInfo(default_output = out), RunInfo(args = cmd_args(out))]

_unzst_rule = rule(
    impl = _unzst_impl,
    attrs = {
        "out": attrs.string(),
        "src": attrs.source(),
        "_unzst": attrs.exec_dep(default = _SELFTEST + ":unzst", providers = [RunInfo]),
    },
)

def _scenario_impl(ctx):
    command = cmd_args(
        ctx.attrs.scenario[RunInfo],
        "--scenario",
        ctx.label.name,
        "--buck2",
        ctx.attrs.buck2[DefaultInfo].default_outputs[0],
        "--buck2-zst",
        ctx.attrs.buck2_zst,
        "--expect",
        ctx.attrs.expect,
        ctx.attrs.guard_args,
    )
    return [
        DefaultInfo(),
        ExternalRunnerTestInfo(
            type = "custom",
            command = [command],
            labels = ctx.attrs.labels,
            # A scenario reads the checkout (what it tests) and starts its
            # own daemons: it runs on the client, from the project root.
            # Every action of its inner builds runs on the farm.
            run_from_project_root = True,
            default_executor = CommandExecutorConfig(
                local_enabled = True,
                remote_enabled = False,
                use_limited_hybrid = False,
            ),
        ),
    ]

_scenario_rule = rule(
    impl = _scenario_impl,
    attrs = {
        "buck2": attrs.exec_dep(default = _SELFTEST + ":buck2"),
        # The release asset `buck2` is unpacked from: the guard holds its
        # sha256 to tools/buck2's pin.
        "buck2_zst": attrs.source(default = _SELFTEST + ":buck2.zst"),
        "expect": attrs.enum(["remote", "local"], default = "remote"),
        # `--nested` under the recursion guard's config_setting, else
        # nothing: set by `selftest_scenario`, never by hand.
        "guard_args": attrs.list(attrs.string(), default = []),
        "labels": attrs.list(attrs.string(), default = []),
        "scenario": attrs.exec_dep(providers = [RunInfo]),
    },
)

def selftest_scenario(name, src = None, expect = "remote", labels = [], visibility = None):
    """One scenario: `<name>.zig` (or `src`) built with the helper library,
    and the test target `<name>` that runs it."""
    zig_exe(
        name = name + "_bin",
        exec_compatible_with = LINUX_X86_64,
        src = src or name + ".zig",
        imports = LIB_SRCS,
        unit_tests = [_SELFTEST + ":lib", _ZIG_VERSION],
        busybox = "komira//tools/build/toolchains:busybox",
        zig = _ZIG,
    )
    _scenario_rule(
        name = name,
        scenario = ":" + name + "_bin",
        expect = expect,
        labels = labels,
        guard_args = select({
            _SELFTEST + ":inner": ["--nested"],
            "DEFAULT": [],
        }),
        target_compatible_with = select({  # komira-limit:selftest-not-inner
            _SELFTEST + ":inner": [_SELFTEST + ":never"],
            "DEFAULT": [],
        }),
        visibility = visibility,
    )

def _graph_check_impl(ctx):
    return [
        DefaultInfo(),
        GraphCheckInfo(
            check = ctx.attrs.check,
            cell = ctx.label.cell,
            checker = ctx.attrs.checker[RunInfo],
            exec_compatible_with = LINUX_X86_64,
            label = str(ctx.label.raw_target()),
            targets = ctx.attrs.targets,
            trees = ctx.attrs.trees,
            files = {(ctx.label.package + "/" if ctx.label.package else "") + f.short_path: f for f in ctx.attrs.srcs},
            surface = ctx.attrs.surface,
            ceiling = ctx.attrs.ceiling,
        ),
    ]

graph_check_rule = rule(
    impl = _graph_check_impl,
    attrs = {
        "check": attrs.string(),
        "checker": attrs.exec_dep(providers = [RunInfo]),
        "targets": attrs.list(attrs.string()),
        # python_closure: the doc_tree targets it reads the files of, as
        # strings keyed by their cell's path in the repository, and the
        # files of this package a doc_tree skips.
        "trees": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "srcs": attrs.list(attrs.source(), default = []),
        # python_closure's allowlist (graph_checks.zig): package paths of
        # the Python surface, and the exact findings allowed today.
        "surface": attrs.list(attrs.string(), default = []),
        "ceiling": attrs.list(attrs.string(), default = []),
    },
)

unzst = declares_docs(_unzst_rule)
graph_check = declares_docs(graph_check_rule)
