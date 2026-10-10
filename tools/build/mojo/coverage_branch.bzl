"""Branch coverage builds of mojo_library's welded tests: the bitcode, the
instrumented binary and its run (tools/build/coverage/branch/README.md).

With `coverage_branch` set (coverage.bzl, coverage_kwargs: the switch on,
linux-x86_64), per `test_srcs` entry that is a source file:

- `[coverage][bc][<test>]` (category `mojo_emit_cov_bc`): the test compiled
  by mojo_wrapper.sh as its coverage binary is (`[coverage][bin]`: -O0, line
  tables, the same `-D` assert level and `test_defines`, the same closure,
  `test_deps` included, and source root), but
  emitted as LLVM bitcode, `cov/branch/<test>.bc`;
- `[coverage][pgo_bin][<test>]` (category `mojo_cov_pgo_link`): that
  bitcode instrumented with IR profile counters by Mojo's lld and linked as a
  release test is, with the profile runtime (cov_branch_link.sh),
  `cov/branch/<test>`;
- `[coverage][branch][<test>]` (category `mojo_cov_branch_run`): the merged
  profile of its run through the release gate's runner (cov_branch_run.sh),
  `cov/branch/<test>.profdata`;
- `[coverage][branch_ir][<test>]` (category `mojo_cov_branch_annotate`): the
  bitcode with that profile applied by Mojo's lld, as IR text whose branches
  carry their counts (cov_branch_annotate.sh, which also reads the binary:
  the profile must hold exactly the functions it links), `cov/branch/<test>.ll`;
- `[coverage][branch_info][<test>]` (category `mojo_cov_branch_classify`):
  the branches of the library's measured sources in that IR, each a source
  decision or a known compiler-made branch, as lcov `BRDA` records in
  repository paths (cov_branch_classify), `cov/branch/<test>.info`.

The gate (coverage.bzl) reads each test's `cov/branch/<test>.info` when
the library's `coverage_branch_gate` is set (a library of
COVERAGE_BRANCH_GATE in tools/build/coverage/policy.bzl, or a fixture of
the tests cell that does not pass False), so its conda package (what
ships) waits for all five through the gate; for any other library nothing
waits for them. No join takes them directly (the library's own package
waits for no coverage action), and `[coverage]` does not include them.
"""

load(":providers.bzl", "MojoPkgTSet")
load(":test_runtime.bzl", "test_root")

def coverage_branch(ctx, tc, t, stem, closure_tsets, mojo_cmd, link_tail, data, env_args, src_dir, src_repo, gen, defines):
    """Declares the five branch coverage actions of test source `t` (module
    docstring) and returns their outputs (bc, binary, profdata, ir, info).
    `closure_tsets` are the MojoPkgTSets the test compiles against (defs.bzl's
    tests_closure: the ungated package and its deps, then the `test_deps`),
    `mojo_cmd` defs.bzl's _mojo_cmd, `link_tail` the C libraries of the
    test's link, `test_deps` included (or None), `data` its staged data,
    `env_args` its runner's --env arguments, `src_dir` the library's [src]
    (it ends in src/<import>; the package is compiled from its parent, so
    the IR names its sources `<import>/<file>`), `src_repo` the repository
    directory of those sources (ending in `/`), `gen` the paths in `src_dir`
    of its generated sources, which are not measured, and `defines` the
    `-D` arguments of the test's builds (defs.bzl's test_defines: its assert
    level and `test_defines`), so the bitcode is the program the gate ran,
    compiled as its coverage binary is."""
    where = "{}: branch coverage of {}".format(ctx.label.raw_target(), t.short_path)
    if "LLVM_PROFILE_FILE" in ctx.attrs.test_env:
        fail("{}: test_env sets LLVM_PROFILE_FILE, which a branch coverage run sets itself (where the test's profile is written)".format(where))
    link_dir, run_dir, annotate_dir, classify = ctx.attrs.coverage_branch[DefaultInfo].default_outputs
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
            defines,
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

    ir = ctx.actions.declare_output("cov/branch/{}.ll".format(stem))
    ctx.actions.run(
        cmd_args(
            tc.busybox,
            "sh",
            annotate_dir.project("cov_branch_annotate.sh"),
            tc.busybox,
            bc,
            profdata,
            exe,
            ir.as_output(),
            hidden = annotate_dir,
        ),
        category = "mojo_cov_branch_annotate",
        identifier = stem,
    )

    # The library's sources are named in the IR `<import>/<file>` (the
    # package is compiled from the parent of [src], which ends in
    # src/<import>), and read in [src]: the classifier reads the token of
    # each branch's line and column. So is every other package of the
    # closure, `test_deps` included (`<its import>/<file>`), which is not
    # measured: an --exclude each, named by its `.mojoc`.
    import_name = src_dir.basename
    others = {}
    for ts in closure_tsets:
        for pkg in ts.traverse():
            dep = pkg.basename.removesuffix(".mojoc")
            if dep != import_name:
                others[dep] = True
    info = ctx.actions.declare_output("cov/branch/{}.info".format(stem))
    ctx.actions.run(
        cmd_args(
            classify,
            "--ir",
            ir,
            "--out",
            info.as_output(),
            "--map",
            "{}/={}".format(import_name, src_repo),
            "--src",
            cmd_args(src_dir, format = "{}/"),
            [["--gen", g] for g in gen],
            # Where the standard library's sources are named: a String's
            # last-reference test is its code inlined at the branch.
            "--stdlib",
            "oss/modular/",
            # The standard library, the closure's other packages, anything
            # under buck-out/, the test itself and the compile unit with no
            # file are not measured.
            "--exclude",
            "oss/modular/",
            [["--exclude", d + "/"] for d in sorted(others)],
            "--exclude",
            "buck-out/",
            "--exclude-file",
            t.short_path,
            "--exclude-file",
            "<unknown>",
            hidden = src_dir,
        ),
        category = "mojo_cov_branch_classify",
        identifier = stem,
    )
    return struct(bc = bc, binary = exe, profdata = profdata, ir = ir, info = info)

def coverage_branch_sub_targets(branch):
    """`bc`, `pgo_bin`, `branch`, `branch_ir` and `branch_info` of a
    library's `coverage` sub-target: `branch` {stem: coverage_branch's
    struct}. Each is every test's file, and `[<test>]` one test's."""
    out = {}
    for name, field in (("bc", "bc"), ("pgo_bin", "binary"), ("branch", "profdata"), ("branch_ir", "ir"), ("branch_info", "info")):
        out[name] = [DefaultInfo(
            default_outputs = [getattr(branch[k], field) for k in sorted(branch)],
            sub_targets = {k: [DefaultInfo(default_output = getattr(v, field))] for k, v in branch.items()},
        )]
    return out
