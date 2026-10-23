"""The rules of the README e2e (README.md): a package of a release, tried as its user.

`readme_e2e_staged` writes a release's staged set from the packages the build made.
`readme_e2e` installs one package from a staged set into a fresh project and runs
its README examples against the installed copy, as one build action.
`readme_e2e_scenario` is one scenario of the tool's own tests.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "DocTreeInfo", "declares_docs")
load("@komira//tools/build/mojo:defs.bzl", "mojo_compile_cmd")
load(":guard.bzl", _guard_findings = "findings")
load("@komira//tools/build/mojo:opt_level.bzl", "TEST_OPT_LEVEL", "opt_level_args")
load("@komira//tools/build/mojo:providers.bzl", "MojoToolchainInfo")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

_TOOL = "komira//tools/build/readme_e2e:readme_e2e"
_README_TOOL = "komira//tools/build/readme_examples:tool"

def _out(dep):
    return dep[DefaultInfo].default_outputs[0]

# ---- the staged set ---------------------------------------------------------

def _staged_impl(ctx):
    out = ctx.actions.declare_output("staged", dir = True)
    cmd = cmd_args(ctx.attrs._tool[RunInfo], "assemble", "--out", out.as_output(), "--mojo", ctx.attrs.mojo)
    for name in sorted(ctx.attrs.members.keys()):
        version, conda, readme = ctx.attrs.members[name]
        cmd.add("--member", name, version, _out(conda), _out(readme))
    ctx.actions.run(cmd, category = "readme_e2e_assemble")
    return [DefaultInfo(default_output = out)]

_readme_e2e_staged = rule(
    impl = _staged_impl,
    doc = "The staged set of a release (mopm's spec/staged-set.md): `plan.json`, each member's `.conda` under its subdir, each README at `<name>/README.md`. `members` is {name: (version, the package's `.conda` target, its README target)}, written in dependency order with the sha256 and size of each file. A member whose package does not hold the name, version and file name given, or that needs a package the set lacks, fails the build. This stands in for `mopm stage` until the release flow has it: any target whose output is a directory in that layout is a `staged` of `readme_e2e`.",
    attrs = {
        "members": attrs.dict(attrs.string(), attrs.tuple(attrs.string(), attrs.dep(), attrs.dep())),
        "mojo": attrs.string(default = "1.0.0"),
        "_tool": attrs.exec_dep(providers = [RunInfo], default = _TOOL),
    },
)

def readme_e2e_staged(**kwargs):
    _readme_e2e_staged(exec_compatible_with = LINUX_X86_64, **kwargs)

readme_e2e_staged = declares_docs(readme_e2e_staged)

# ---- one package ------------------------------------------------------------

def _e2e_impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    work = ctx.actions.declare_output("work", dir = True)
    marker = ctx.actions.declare_output(ctx.label.name + ".passed")

    # Each command is written one word per line (the tool adds the arguments),
    # with its inputs, so the action runs them from the directory it runs from.
    mopm, mopm_in = ctx.actions.write("mopm.cmd", cmd_args(ctx.attrs.mopm[RunInfo]), allow_args = True, with_inputs = True)
    readme, readme_in = ctx.actions.write("readme_tool.cmd", cmd_args(ctx.attrs.readme_tool[RunInfo]), allow_args = True, with_inputs = True)

    # What mojo_library's README gate builds an example with (defs.bzl,
    # _build_executable), up to the includes, the program and the output.
    build = mojo_compile_cmd(tc, ["build", opt_level_args(ctx.label, TEST_OPT_LEVEL, "mojo_build_test", None), "--target-cpu", tc.target_cpu])
    compile, compile_in = ctx.actions.write("compile.cmd", build, allow_args = True, with_inputs = True)

    # What runs every welded test (test_runtime.bzl, gate_mojo), up to the
    # label, the test and the marker.
    gate = cmd_args(tc.gate, "mojo", "--busybox", tc.busybox, "--runtime-lib", cmd_args(tc.compiler, format = "{}/lib"))
    run, run_in = ctx.actions.write("run.cmd", gate, allow_args = True, with_inputs = True)

    ctx.actions.run(
        cmd_args(
            ctx.attrs.tool[RunInfo],
            "verify",
            "--package",
            ctx.attrs.package,
            "--version",
            ctx.attrs.version,
            "--mojo",
            ctx.attrs.mojo,
            "--staged",
            _out(ctx.attrs.staged),
            "--work",
            work.as_output(),
            "--marker",
            marker.as_output(),
            "--mopm",
            mopm,
            "--readme-tool",
            readme,
            "--compile",
            compile,
            "--run",
            run,
            hidden = [mopm_in, readme_in, compile_in, run_in],
        ),
        category = "readme_e2e",
        identifier = ctx.attrs.package,
    )
    return [DefaultInfo(default_output = marker, sub_targets = {"work": [DefaultInfo(default_output = work)]})]

_readme_e2e = rule(
    impl = _e2e_impl,
    doc = "One package of a staged set, tried as a user of it: a fresh project runs `mopm add <package>@=<version> --overlay <staged set>`, the locked closure is unpacked into a prefix, and the README the set holds is compiled and run example by example against that prefix, with nothing of the source tree on the path. The target exists (its marker) only when every example passed. See README.md.",
    attrs = {
        "mojo": attrs.string(default = "1.0.0", doc = "The compiler version the packages are built for."),
        "mopm": attrs.exec_dep(providers = [RunInfo], doc = "The mopm that installs. It must have `--overlay`: one that lacks it fails the target, naming the option."),
        "package": attrs.string(),
        "readme_tool": attrs.exec_dep(providers = [RunInfo], default = _README_TOOL),
        "staged": attrs.dep(doc = "A target whose output is a staged set: `readme_e2e_staged`, or `mopm stage`'s directory."),
        "tool": attrs.exec_dep(providers = [RunInfo], default = _TOOL),
        "toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
        "version": attrs.string(),
    },
)

def readme_e2e(**kwargs):
    _readme_e2e(exec_compatible_with = LINUX_X86_64, **kwargs)

readme_e2e = declares_docs(readme_e2e)

# ---- the tool's own scenarios -----------------------------------------------

def _scenario_impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name + ".passed")
    work = ctx.actions.declare_output("work", dir = True)
    ctx.actions.run(
        cmd_args(
            ctx.attrs.scenario[RunInfo],
            "--scenario",
            ctx.label.name,
            "--tool",
            ctx.attrs.tool[RunInfo],
            "--fake",
            ctx.attrs.fake[RunInfo],
            "--readme-tool",
            ctx.attrs.readme_tool[RunInfo],
            "--work",
            work.as_output(),
            "--out",
            out.as_output(),
        ),
        category = "readme_e2e_scenario",
    )
    return [DefaultInfo(default_output = out)]

_readme_e2e_scenario = rule(
    impl = _scenario_impl,
    doc = "One scenario of the README e2e tool (scenario.zig's table), named by the target, run as a build action: the target exists only if the scenario's checks held.",
    attrs = {
        "fake": attrs.exec_dep(providers = [RunInfo], doc = "The stand-ins of mopm, the compiler and the gate, fake.zig, built."),
        "readme_tool": attrs.exec_dep(providers = [RunInfo], default = _README_TOOL),
        "scenario": attrs.exec_dep(providers = [RunInfo], doc = "scenario.zig, built."),
        "tool": attrs.exec_dep(providers = [RunInfo], doc = "The tool under test (`:readme_e2e_unchecked`)."),
    },
)

def readme_e2e_scenario(**kwargs):
    _readme_e2e_scenario(exec_compatible_with = LINUX_X86_64, **kwargs)

readme_e2e_scenario = declares_docs(readme_e2e_scenario)

# ---- the aggregate ----------------------------------------------------------

def _all_impl(ctx):
    return [DefaultInfo(default_outputs = [_out(d) for d in ctx.attrs.packages])]

_readme_e2e_all = rule(
    impl = _all_impl,
    doc = "Building this builds every `packages` target: the README e2e of the whole release, one marker per package.",
    attrs = {"packages": attrs.list(attrs.dep())},
)

def readme_e2e_all(**kwargs):
    _readme_e2e_all(exec_compatible_with = LINUX_X86_64, **kwargs)

readme_e2e_all = declares_docs(readme_e2e_all)

# ---- the guard --------------------------------------------------------------

def _complete_impl(ctx):
    paths = ctx.attrs.tree[DocTreeInfo].files.keys()
    why = _guard_findings(paths, ctx.attrs.covered)
    if why:
        fail("{}: {}".format(ctx.label, why))
    out = ctx.actions.write(ctx.label.name + ".txt", "README e2e targets: {}\n".format(" ".join(sorted(ctx.attrs.covered))))
    return [DefaultInfo(default_output = out)]

_readme_e2e_complete = rule(
    impl = _complete_impl,
    doc = "Fails analysis when a package with `src/<name>/mopm.toml` (read from `tree`, the cell's root doc_tree, which holds every file) is not in `covered`, or `covered` names one without. `targets` are the README e2e targets of `covered`: analysed, never built, so a name with no target is an analysis error too.",
    attrs = {
        "covered": attrs.list(attrs.string()),
        "targets": attrs.list(attrs.dep(), default = []),
        "tree": attrs.dep(providers = [DocTreeInfo]),
    },
)

def readme_e2e_complete(**kwargs):
    _readme_e2e_complete(exec_compatible_with = LINUX_X86_64, **kwargs)

readme_e2e_complete = declares_docs(readme_e2e_complete)

# ---- a stand-in for mopm ----------------------------------------------------

def _standin_impl(ctx):
    return [DefaultInfo(), RunInfo(args = cmd_args(ctx.attrs.fake[RunInfo], ctx.attrs.program))]

_readme_e2e_standin = rule(
    impl = _standin_impl,
    doc = "A program of fake.zig as a command (`fake <program>`): `mopm`, the `mopm add --overlay` of a staged set that holds its closure. For the target that runs the real compiler over a real package before the pinned mopm has `--overlay`.",
    attrs = {
        "fake": attrs.exec_dep(providers = [RunInfo]),
        "program": attrs.string(),
    },
)

def readme_e2e_standin(**kwargs):
    _readme_e2e_standin(exec_compatible_with = LINUX_X86_64, **kwargs)

readme_e2e_standin = declares_docs(readme_e2e_standin)
