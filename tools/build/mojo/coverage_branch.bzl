"""Branch coverage builds of mojo_library's welded tests: the bitcode, the
instrumented binary and its run (tools/build/coverage/branch/README.md).

With `coverage_branch` set (coverage.bzl, coverage_kwargs: the switch on,
linux-x86_64), per `test_srcs` entry that is a source file:

- `[coverage][bc][<test>]` (category `mojo_emit_cov_bc`): the test compiled
  by mojo_wrapper.sh as its coverage binary is (`[coverage][bin]`: -O0, line
  tables, the same closure, `test_deps` included, and source root), but
  emitted as LLVM bitcode, `cov/branch/<test>.bc`;
- `[coverage][pgo_bin][<test>]` (category `mojo_cov_pgo_link`): that
  bitcode instrumented with IR profile counters by Mojo's lld and linked as a
  release test is, with the profile runtime (cov_branch_link.sh),
  `cov/branch/<test>`;
- `[coverage][branch][<test>]` (category `mojo_cov_branch_run`): the merged
  profile of its run through the release gate's runner (cov_branch_run.sh),
  `cov/branch/<test>.profdata`.

Nothing waits for them: the package's join, `[coverage]` and the gate are
what they are without them.
"""

load(":providers.bzl", "MojoPkgTSet")
load(":test_runtime.bzl", "test_root")

def coverage_branch(ctx, tc, t, stem, closure_tsets, mojo_cmd, link_tail, data, env_args):
    """Declares the three branch coverage actions of test source `t`
    (module docstring) and returns (bitcode, binary, profdata).
    `closure_tsets` are the MojoPkgTSets the test compiles against (defs.bzl's
    tests_closure: the ungated package and its deps, then the `test_deps`),
    `mojo_cmd` defs.bzl's _mojo_cmd, `link_tail` the C libraries of the
    test's link, `test_deps` included (or None),
    `data` its staged data and `env_args` its runner's --env arguments."""
    where = "{}: branch coverage of {}".format(ctx.label.raw_target(), t.short_path)
    if "LLVM_PROFILE_FILE" in ctx.attrs.test_env:
        fail("{}: test_env sets LLVM_PROFILE_FILE, which a branch coverage run sets itself (where the test's profile is written)".format(where))
    link_dir, run_dir = ctx.attrs.coverage_branch[DefaultInfo].default_outputs
    # As _build_executable makes the release test's closure from the same list.
    closure = ctx.actions.tset(MojoPkgTSet, children = closure_tsets)

    # The test, staged as _build_executable stages it: the wrapper strips the
    # staged directory, so the bitcode names the test by its package path.
    staged = ctx.actions.copied_dir("cov/branch/{}.src".format(stem), {t.short_path: t})
    bc = ctx.actions.declare_output("cov/branch/{}.bc".format(stem))
    ctx.actions.run(
        mojo_cmd(tc, [
            "build",
            "--emit",
            "llvm-bitcode",
            "--optimization-level",
            "0",
            "--target-cpu",
            tc.target_cpu,
            "--debug-level",
            "line-tables",
            closure.project_as_args("include"),
            staged.project(t.short_path),
            "-o",
            bc.as_output(),
        ], source_root = staged),
        category = "mojo_emit_cov_bc",
        identifier = stem,
    )

    exe = ctx.actions.declare_output("cov/branch/{}".format(stem))
    ctx.actions.run(
        cmd_args(
            tc.busybox,
            "sh",
            link_dir.project("cov_branch_link.sh"),
            tc.busybox,
            tc.compiler,
            tc.link,
            tc.cc_target,
            bc,
            exe.as_output(),
            link_tail if link_tail else [],
            hidden = link_dir,
        ),
        category = "mojo_cov_pgo_link",
        identifier = stem,
    )

    root, binary = test_root(ctx, "cov/branch/{}.root".format(stem), exe, data)
    profdata = ctx.actions.declare_output("cov/branch/{}.profdata".format(stem))
    ctx.actions.run(
        cmd_args(
            tc.busybox,
            "sh",
            run_dir.project("cov_branch_run.sh"),
            tc.busybox,
            tc.gate_runner,
            tc.compiler,
            "{}:{} [branch coverage]".format(ctx.label.raw_target(), t.short_path),
            binary,
            profdata.as_output(),
            env_args,
            hidden = [run_dir, root],
        ),
        category = "mojo_cov_branch_run",
        identifier = stem,
    )
    return struct(bc = bc, binary = exe, profdata = profdata)

def coverage_branch_sub_targets(branch):
    """`bc`, `pgo_bin` and `branch` of a library's `coverage` sub-target:
    `branch` {stem: coverage_branch's struct}. Each is every test's file, and
    `[<test>]` one test's."""
    out = {}
    for name, field in (("bc", "bc"), ("pgo_bin", "binary"), ("branch", "profdata")):
        out[name] = [DefaultInfo(
            default_outputs = [getattr(branch[k], field) for k in sorted(branch)],
            sub_targets = {k: [DefaultInfo(default_output = getattr(v, field))] for k, v in branch.items()},
        )]
    return out
